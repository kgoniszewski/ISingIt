import Foundation
import ISingItLyrics
import ISingItScore

/// Performance.Planner: turns a score with phonemes into timed phoneme segments and
/// frame-level pitch, loudness and breath curves, phrase by phrase.
///
/// Singers start consonants before the beat so the vowel lands on it; the planner does
/// the same, borrowing the time from the previous note (or from the rest before it).
public struct PerformancePlanner: Sendable {
    public var settings: PerformanceSettings
    public static let frameRate = 200.0
    /// Syllable sung on notes that have no lyric.
    public static let defaultSyllable = ["L", "AA"]

    public init(settings: PerformanceSettings = PerformanceSettings()) {
        self.settings = settings
    }

    /// A syllable together with the notes it is sung over (more than one for a melisma).
    struct Unit {
        var notes: [Int]
        var start: Double
        var end: Double
        var onset: [String]
        var nucleus: [String]
        var coda: [String]
    }

    public func plan(_ score: Score) -> PerformancePlan {
        let tempo = score.tempoMap.scaled(by: settings.tempoScale)
        let times = score.notes.map { (tempo.seconds(atBeat: $0.onset), tempo.seconds(atBeat: $0.endBeat)) }
        let units = makeUnits(score, times: times)
        guard !units.isEmpty else { return PerformancePlan(phrases: [], duration: 0) }

        // Split into phrases at rests.
        var phrases: [[Unit]] = [[units[0]]]
        for unit in units.dropFirst() {
            if unit.start - phrases[phrases.count - 1].last!.end >= settings.phraseBreak {
                phrases.append([unit])
            } else {
                phrases[phrases.count - 1].append(unit)
            }
        }
        var plans: [PhrasePlan] = []
        // The first phrase may start before time zero (consonants before the first beat);
        // the renderer adds that lead-in to the front of the audio.
        var previousEnd = -0.5
        for phraseUnits in phrases {
            let plan = planPhrase(phraseUnits, score: score, times: times, tempo: tempo, earliestStart: previousEnd)
            plans.append(plan)
            previousEnd = plan.startTime + plan.duration - 0.12
        }
        let leadIn = max(0, -(plans.map(\.startTime).min() ?? 0))
        return PerformancePlan(phrases: plans, duration: (plans.map(\.endTime).max() ?? 0) + leadIn, leadIn: leadIn)
    }

    // MARK: - Units

    func makeUnits(_ score: Score, times: [(Double, Double)]) -> [Unit] {
        var units: [Unit] = []
        for (i, note) in score.notes.enumerated() {
            let joined = i > 0 && abs(times[i - 1].1 - times[i].0) < 1e-4
            if note.continuesSyllable && joined && !units.isEmpty && note.lyric == nil {
                units[units.count - 1].notes.append(i)
                units[units.count - 1].end = times[i].1
                continue
            }
            var phonemes = note.lyric?.phonemes ?? []
            if phonemes.isEmpty, let lyric = note.lyric {
                // G2P has not run: convert this syllable on its own.
                phonemes = EnglishG2P.shared.phonemes(for: lyric.text)
            }
            if phonemes.isEmpty || !phonemes.contains(where: Phonemes.isVowel) {
                phonemes = (phonemes.isEmpty ? Self.defaultSyllable : phonemes + ["AH"])
            }
            let first = phonemes.firstIndex(where: Phonemes.isVowel)!
            let last = phonemes.lastIndex(where: Phonemes.isVowel)!
            units.append(Unit(
                notes: [i], start: times[i].0, end: times[i].1,
                onset: Array(phonemes[..<first]), nucleus: Array(phonemes[first...last]),
                coda: Array(phonemes[(last + 1)...])))
        }
        return units
    }

    func baseDuration(_ phoneme: String) -> Double {
        let d: Double = switch Phonemes.class(of: phoneme) {
        case .stop: 0.075
        case .affricate: 0.10
        case .fricative: ["S", "SH", "Z", "ZH"].contains(phoneme) ? 0.11 : 0.085
        case .nasal: 0.075
        case .liquid: 0.065
        case .glide: 0.055
        case .aspirate: 0.065
        case .vowel: 0.12
        case .silence: 0.05
        }
        return d * settings.consonantScale
    }

