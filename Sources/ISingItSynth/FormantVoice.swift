import Foundation
import ISingItPerformance

/// A voice that can sing a planned phrase. The DSP voice implements it now; the neural
/// voice (phase 3) implements the same protocol, so nothing upstream changes.
public protocol VoiceSynthesizer: Sendable {
    var profile: VoiceProfile { get }
    /// Renders mono audio for one phrase, `phrase.duration` seconds long.
    func render(_ phrase: PhrasePlan, sampleRate: Double) -> [Float]
}

/// Describes a voice the user can pick.
public struct VoiceProfile: Codable, Sendable, Equatable, Identifiable, Hashable {
    public var id: String
    public var name: String
    /// Multiplies every formant: ~1.0 for an adult male voice, ~1.17 for an adult female.
    public var formantScale: Double
    /// Glottal open quotient (higher = softer, breathier).
    public var openQuotient: Double
    /// Extra breath noise.
    public var breathiness: Double
    /// Comfortable range, MIDI note numbers (the editor warns outside it).
    public var range: ClosedRange<Int>

    public init(id: String, name: String, formantScale: Double, openQuotient: Double, breathiness: Double, range: ClosedRange<Int>) {
        self.id = id
        self.name = name
        self.formantScale = formantScale
        self.openQuotient = openQuotient
        self.breathiness = breathiness
        self.range = range
    }

    /// The phase 1 DSP voices. Real recorded and neural voices arrive in phase 3.
    public static let dspSoprano = VoiceProfile(id: "dsp-soprano", name: "DSP Soprano", formantScale: 1.17, openQuotient: 0.62, breathiness: 0.04, range: 60...84)
    public static let dspAlto = VoiceProfile(id: "dsp-alto", name: "DSP Alto", formantScale: 1.1, openQuotient: 0.6, breathiness: 0.04, range: 53...77)
    public static let dspTenor = VoiceProfile(id: "dsp-tenor", name: "DSP Tenor", formantScale: 1.0, openQuotient: 0.55, breathiness: 0.03, range: 48...72)
    public static let dspBass = VoiceProfile(id: "dsp-bass", name: "DSP Bass", formantScale: 0.92, openQuotient: 0.5, breathiness: 0.03, range: 40...64)

    public static let builtIn: [VoiceProfile] = [dspSoprano, dspAlto, dspTenor, dspBass]

    public static func named(_ id: String) -> VoiceProfile? {
        builtIn.first { $0.id == id || $0.id == "dsp-\(id)" || $0.name.lowercased() == id.lowercased() }
    }
}

/// Synth.DSP: a source-filter formant singer (Klatt-style cascade).
///
/// A glottal pulse train at the planned pitch excites five formant resonators whose
/// frequencies follow the phonemes; fricatives and bursts add band-limited noise. It
/// needs no recordings or training, so the app can sing from day one. The plan's WORLD
/// vocoder + phoneme bank needs a recorded singer; see docs/adr/0002.
public struct FormantVoice: VoiceSynthesizer {
    public var profile: VoiceProfile

    public init(profile: VoiceProfile = .dspSoprano) {
        self.profile = profile
    }

    /// Parameters per control block.
    private struct Frame {
        var f1 = 500.0, f2 = 1500.0, f3 = 2500.0
        var b1 = 70.0, b2 = 90.0, b3 = 140.0
        var voicing = 0.0
        var frication = 0.0
        var fricationCenter = 5000.0
        var fricationBandwidth = 3000.0
        var aspiration = 0.0
        var nasal = 0.0
    }

    static let blockSize = 32

