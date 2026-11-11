import Foundation
import Testing
import ISingItEngine

@Suite struct RenderTests {
    /// Two phrases separated by a 2-beat rest (2 s at 60 bpm, far above the 0.25 s break).
    func twoPhraseScore() -> Score {
        TestSupport.score([
            (60, 0, 1, "la"), (62, 1, 1, "la"),
            (64, 4, 1, "la"), (65, 5, 1, "la"),
        ])
    }

    var fast: RenderSettings { var s = RenderSettings(); s.sampleRate = 16_000; return s }

    @Test func secondRenderIsFullyCached() async {
        let renderer = Renderer()
        let score = twoPhraseScore()
        let first = await renderer.render(score, settings: fast)
        #expect(first.plan.phrases.count == 2)
        #expect(first.phrasesRendered == 2)
        #expect(first.cacheHits == 0)
        let second = await renderer.render(score, settings: fast)
        #expect(second.cacheHits == second.plan.phrases.count)
        #expect(second.phrasesRendered == 0)
        #expect(second.audio.samples == first.audio.samples)
        #expect(await renderer.cache.count == 2)
    }

    @Test func editingOneNoteRerendersOnePhrase() async {
        let renderer = Renderer()
        var score = twoPhraseScore()
        _ = await renderer.render(score, settings: fast)
        score.notes[3].pitch += 2
        let edited = await renderer.render(score, settings: fast)
        #expect(edited.phrasesRendered == 1)
        #expect(edited.cacheHits == 1)
        // And editing the first phrase leaves the second cached.
        score.notes[0].pitch += 1
        let again = await renderer.render(score, settings: fast)
        #expect(again.phrasesRendered == 1)
        #expect(again.cacheHits == 1)
    }

    @Test func settingsChangeInvalidatesCache() async {
        let renderer = Renderer()
        let score = twoPhraseScore()
        _ = await renderer.render(score, settings: fast)
        var other = fast; other.voice = .dspBass
        let r = await renderer.render(score, settings: other)
        #expect(r.phrasesRendered == 2)
        #expect(r.cacheHits == 0)
    }

    @Test func cacheEvictsAtCapacity() async {
        let cache = PhraseCache(capacity: 2)
        await cache.put(1, [1]); await cache.put(2, [2]); await cache.put(3, [3])
        #expect(await cache.count == 2)
        #expect(await cache.get(1) == nil)
        #expect(await cache.get(3) == [3])
        await cache.removeAll()
        #expect(await cache.count == 0)
    }

    @Test func normalizeSetsPeakAndLengthMatchesPlan() async {
        var s = fast; s.normalize = true
        let r = await Renderer().render(twoPhraseScore(), settings: s)
        #expect(abs(r.audio.peak - 0.89) < 1e-3)
        #expect(r.audio.duration >= r.plan.duration - 0.01)
        #expect(r.realTimeFactor >= 0)
        #expect(!ISingIt.engineVersion.isEmpty)
    }
}