    // MARK: - Phrase

    func planPhrase(_ units: [Unit], score: Score, times: [(Double, Double)], tempo: TempoMap, earliestStart: Double) -> PhrasePlan {
        // 1. Absolute phoneme timing.
        struct Timed { var phoneme: String; var start: Double; var end: Double; var note: Int }
        var timed: [Timed] = []
        var onsetLengths: [Double] = []
        for (k, unit) in units.enumerated() {
            let wanted = unit.onset.map(baseDuration).reduce(0, +)
            let room: Double
            if k == 0 {
                room = max(0.03, min(0.35, unit.start - earliestStart))
            } else {
                let previous = units[k - 1]
                let gap = max(0, unit.start - previous.end)
                room = gap + 0.5 * (previous.end - previous.start)
            }
            onsetLengths.append(min(wanted, room))
        }
        for (k, unit) in units.enumerated() {
            let length = unit.end - unit.start
            let nextOnset = k + 1 < units.count ? onsetLengths[k + 1] : 0
            let nextStart = k + 1 < units.count ? units[k + 1].start : Double.infinity
            // Vowel ends where the next syllable's consonants begin (if they overlap this note).
            let singEnd = min(unit.end, nextStart - nextOnset)
            let codaWanted = unit.coda.map(baseDuration).reduce(0, +)
            let codaLength = min(codaWanted, 0.3 * length, max(0, singEnd - unit.start - 0.04))
            let codaEnd = (k + 1 < units.count && nextStart - unit.end < 0.02) ? singEnd : unit.end

            // Onset consonants, just before the beat.
            let onsetWanted = unit.onset.map(baseDuration).reduce(0, +)
            let onsetScale = onsetWanted > 0 ? onsetLengths[k] / onsetWanted : 0
            var t = unit.start - onsetLengths[k]
            for p in unit.onset {
                let d = baseDuration(p) * onsetScale
                timed.append(Timed(phoneme: p, start: t, end: t + d, note: unit.notes[0]))
                t += d
            }
            // Nucleus: vowels share the time; interior consonants keep short lengths.
            let nucleusStart = unit.start
            let nucleusEnd = max(nucleusStart + 0.03, codaEnd - codaLength)
            let available = nucleusEnd - nucleusStart
            let interior = unit.nucleus.filter { !Phonemes.isVowel($0) }
            let interiorLength = min(0.3 * available, interior.map(baseDuration).reduce(0, +))
            let interiorScale = interior.isEmpty ? 0 : interiorLength / interior.map(baseDuration).reduce(0, +)
            let vowelCount = unit.nucleus.filter(Phonemes.isVowel).count
            let vowelLength = (available - interiorLength) / Double(max(1, vowelCount))
            t = nucleusStart
            for p in unit.nucleus {
                let d = Phonemes.isVowel(p) ? vowelLength : baseDuration(p) * interiorScale
                // Attribute the vowel to the note sounding at its start (for melismas the
                // pitch curve follows the notes anyway).
                let note = unit.notes.last(where: { times[$0].0 <= t + 1e-6 }) ?? unit.notes[0]
                timed.append(Timed(phoneme: p, start: t, end: t + d, note: note))
                t += d
            }
            // Coda consonants at the end of the last note.
            let codaScale = codaWanted > 0 ? codaLength / codaWanted : 0
            for p in unit.coda {
                let d = baseDuration(p) * codaScale
                timed.append(Timed(phoneme: p, start: t, end: t + d, note: unit.notes.last!))
                t += d
            }
        }

        // 2. Phrase window.
        let lead = 0.04
        let tail = 0.25
        let phraseStart = (timed.first?.start ?? units[0].start) - lead
        let phraseEnd = (timed.last?.end ?? units.last!.end) + tail
        let frameCount = Int(((phraseEnd - phraseStart) * Self.frameRate).rounded(.up)) + 1
        let segments = timed.map {
            PhonemeSegment(phoneme: $0.phoneme, start: $0.start - phraseStart, end: $0.end - phraseStart, noteIndex: $0.note)
        }

        // 3. Curves.
        let noteIndices = units.flatMap(\.notes)
        let notes = noteIndices.map { (index: $0, start: times[$0].0, end: times[$0].1, pitch: Double(score.notes[$0].pitch) + settings.transpose) }
        let soundEnd = timed.last?.end ?? units.last!.end
        var f0 = [Float](repeating: 0, count: frameCount)
        var loudness = [Float](repeating: 0, count: frameCount)
        var breath = [Float](repeating: 0, count: frameCount)
        let seed = Double(noteIndices.first ?? 0) * 1.618
        for frame in 0..<frameCount {
            let t = phraseStart + Double(frame) / Self.frameRate
            f0[frame] = Float(440 * pow(2, (pitch(at: t, notes: notes, seed: seed) - 69) / 12))

            // Loudness: note velocity and score dynamics, a soft attack, a gentle decay
            // on long notes and a release at the end of the phrase.
            let n = notes.last(where: { $0.start <= t + 0.03 }) ?? notes[0]
            let note = score.notes[n.index]
            let dynamic = score.dynamic(atBeat: note.onset)?.gain ?? Dynamic.mf.gain
            let velocity = pow(Double(note.velocity) / 100.0, 0.6)
            var level = dynamic * velocity
            let sinceOnset = t - n.start
            if sinceOnset > 0 { level *= 1 - 0.12 * min(1, sinceOnset / 2.5) }
            let attack = smoothstep((t - (phraseStart + lead)) / 0.05)
            let release = 1 - smoothstep((t - soundEnd + 0.02) / 0.1)
            loudness[frame] = Float(max(0, level * attack * release))

            let toEnd = soundEnd - t
            breath[frame] = Float(settings.breathiness + 0.18 * (1 - smoothstep(toEnd / 0.2)))
        }

        return PhrasePlan(
            startTime: phraseStart, duration: phraseEnd - phraseStart, frameRate: Self.frameRate,
            segments: segments, f0: f0, loudness: loudness, breathiness: breath,
            noteRange: (noteIndices.min() ?? 0)...(noteIndices.max() ?? 0))
    }