    public func render(_ phrase: PhrasePlan, sampleRate: Double) -> [Float] {
        let sampleCount = max(0, Int((phrase.duration * sampleRate).rounded()))
        guard sampleCount > 0 else { return [] }
        let blockCount = (sampleCount + Self.blockSize - 1) / Self.blockSize
        let blockDuration = Double(Self.blockSize) / sampleRate
        var frames = targets(phrase, blockCount: blockCount, blockDuration: blockDuration)
        smooth(&frames, blockDuration: blockDuration)

        var output = [Float](repeating: 0, count: sampleCount)
        var rng = SplitMix(seed: UInt64(truncatingIfNeeded: phrase.segments.count &* 7919 &+ Int(phrase.startTime * 1000)))
        let scale = profile.formantScale
        let f4 = 3350 * scale, f5 = 3950 * scale

        var r1 = Resonator(), r2 = Resonator(), r3 = Resonator(), r4 = Resonator(), r5 = Resonator()
        var nasalLowpass = OnePole()
        var tilt = OnePole()
        var fric = Biquad()
        var dcBlock = DCBlocker()
        var phase = 0.0
        var jitter = 0.0
        var aspLowpass = OnePole()

        for block in 0..<blockCount {
            let frame = frames[block]
            let t = (Double(block) + 0.5) * blockDuration
            let f0Block = interpolate(phrase.f0, at: t * phrase.frameRate)
            let loud = interpolate(phrase.loudness, at: t * phrase.frameRate)
            let breath = interpolate(phrase.breathiness, at: t * phrase.frameRate) + profile.breathiness

            // Singers raise F1 to stay above the pitch on high notes ("formant tuning").
            let f1 = max(frame.f1 * scale, min(f0Block * 1.1, 1100))
            r1.set(frequency: f1, bandwidth: frame.b1, sampleRate: sampleRate)
            r2.set(frequency: frame.f2 * scale, bandwidth: frame.b2, sampleRate: sampleRate)
            r3.set(frequency: frame.f3 * scale, bandwidth: frame.b3, sampleRate: sampleRate)
            r4.set(frequency: f4, bandwidth: 250, sampleRate: sampleRate)
            r5.set(frequency: f5, bandwidth: 320, sampleRate: sampleRate)
            fric.setBandpass(center: min(frame.fricationCenter * (0.85 + 0.15 * scale), sampleRate * 0.45),
                             bandwidth: frame.fricationBandwidth, sampleRate: sampleRate)
            nasalLowpass.set(cutoff: 1000 + 9000 * (1 - frame.nasal), sampleRate: sampleRate)
            tilt.set(cutoff: 2800 + 2600 * loud, sampleRate: sampleRate)
            aspLowpass.set(cutoff: 6000, sampleRate: sampleRate)

            let start = block * Self.blockSize
            let end = min(sampleCount, start + Self.blockSize)
            let oq = profile.openQuotient + 0.15 * breath
            for n in start..<end {
                // Glottal source (KLGLOTT88 flow derivative), with a little jitter.
                jitter += 0.002 * (rng.uniform() - jitter)
                let f0 = f0Block * (1 + 0.004 * jitter)
                phase += f0 / sampleRate
                if phase >= 1 { phase -= 1 }
                var pulse = 0.0
                var openPhase = false
                if phase < oq {
                    let x = phase / oq
                    pulse = 2 * x - 3 * x * x
                    openPhase = true
                }
                let noise = rng.uniform()
                let breathNoise = aspLowpass.process(noise) * (openPhase ? 1.0 : 0.4)

                let voiced = tilt.process(pulse) * frame.voicing * 1.0
                let aspirated = breathNoise * (frame.aspiration + breath * frame.voicing) * 0.9
                var y = r1.process(voiced + aspirated)
                y = r2.process(y)
                y = r3.process(y)
                y = r4.process(y)
                y = r5.process(y)
                y = nasalLowpass.process(y)
                let fricative = fric.process(noise) * frame.frication * 1.6
                var sample = (y * 0.22 + fricative) * loud
                sample = dcBlock.process(sample)
                output[n] = Float(tanh(sample * 1.4) / 1.4)
            }
        }
        return output
    }

    // MARK: - Targets

