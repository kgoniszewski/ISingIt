import Foundation

/// One phoneme placed in time, relative to the start of its phrase.
public struct PhonemeSegment: Codable, Sendable, Equatable {
    public var phoneme: String
    public var start: Double
    public var end: Double
    /// Index of the note (in the score) this phoneme belongs to.
    public var noteIndex: Int

    public init(phoneme: String, start: Double, end: Double, noteIndex: Int) {
        self.phoneme = phoneme
        self.start = start
        self.end = end
        self.noteIndex = noteIndex
    }

    public var duration: Double { end - start }
}

/// A sung phrase (notes between breaths), ready for a voice to render. This is the
/// interface between the performance stages and every synthesizer: the DSP voice now,
/// the neural voice in phase 3. Frame-level curves use ``frameRate`` frames per second.
public struct PhrasePlan: Codable, Sendable, Equatable {
    /// Where the phrase starts in song time, in seconds (includes the consonants sung
    /// before the first beat, so the first phrase can start below zero).
    public var startTime: Double
    /// Length of the phrase audio in seconds, including the release tail.
    public var duration: Double
    public var frameRate: Double
    public var segments: [PhonemeSegment]
    /// Fundamental frequency per frame in Hz.
    public var f0: [Float]
    /// Overall loudness per frame, 0...~1.3.
    public var loudness: [Float]
    /// Breath noise mixed into the voice per frame, 0...1.
    public var breathiness: [Float]
    /// Score note indices covered by this phrase.
    public var noteRange: ClosedRange<Int>

    public init(
        startTime: Double, duration: Double, frameRate: Double, segments: [PhonemeSegment],
        f0: [Float], loudness: [Float], breathiness: [Float], noteRange: ClosedRange<Int>
    ) {
        self.startTime = startTime
        self.duration = duration
        self.frameRate = frameRate
        self.segments = segments
        self.f0 = f0
        self.loudness = loudness
        self.breathiness = breathiness
        self.noteRange = noteRange
    }

    public var endTime: Double { startTime + duration }
}

/// The whole song's performance: phrases in time order.
public struct PerformancePlan: Codable, Sendable, Equatable {
    public var phrases: [PhrasePlan]
    /// Length of the rendered audio in seconds, lead-in included.
    public var duration: Double
    /// Seconds of audio before song time zero (consonants sung ahead of the first beat).
    /// Song time t plays at audio time t + leadIn.
    public var leadIn: Double

    public init(phrases: [PhrasePlan], duration: Double, leadIn: Double = 0) {
        self.phrases = phrases
        self.duration = duration
        self.leadIn = leadIn
    }
}

/// Performance settings the user can change. Style presets (phase 2) set these and more.
public struct PerformanceSettings: Codable, Sendable, Equatable {
    /// Transpose in semitones.
    public var transpose: Double = 0
    /// Tempo multiplier (2 = twice as fast).
    public var tempoScale: Double = 1
    public var vibratoRateHz: Double = 5.6
    /// Peak vibrato deviation in cents.
    public var vibratoDepthCents: Double = 28
    /// Delay from note onset to vibrato start, in seconds.
    public var vibratoOnset: Double = 0.28
    /// Notes shorter than this get no vibrato.
    public var vibratoMinNote: Double = 0.4
    /// Time for a legato pitch glide between notes, in seconds.
    public var portamento: Double = 0.07
    /// Scales every consonant length.
    public var consonantScale: Double = 1
    /// A rest at least this long (seconds) starts a new phrase.
    public var phraseBreak: Double = 0.25
    /// Base breath noise.
    public var breathiness: Double = 0.06
    /// Slow random pitch drift (cents), for a less mechanical sound.
    public var pitchDriftCents: Double = 5

    public init() {}
}

extension PerformanceSettings {
    /// Names of the numeric settings, as used by `--set key=value` and preset files.
    public static var keys: [String] {
        let data = (try? JSONEncoder().encode(PerformanceSettings())) ?? Data()
        let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        return object.keys.sorted()
    }

    /// Returns a copy with the given settings replaced (unknown keys are an error).
    public func applying(_ overrides: [String: Double]) throws -> PerformanceSettings {
        guard !overrides.isEmpty else { return self }
        var object = (try JSONSerialization.jsonObject(with: JSONEncoder().encode(self))) as? [String: Any] ?? [:]
        for (key, value) in overrides {
            guard object[key] != nil else { throw SettingsError.unknownKey(key) }
            object[key] = value
        }
        return try JSONDecoder().decode(PerformanceSettings.self, from: JSONSerialization.data(withJSONObject: object))
    }
}

public enum SettingsError: Error, CustomStringConvertible {
    case unknownKey(String)
    public var description: String {
        switch self { case .unknownKey(let key): "Unknown setting '\(key)'" }
    }
}