    /// Pitch in MIDI semitones at time t: note targets with legato glides, a scoop into
    /// the first note, delayed vibrato on long notes and a slow random drift.
    func pitch(at t: Double, notes: [(index: Int, start: Double, end: Double, pitch: Double)], seed: Double) -> Double {
        var k = notes.lastIndex(where: { $0.start <= t }) ?? 0
        if k < 0 { k = 0 }
        let current = notes[k]
        var value = current.pitch

        // Glide from the previous note when they are joined.
        if k > 0 {
            let previous = notes[k - 1]
            let joined = current.start - previous.end < 0.03
            let glide = settings.portamento
            if joined {
                let x = (t - current.start + 0.3 * glide) / glide
                value = previous.pitch + (current.pitch - previous.pitch) * smoothstep(x)
            }
        }
        // Anticipate the next note's glide start.
        if k + 1 < notes.count {
            let next = notes[k + 1]
            if next.start - current.end < 0.03 {
                let glide = settings.portamento
                let x = (t - next.start + 0.3 * glide) / glide
                if x > 0 { value = current.pitch + (next.pitch - current.pitch) * smoothstep(x) }
            }
        }
        // Scoop into a note that starts after a rest.
        let isPhraseStart = k == 0 || current.start - notes[k - 1].end >= 0.03
        if isPhraseStart {
            let x = (t - current.start + 0.02) / 0.1
            value -= 0.35 * (1 - smoothstep(x))
        }
        // Vibrato.
        let length = current.end - current.start
        if length >= settings.vibratoMinNote {
            let onset = min(settings.vibratoOnset, length * 0.45)
            let ramp = smoothstep((t - current.start - onset) / 0.25) * (1 - smoothstep((t - current.end + 0.08) / 0.08))
            value += ramp * settings.vibratoDepthCents / 100 * sin(2 * .pi * settings.vibratoRateHz * (t - current.start - onset))
        }
        // Drift.
        value += settings.pitchDriftCents / 100 * (0.6 * sin(2 * .pi * 0.7 * t + seed) + 0.4 * sin(2 * .pi * 1.9 * t + 2 * seed))
        return value
    }
}

@inline(__always)
func smoothstep(_ x: Double) -> Double {
    let c = min(1, max(0, x))
    return c * c * (3 - 2 * c)
}
