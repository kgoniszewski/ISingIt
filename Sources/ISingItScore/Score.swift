import Foundation

/// The Score IR: the single source of truth every pipeline stage reads and writes.
///
/// Times are in **beats** (quarter notes) from the start of the song. Converting to
/// seconds goes through ``TempoMap``. The vocal line is monophonic: notes are sorted by
/// onset and do not overlap.
public struct Score: Codable, Sendable, Equatable {
    /// Bumped whenever the JSON layout changes incompatibly.
    public static let currentFormatVersion = 1

    public var formatVersion: Int
    public var title: String?
    public var language: Language
    public var tempoMap: TempoMap
    public var timeSignatures: [TimeSignatureEvent]
    /// Key signature as a count of fifths (-7...7), when the source declares one.
    public var keyFifths: Int?
    public var notes: [Note]
    public var dynamics: [DynamicMark]
    public var sections: [Section]
    /// Where the score came from (file name, chosen part or track), for the editor.
    public var source: SourceInfo?

    public init(
        title: String? = nil,
        language: Language = .english,
        tempoMap: TempoMap = TempoMap(),
        timeSignatures: [TimeSignatureEvent] = [TimeSignatureEvent(beat: 0, numerator: 4, denominator: 4)],
        keyFifths: Int? = nil,
        notes: [Note] = [],
        dynamics: [DynamicMark] = [],
        sections: [Section] = [],
        source: SourceInfo? = nil
    ) {
        self.formatVersion = Score.currentFormatVersion
        self.title = title
        self.language = language
        self.tempoMap = tempoMap
        self.timeSignatures = timeSignatures
        self.keyFifths = keyFifths
        self.notes = notes
        self.dynamics = dynamics
        self.sections = sections
        self.source = source
    }

    /// Beat at which the last note ends.
    public var endBeat: Double { notes.map(\.endBeat).max() ?? 0 }

    /// Length of the song in seconds.
    public var durationSeconds: Double { tempoMap.seconds(atBeat: endBeat) }

    /// Sorts notes by onset, trims overlaps so the line is monophonic, and renumbers ids
    /// that are missing or duplicated.
    public mutating func normalize() {
        notes.sort { ($0.onset, -$0.pitch) < ($1.onset, -$1.pitch) }
        var kept: [Note] = []
        for note in notes where note.duration > 1e-6 {
            if var last = kept.last {
                if note.onset < last.onset + 1e-6 {
                    continue  // same onset: keep the higher pitch (sorted first)
                }
                if last.endBeat > note.onset {
                    last.duration = note.onset - last.onset
                    kept[kept.count - 1] = last
                }
            }
            kept.append(note)
        }
        var seen = Set<Int>()
        var nextID = (kept.map(\.id).max() ?? 0) + 1
        for i in kept.indices where !seen.insert(kept[i].id).inserted {
            kept[i].id = nextID
            seen.insert(nextID)
            nextID += 1
        }
        notes = kept
        dynamics.sort { $0.beat < $1.beat }
        sections.sort { $0.beat < $1.beat }
        timeSignatures.sort { $0.beat < $1.beat }
    }

    /// The dynamic mark in force at a beat, if any.
    public func dynamic(atBeat beat: Double) -> Dynamic? {
        dynamics.last(where: { $0.beat <= beat + 1e-9 })?.level
    }

    /// Encodes the score as stable, human-readable JSON (sorted keys), used for tests and
    /// for the project file.
    public func jsonData() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(self)
    }

    public static func fromJSON(_ data: Data) throws -> Score {
        try JSONDecoder().decode(Score.self, from: data)
    }
}

public enum Language: String, Codable, Sendable, CaseIterable {
    case english = "en"
    case polish = "pl"
}

/// One note of the vocal line.
public struct Note: Codable, Sendable, Equatable, Identifiable {
    /// Stable id within a score (used by the editor and for undo).
    public var id: Int
    /// MIDI note number (60 = middle C).
    public var pitch: Int
    /// Onset in beats.
    public var onset: Double
    /// Duration in beats. Tied notes are merged into one note at import.
    public var duration: Double
    /// MIDI-style velocity, 1...127.
    public var velocity: Int
    /// The syllable sung on this note. `nil` with ``continuesSyllable`` means a melisma.
    public var lyric: Syllable?
    /// True when this note carries on the previous note's syllable (a slur or lyric
    /// extension in the source, or set by lyric alignment).
    public var continuesSyllable: Bool

    public init(
        id: Int, pitch: Int, onset: Double, duration: Double, velocity: Int = 90,
        lyric: Syllable? = nil, continuesSyllable: Bool = false
    ) {
        self.id = id
        self.pitch = pitch
        self.onset = onset
        self.duration = duration
        self.velocity = velocity
        self.lyric = lyric
        self.continuesSyllable = continuesSyllable
    }

    public var endBeat: Double { onset + duration }

    /// Frequency in Hz (A4 = 440 Hz), after an optional transpose in semitones.
    public func frequency(transpose: Double = 0) -> Double {
        440.0 * pow(2.0, (Double(pitch) + transpose - 69.0) / 12.0)
    }
}

/// A syllable of lyrics attached to a note.
public struct Syllable: Codable, Sendable, Equatable {
    /// Position of the syllable in its word, as in MusicXML's `<syllabic>`.
    public enum Kind: String, Codable, Sendable {
        case single, begin, middle, end

        /// True when the next syllable belongs to the same word.
        public var continuesWord: Bool { self == .begin || self == .middle }
    }

    public var text: String
    public var kind: Kind
    /// Phonemes (ARPAbet for English, without stress digits), filled by G2P.
    public var phonemes: [String]?

    public init(text: String, kind: Kind = .single, phonemes: [String]? = nil) {
        self.text = text
        self.kind = kind
        self.phonemes = phonemes
    }
}

public struct TimeSignatureEvent: Codable, Sendable, Equatable {
    public var beat: Double
    public var numerator: Int
    public var denominator: Int

    public init(beat: Double, numerator: Int, denominator: Int) {
        self.beat = beat
        self.numerator = numerator
        self.denominator = denominator
    }

    /// Length of one bar in quarter-note beats.
    public var beatsPerBar: Double { Double(numerator) * 4.0 / Double(denominator) }
}

public enum Dynamic: String, Codable, Sendable, CaseIterable {
    case ppp, pp, p, mp, mf, f, ff, fff

    /// Loudness multiplier relative to mezzo-forte.
    public var gain: Double {
        switch self {
        case .ppp: 0.25
        case .pp: 0.35
        case .p: 0.5
        case .mp: 0.7
        case .mf: 0.85
        case .f: 1.0
        case .ff: 1.15
        case .fff: 1.3
        }
    }
}

public struct DynamicMark: Codable, Sendable, Equatable {
    public var beat: Double
    public var level: Dynamic

    public init(beat: Double, level: Dynamic) {
        self.beat = beat
        self.level = level
    }
}

/// A named section of the song. `preset` lets a section switch style (phase 2).
public struct Section: Codable, Sendable, Equatable {
    public var beat: Double
    public var name: String
    public var preset: String?

    public init(beat: Double, name: String, preset: String? = nil) {
        self.beat = beat
        self.name = name
        self.preset = preset
    }
}

public struct SourceInfo: Codable, Sendable, Equatable {
    public enum Format: String, Codable, Sendable { case musicXML, midi, project }
    public var format: Format
    public var fileName: String?
    /// MusicXML part id or MIDI track index that was used as the vocal line.
    public var part: String?

    public init(format: Format, fileName: String? = nil, part: String? = nil) {
        self.format = format
        self.fileName = fileName
        self.part = part
    }
}
