import Foundation
import Testing
import ISingItEngine

/// Golden-render regression test.
///
/// Renders `Fixtures/MusicXML/twinkle.musicxml` with two voices and compares a compact
/// feature set against references in `Tests/ISingItEngineTests/Golden/*.json`:
///   - per-note median f0, in cents relative to the written pitch  (tolerance 25 cents)
///   - onset times of voiced regions                               (tolerance 15 ms)
///   - RMS loudness per 50 ms frame, in dB                         (tolerance 2 dB)
/// so audio changes are caught without byte-exact matching.
///
/// To regenerate the references after an intentional audio change:
///
///     ISINGIT_UPDATE_GOLDEN=1 swift test --filter RenderGoldenTests
///
/// then review and commit the changed JSON files.
@Suite struct RenderGoldenTests {
    struct Features: Codable {
        var voice: String
        var sampleRate: Double
        var noteCentsError: [Double?]
        var voicedOnsets: [Double]
        var loudnessDB: [Double]
    }

    static let pitchTolerance = 25.0
    static let onsetTolerance = 0.015
    static let loudnessTolerance = 2.0
    static let silenceFloorDB = -60.0
    static let goldenDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Golden")

    static func features(voice: VoiceProfile) async throws -> Features {
        let score = try TestSupport.importFixture("MusicXML/twinkle.musicxml")
        var settings = RenderSettings()
        settings.voice = voice
        settings.sampleRate = 22_050
        let result = await Renderer().render(score, settings: settings)
        let rate = settings.sampleRate
        let x = result.audio.samples

        // Per-note median f0 over the middle half of the note.
        var errors: [Double?] = []
        for note in score.notes {
            let a = score.tempoMap.seconds(atBeat: note.onset) + result.plan.leadIn
            let b = score.tempoMap.seconds(atBeat: note.endBeat) + result.plan.leadIn
            let from = a + 0.25 * (b - a), to = b - 0.25 * (b - a)
            var estimates: [Double] = []
            var t = from
            while t + 0.04 <= to {
                let s = Int(t * rate)
                if let f = TestSupport.estimateF0(x[s..<(s + Int(0.04 * rate))], sampleRate: rate) { estimates.append(f) }
                t += 0.02
            }
            errors.append(TestSupport.median(estimates).map { round(TestSupport.cents($0, vs: TestSupport.hz(midi: note.pitch)) * 10) / 10 })
        }

        // Voiced regions: 10 ms hops, 30 ms windows, loud enough and periodic.
        let hop = Int(0.01 * rate), win = Int(0.03 * rate)
        let peak = Double(result.audio.peak)
        var onsets: [Double] = []
        var wasVoiced = false
        var start = 0
        while start + win <= x.count {
            let slice = x[start..<(start + win)]
            let rms = (slice.reduce(0.0) { $0 + Double($1) * Double($1) } / Double(win)).squareRoot()
            let voiced = rms > 0.05 * peak && TestSupport.estimateF0(slice, sampleRate: rate, minCorrelation: 0.6) != nil
            if voiced && !wasVoiced { onsets.append(round(Double(start) / rate * 1000) / 1000) }
            wasVoiced = voiced
            start += hop
        }

        // Loudness per 50 ms frame.
        let frame = Int(0.05 * rate)
        var loudness: [Double] = []
        var i = 0
        while i + frame <= x.count {
            let rms = (x[i..<(i + frame)].reduce(0.0) { $0 + Double($1) * Double($1) } / Double(frame)).squareRoot()
            loudness.append(round(max(silenceFloorDB, 20 * log10(max(rms, 1e-9))) * 10) / 10)
            i += frame
        }
        return Features(voice: voice.id, sampleRate: rate, noteCentsError: errors, voicedOnsets: onsets, loudnessDB: loudness)
    }

    @Test(arguments: [VoiceProfile.dspSoprano, VoiceProfile.dspTenor])
    func matchesGolden(voice: VoiceProfile) async throws {
        let actual = try await Self.features(voice: voice)
        let url = Self.goldenDirectory.appendingPathComponent("twinkle-\(voice.id).json")

        if ProcessInfo.processInfo.environment["ISINGIT_UPDATE_GOLDEN"] == "1" {
            try FileManager.default.createDirectory(at: Self.goldenDirectory, withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(actual).write(to: url)
            return
        }

        let data = try #require(try? Data(contentsOf: url),
                                "Missing \(url.lastPathComponent); run with ISINGIT_UPDATE_GOLDEN=1 to create it")
        let golden = try JSONDecoder().decode(Features.self, from: data)

        #expect(actual.noteCentsError.count == golden.noteCentsError.count)
        for (i, (a, g)) in zip(actual.noteCentsError, golden.noteCentsError).enumerated() {
            switch (a, g) {
            case (let a?, let g?): #expect(abs(a - g) <= Self.pitchTolerance, "note \(i): \(a) vs golden \(g) cents")
            case (nil, nil): break
            default: Issue.record("note \(i): pitch detected = \(a != nil), golden detected = \(g != nil)")
            }
        }

        #expect(actual.voicedOnsets.count == golden.voicedOnsets.count,
                "voiced region count \(actual.voicedOnsets.count) vs golden \(golden.voicedOnsets.count)")
        for (i, (a, g)) in zip(actual.voicedOnsets, golden.voicedOnsets).enumerated() {
            #expect(abs(a - g) <= Self.onsetTolerance, "onset \(i): \(a) s vs golden \(g) s")
        }

        #expect(abs(actual.loudnessDB.count - golden.loudnessDB.count) <= 1, "length differs")
        for (i, (a, g)) in zip(actual.loudnessDB, golden.loudnessDB).enumerated() {
            #expect(abs(a - g) <= Self.loudnessTolerance, "frame \(i) (\(Double(i) * 0.05) s): \(a) dB vs golden \(g) dB")
        }
    }

    @Test func goldenFeaturesAreSane() async throws {
        let f = try await Self.features(voice: .dspSoprano)
        #expect(f.noteCentsError.count == 14)
        #expect(f.noteCentsError.allSatisfy { $0 != nil })
        #expect(f.voicedOnsets.count >= 1)
        #expect(f.loudnessDB.max()! > -40)
    }
}
