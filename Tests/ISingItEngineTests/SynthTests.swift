import Foundation
import Testing
import ISingItEngine

@Suite struct SynthTests {
    func steadySettings() -> RenderSettings {
        var s = RenderSettings()
        s.sampleRate = 22_050
        s.performance.vibratoDepthCents = 0
        s.performance.pitchDriftCents = 0
        return s
    }

    @Test func renderIsDeterministicFiniteAndBounded() async throws {
        let score = try TestSupport.importFixture("MusicXML/twinkle.musicxml")
        var settings = RenderSettings(); settings.sampleRate = 22_050
        let a = await Renderer().render(score, settings: settings)
        let b = await Renderer().render(score, settings: settings)
        #expect(a.audio.samples == b.audio.samples)
        #expect(a.audio.samples.allSatisfy { $0.isFinite })
        #expect(a.audio.peak > 0.05)
        #expect(a.audio.peak <= 1.0)
        #expect(a.audio.rms > 0.005)
        #expect(a.audio.duration > 8)
        // Direct voice rendering is deterministic too.
        let voice = FormantVoice(profile: .dspTenor)
        let phrase = try #require(a.plan.phrases.first)
        #expect(voice.render(phrase, sampleRate: 22_050) == voice.render(phrase, sampleRate: 22_050))
        #expect(voice.render(phrase, sampleRate: 22_050).count == Int((phrase.duration * 22_050).rounded(.up))
                || abs(voice.render(phrase, sampleRate: 22_050).count - Int(phrase.duration * 22_050)) <= 2)
    }

    @Test func voicesDiffer() async throws {
        let score = TestSupport.score([(60, 0, 2, "ah")])
        var s = steadySettings()
        let soprano = await Renderer().render(score, settings: s)
        s.voice = .dspTenor
        let tenor = await Renderer().render(score, settings: s)
        #expect(soprano.audio.samples != tenor.audio.samples)
        #expect(VoiceProfile.named("tenor") == .dspTenor)
        #expect(VoiceProfile.named("dsp-bass") == .dspBass)
        #expect(VoiceProfile.named("nobody") == nil)
    }

    @Test(arguments: [57, 60, 64, 69])
    func sustainedVowelPitch(midi: Int) async throws {
        let score = TestSupport.score([(midi, 0, 4, "ah")])
        let settings = steadySettings()
        let result = await Renderer().render(score, settings: settings)
        let rate = settings.sampleRate
        let start = Int((result.plan.leadIn + 1.2) * rate)
        let window = result.audio.samples[start..<(start + Int(0.1 * rate))]
        let f0 = try #require(TestSupport.estimateF0(window, sampleRate: rate))
        let error = TestSupport.cents(f0, vs: TestSupport.hz(midi: midi))
        #expect(abs(error) < 30, "midi \(midi): \(f0) Hz, \(error) cents")
    }

    @Test func silenceForEmptyPlan() async {
        let result = await Renderer().render(Score())
        #expect(result.audio.samples.isEmpty || result.audio.peak == 0)
    }
}
