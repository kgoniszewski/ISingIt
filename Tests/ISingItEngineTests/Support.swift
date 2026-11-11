import Foundation
import ISingItEngine

/// Shared helpers for the engine tests.
enum TestSupport {
    /// Repo root, found by walking up from this file until Package.swift appears.
    static let repoRoot: URL = {
        var url = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        while url.path != "/" {
            if FileManager.default.fileExists(atPath: url.appendingPathComponent("Package.swift").path) { return url }
            url.deleteLastPathComponent()
        }
        fatalError("Package.swift not found above \(#filePath)")
    }()

    static func fixture(_ relativePath: String) -> URL {
        repoRoot.appendingPathComponent("Fixtures").appendingPathComponent(relativePath)
    }

    static func fixtureData(_ relativePath: String) throws -> Data {
        try Data(contentsOf: fixture(relativePath))
    }

    static func importFixture(_ relativePath: String, part: String? = nil) throws -> Score {
        try ScoreImporter.importFile(at: fixture(relativePath), part: part)
    }

    /// Builds a score from (pitch, onset beat, duration beats, lyric text or nil) tuples.
    /// Lyric kind is `.single`; use `kind` for multi-syllable words.
    static func score(
        bpm: Double = 60, _ notes: [(pitch: Int, onset: Double, duration: Double, lyric: String?)]
    ) -> Score {
        var s = Score(tempoMap: TempoMap(bpm: bpm))
        s.notes = notes.enumerated().map { i, n in
            Note(id: i + 1, pitch: n.pitch, onset: n.onset, duration: n.duration,
                 lyric: n.lyric.map { Syllable(text: $0) })
        }
        return s
    }

    static func cents(_ f: Double, vs reference: Double) -> Double { 1200 * log2(f / reference) }

    static func hz(midi: Int) -> Double { 440 * pow(2, (Double(midi) - 69) / 12) }

    /// Fundamental frequency of `samples` by normalized autocorrelation with parabolic
    /// interpolation; nil when unvoiced. Searches 70...1000 Hz.
    static func estimateF0(_ samples: ArraySlice<Float>, sampleRate: Double, minCorrelation: Double = 0.5) -> Double? {
        let x = Array(samples)
        let minLag = Int(sampleRate / 1000), maxLag = min(x.count / 2, Int(sampleRate / 70))
        guard maxLag > minLag + 2 else { return nil }
        var energy = 0.0
        for v in x { energy += Double(v) * Double(v) }
        guard energy > 1e-9 else { return nil }
        var corr = [Double](repeating: 0, count: maxLag + 2)
        for lag in minLag...(maxLag + 1) where lag < x.count {
            var sum = 0.0
            for i in 0..<(x.count - lag) { sum += Double(x[i]) * Double(x[i + lag]) }
            corr[lag] = sum / energy
        }
        // First strong local maximum, to avoid octave errors.
        let best = (minLag...maxLag).map { corr[$0] }.max() ?? 0
        guard best >= minCorrelation else { return nil }
        for lag in (minLag + 1)...maxLag where corr[lag] >= 0.9 * best && corr[lag] >= corr[lag - 1] && corr[lag] >= corr[lag + 1] {
            let a = corr[lag - 1], b = corr[lag], c = corr[lag + 1]
            let denom = a - 2 * b + c
            let shift = abs(denom) > 1e-12 ? 0.5 * (a - c) / denom : 0
            return sampleRate / (Double(lag) + shift)
        }
        return nil
    }

    static func median(_ values: [Double]) -> Double? {
        guard !values.isEmpty else { return nil }
        let s = values.sorted()
        return s.count % 2 == 1 ? s[s.count / 2] : 0.5 * (s[s.count / 2 - 1] + s[s.count / 2])
    }
}
