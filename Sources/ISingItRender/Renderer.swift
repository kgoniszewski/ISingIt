import Foundation
import ISingItAudio
import ISingItLyrics
import ISingItPerformance
import ISingItScore
import ISingItSynth

/// Everything that changes how a score is rendered, other than the score itself.
public struct RenderSettings: Codable, Sendable, Equatable {
    public var voice: VoiceProfile = .dspSoprano
    public var sampleRate: Double = 44_100
    public var performance = PerformanceSettings()
    /// Scale the final mix so its peak is at -1 dBFS (CLI exports). Off in the editor so
    /// the level does not jump while editing.
    public var normalize = false

    public init() {}
}

public struct RenderResult: Sendable {
    public var audio: AudioBuffer
    public var plan: PerformancePlan
    public var phrasesRendered: Int
    public var cacheHits: Int
    public var renderSeconds: Double

    /// Render time divided by audio length (below 1 is faster than real time).
    public var realTimeFactor: Double { audio.duration > 0 ? renderSeconds / audio.duration : 0 }
}

/// Caches rendered phrases by content hash, so an edit only re-renders the phrases it
/// touched.
public actor PhraseCache {
    private var entries: [UInt64: [Float]] = [:]
    private var order: [UInt64] = []
    public let capacity: Int

    public init(capacity: Int = 512) {
        self.capacity = capacity
    }

    public func get(_ key: UInt64) -> [Float]? { entries[key] }

    public func put(_ key: UInt64, _ samples: [Float]) {
        if entries[key] == nil { order.append(key) }
        entries[key] = samples
        while order.count > capacity { entries[order.removeFirst()] = nil }
    }

    public var count: Int { entries.count }

    public func removeAll() {
        entries.removeAll()
        order.removeAll()
    }
}

/// Render: score in, audio out. Runs G2P, plans the performance, renders phrases in
/// parallel through the voice, and mixes them on the timeline.
public struct Renderer: Sendable {
    public static let engineVersion = "0.1.0"
    public let cache: PhraseCache

    public init(cache: PhraseCache = PhraseCache()) {
        self.cache = cache
    }

    /// Fills in phonemes the score does not have yet.
    public func prepare(_ score: Score) -> Score {
        var prepared = score
        Phonemizer(language: score.language).apply(to: &prepared)
        return prepared
    }

    public func plan(_ score: Score, settings: RenderSettings) -> PerformancePlan {
        PerformancePlanner(settings: settings.performance).plan(prepare(score))
    }

    public func render(_ score: Score, settings: RenderSettings = RenderSettings()) async -> RenderResult {
        let started = Date()
        let plan = plan(score, settings: settings)
        let voice = FormantVoice(profile: settings.voice)
        let keys = plan.phrases.map { Self.cacheKey($0, settings: settings) }

        var rendered: [Int: [Float]] = [:]
        var hits = 0
        for (i, key) in keys.enumerated() {
            if let cached = await cache.get(key) {
                rendered[i] = cached
                hits += 1
            }
        }
        let missing = plan.phrases.indices.filter { rendered[$0] == nil }
        await withTaskGroup(of: (Int, [Float]).self) { group in
            for i in missing {
                let phrase = plan.phrases[i]
                group.addTask { (i, voice.render(phrase, sampleRate: settings.sampleRate)) }
            }
            for await (i, samples) in group {
                rendered[i] = samples
                await cache.put(keys[i], samples)
            }
        }

        var audio = AudioBuffer(sampleRate: settings.sampleRate, duration: plan.duration)
        for (i, phrase) in plan.phrases.enumerated() {
            audio.mix(rendered[i] ?? [], at: phrase.startTime + plan.leadIn)
        }
        if settings.normalize { audio.normalize() }
        return RenderResult(
            audio: audio, plan: plan, phrasesRendered: missing.count, cacheHits: hits,
            renderSeconds: Date().timeIntervalSince(started))
    }

    /// FNV-1a over the phrase plan, voice and sample rate, so equal input gives equal key.
    public static func cacheKey(_ phrase: PhrasePlan, settings: RenderSettings) -> UInt64 {
        var hash: UInt64 = 0xCBF2_9CE4_8422_2325
        func feed<T>(_ value: T) {
            withUnsafeBytes(of: value) { raw in
                for byte in raw {
                    hash ^= UInt64(byte)
                    hash = hash &* 0x0000_0100_0000_01B3
                }
            }
        }
        func feed(_ string: String) {
            for byte in string.utf8 { feed(byte) }
            feed(UInt8(0))
        }
        feed(engineVersion)
        feed(settings.voice.id)
        feed(settings.voice.formantScale)
        feed(settings.voice.openQuotient)
        feed(settings.voice.breathiness)
        feed(settings.sampleRate)
        feed(phrase.duration)
        feed(phrase.startTime.truncatingRemainder(dividingBy: 1000))  // seeds the noise
        for segment in phrase.segments {
            feed(segment.phoneme)
            feed(segment.start)
            feed(segment.end)
        }
        for v in phrase.f0 { feed(v) }
        for v in phrase.loudness { feed(v) }
        for v in phrase.breathiness { feed(v) }
        return hash
    }
}
