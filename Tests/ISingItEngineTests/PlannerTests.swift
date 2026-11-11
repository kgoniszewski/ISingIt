import Foundation
import Testing
import ISingItEngine

@Suite struct PlannerTests {
    func plan(_ score: Score, _ settings: PerformanceSettings = PerformanceSettings()) -> PerformancePlan {
        Renderer().plan(score, settings: { var s = RenderSettings(); s.performance = settings; return s }())
    }

    @Test func phrasesSplitAtRests() throws {
        let score = TestSupport.score([
            (60, 0, 1, "la"), (62, 1, 1, "la"), (64, 2, 1, "la"),
            (65, 4, 1, "la"), (67, 5, 1, "la"),   // 1 s rest at 60 bpm
        ])
        let p = plan(score)
        #expect(p.phrases.count == 2)
        #expect(p.phrases[0].noteRange == 0...2)
        #expect(p.phrases[1].noteRange == 3...4)
        // Contiguous song stays one phrase.
        let twinkle = plan(try TestSupport.importFixture("MusicXML/twinkle.musicxml"))
        #expect(twinkle.phrases.count == 1)
        // A tiny phraseBreak splits at every gap but not at joined notes.
        var s = PerformanceSettings(); s.phraseBreak = 0.05
        #expect(plan(score, s).phrases.count == 2)
        // A huge phraseBreak merges.
        s.phraseBreak = 5
        #expect(plan(score, s).phrases.count == 1)
    }

    @Test func consonantsPrecedeOnsetVowelOnBeat() throws {
        let score = try TestSupport.importFixture("MusicXML/twinkle.musicxml")
        let prepared = Renderer().prepare(score)
        let p = Renderer().plan(score, settings: RenderSettings())
        let phrase = try #require(p.phrases.first)
        var checkedWithConsonant = 0
        for (i, note) in prepared.notes.enumerated() {
            let onsetSeconds = prepared.tempoMap.seconds(atBeat: note.onset)
            let segments = phrase.segments.filter { $0.noteIndex == i }
            let vowel = try #require(segments.first(where: { Phonemes.isVowel($0.phoneme) }), "note \(i)")
            #expect(abs((vowel.start + phrase.startTime) - onsetSeconds) < 0.001, "note \(i)")
            if let first = segments.first, first.phoneme != vowel.phoneme {
                checkedWithConsonant += 1
                #expect(first.start + phrase.startTime < onsetSeconds)
            }
        }
        #expect(checkedWithConsonant >= 8)
        // Segments are ordered and non-overlapping.
        for (a, b) in zip(phrase.segments, phrase.segments.dropFirst()) { #expect(a.end <= b.start + 1e-9) }
    }

    @Test func leadInWhenFirstSyllableStartsWithConsonant() throws {
        let score = TestSupport.score([(60, 0, 2, "star"), (62, 2, 2, "far")])
        let p = plan(score)
        #expect(p.leadIn > 0)
        #expect(p.phrases[0].startTime < 0)
        let vowelOnset = try #require(p.phrases[0].segments.first(where: { Phonemes.isVowel($0.phoneme) }))
        #expect(abs(vowelOnset.start + p.phrases[0].startTime) < 0.001)
        // A vowel-initial first syllable still has a small window before it (lead).
        let vowelFirst = plan(TestSupport.score([(60, 0, 2, "ah")]))
        #expect(vowelFirst.leadIn >= 0)
        #expect(vowelFirst.duration > 0)
    }

    @Test func f0FollowsPitch() throws {
        let score = try TestSupport.importFixture("MusicXML/twinkle.musicxml")
        let p = Renderer().plan(score, settings: RenderSettings())
        let phrase = p.phrases[0]
        for (i, note) in score.notes.enumerated() {
            let a = score.tempoMap.seconds(atBeat: note.onset), b = score.tempoMap.seconds(atBeat: note.endBeat)
            let mid = 0.5 * (a + b)
            let frame = Int(((mid - phrase.startTime) * phrase.frameRate).rounded())
            let f = Double(phrase.f0[frame])
            #expect(abs(TestSupport.cents(f, vs: TestSupport.hz(midi: note.pitch))) < 40, "note \(i): \(f) Hz")
        }
    }

    @Test func transposeAndTempoScale() {
        let score = TestSupport.score([(60, 0, 2, "la")])
        var s = PerformanceSettings()
        s.transpose = 12; s.vibratoDepthCents = 0; s.pitchDriftCents = 0
        let phrase = plan(score, s).phrases[0]
        let mid = phrase.f0[phrase.f0.count / 2]
        #expect(abs(TestSupport.cents(Double(mid), vs: TestSupport.hz(midi: 72))) < 5)
        let normal = plan(score).duration
        var fast = PerformanceSettings(); fast.tempoScale = 2
        #expect(plan(score, fast).duration < normal)
    }

    @Test func emptyScore() {
        let p = plan(Score())
        #expect(p.phrases.isEmpty)
        #expect(p.duration == 0)
    }

    @Test func settingsApplyingAndKeys() throws {
        let keys = PerformanceSettings.keys
        for k in ["transpose", "tempoScale", "vibratoDepthCents", "phraseBreak", "portamento", "pitchDriftCents"] {
            #expect(keys.contains(k), "\(k)")
        }
        #expect(keys == keys.sorted())
        let s = try PerformanceSettings().applying(["vibratoDepthCents": 40, "phraseBreak": 0.5])
        #expect(s.vibratoDepthCents == 40)
        #expect(s.phraseBreak == 0.5)
        #expect(s.vibratoRateHz == PerformanceSettings().vibratoRateHz)
        #expect(try PerformanceSettings().applying([:]) == PerformanceSettings())
        #expect(throws: SettingsError.self) { try PerformanceSettings().applying(["nope": 1]) }
    }
}