    private func targets(_ phrase: PhrasePlan, blockCount: Int, blockDuration: Double) -> [Frame] {
        var frames = [Frame](repeating: Frame(), count: blockCount)
        let segments = phrase.segments
        guard !segments.isEmpty else { return frames }
        var s = 0
        for block in 0..<blockCount {
            let t = (Double(block) + 0.5) * blockDuration
            while s + 1 < segments.count && segments[s].end <= t { s += 1 }
            let segment = segments[s]
            var frame = Frame()
            // Before the first or after the last phoneme: silence, holding formants.
            let inside = t >= segment.start && t < segment.end
            let target = PhonemeTarget.of(segment.phoneme)
            var formants = target.formants
            if target.borrowsFormants {
                // Use the neighbouring vowel's formants (the next one, else the previous).
                let neighbour = segments[(s + 1)...].first(where: { !PhonemeTarget.of($0.phoneme).borrowsFormants })
                    ?? segments[..<s].last(where: { !PhonemeTarget.of($0.phoneme).borrowsFormants })
                if let neighbour { formants = PhonemeTarget.of(neighbour.phoneme).formants }
                if target.velar { formants = (260, formants.1, min(formants.2, formants.1 + 400)) }
            }
            let u = segment.duration > 0 ? (t - segment.start) / segment.duration : 0
            if let endFormants = target.endFormants {
                // Diphthong: hold the first vowel, glide in the last part of the note.
                let glide = min(0.2, 0.45 * segment.duration)
                let x = smooth01((t - (segment.end - glide)) / glide)
                formants = (lerp(formants.0, endFormants.0, x), lerp(formants.1, endFormants.1, x), lerp(formants.2, endFormants.2, x))
            }
            frame.f1 = formants.0
            frame.f2 = formants.1
            frame.f3 = formants.2
            frame.b1 = target.bandwidths.0
            frame.b2 = target.bandwidths.1
            frame.b3 = target.bandwidths.2
            frame.fricationCenter = target.fricationCenter
            frame.fricationBandwidth = target.fricationBandwidth
            frame.nasal = target.nasal ? 1 : 0
            if inside {
                if target.closure > 0 {
                    if u < target.closure {
                        frame.voicing = target.voicing  // voice bar for voiced stops
                    } else {
                        let r = (u - target.closure) / (1 - target.closure)
                        frame.frication = target.frication * (r < 0.35 ? 1 : max(0, 1 - (r - 0.35) / 0.5))
                        frame.aspiration = target.burstAspiration * (r > 0.25 ? 1 : 0)
                        frame.voicing = target.voicing > 0 ? 0.5 : 0
                    }
                } else {
                    frame.voicing = target.voicing
                    frame.frication = target.frication
                    frame.aspiration = target.aspiration
                }
            }
            frames[block] = frame
        }
        return frames
    }

    /// Zero-phase smoothing so phonemes blend (coarticulation) without lag.
    private func smooth(_ frames: inout [Frame], blockDuration: Double) {
        func pass(_ get: (Frame) -> Double, _ set: (inout Frame, Double) -> Void, tau: Double) {
            let a = 1 - exp(-blockDuration / tau)
            guard frames.count > 1 else { return }
            var y = get(frames[0])
            for i in frames.indices { y += a * (get(frames[i]) - y); set(&frames[i], y) }
            y = get(frames[frames.count - 1])
            for i in frames.indices.reversed() { y += a * (get(frames[i]) - y); set(&frames[i], y) }
        }
        pass({ $0.f1 }, { $0.f1 = $1 }, tau: 0.018)
        pass({ $0.f2 }, { $0.f2 = $1 }, tau: 0.022)
        pass({ $0.f3 }, { $0.f3 = $1 }, tau: 0.022)
        pass({ $0.b1 }, { $0.b1 = $1 }, tau: 0.015)
        pass({ $0.b2 }, { $0.b2 = $1 }, tau: 0.015)
        pass({ $0.b3 }, { $0.b3 = $1 }, tau: 0.015)
        pass({ $0.nasal }, { $0.nasal = $1 }, tau: 0.012)
        pass({ $0.voicing }, { $0.voicing = $1 }, tau: 0.006)
        pass({ $0.frication }, { $0.frication = $1 }, tau: 0.003)
        pass({ $0.aspiration }, { $0.aspiration = $1 }, tau: 0.006)
        pass({ $0.fricationCenter }, { $0.fricationCenter = $1 }, tau: 0.01)
    }

    private func interpolate(_ values: [Float], at position: Double) -> Double {
        guard !values.isEmpty else { return 0 }
        let p = max(0, min(Double(values.count - 1), position))
        let i = Int(p)
        let j = min(values.count - 1, i + 1)
        let f = p - Double(i)
        return Double(values[i]) * (1 - f) + Double(values[j]) * f
    }
}

@inline(__always) private func lerp(_ a: Double, _ b: Double, _ x: Double) -> Double { a + (b - a) * x }
@inline(__always) private func smooth01(_ x: Double) -> Double {
    let c = min(1, max(0, x))
    return c * c * (3 - 2 * c)
}
