import Foundation
import ISingItScore

/// Summary of one part in a MusicXML file, for choosing the vocal line.
public struct MusicXMLPartInfo: Sendable, Equatable {
    public var id: String
    public var name: String
    public var noteCount: Int
    public var lyricCount: Int
}

public enum ImportError: Error, CustomStringConvertible, Equatable {
    case unsupportedFile(String)
    case invalidMusicXML(String)
    case invalidMIDI(String)
    case invalidArchive(String)
    case partNotFound(String)
    case noNotes

    public var description: String {
        switch self {
        case .unsupportedFile(let name): "Unsupported file type: \(name)"
        case .invalidMusicXML(let why): "Invalid MusicXML: \(why)"
        case .invalidMIDI(let why): "Invalid MIDI file: \(why)"
        case .invalidArchive(let why): "Invalid compressed MusicXML (.mxl): \(why)"
        case .partNotFound(let id): "No part or track named \(id)"
        case .noNotes: "The chosen part has no notes"
        }
    }
}

/// Import.MusicXML: reads partwise MusicXML (`.musicxml`, `.xml`, or compressed `.mxl`)
/// into the Score IR.
public struct MusicXMLImporter {
    public init() {}

    /// Lists the parts so the user (or the CLI) can pick the vocal part.
    public func parts(in data: Data) throws -> [MusicXMLPartInfo] {
        let root = try Self.root(of: data)
        let names = Self.partNames(root)
        return root.children("part").map { part in
            let id = part.attributes["id"] ?? "?"
            let notes = part.descendants("note").filter { !$0.has("rest") && !$0.has("grace") }
            return MusicXMLPartInfo(
                id: id, name: names[id] ?? id, noteCount: notes.count,
                lyricCount: notes.filter { $0.has("lyric") }.count)
        }
    }

    /// Imports the vocal line. With `partID` nil, the part with the most lyrics is used.
    public func importScore(from data: Data, fileName: String? = nil, partID: String? = nil) throws -> Score {
        let root = try Self.root(of: data)
        let parts = root.children("part")
        guard !parts.isEmpty else { throw ImportError.invalidMusicXML("no <part> elements") }

        let chosen: XMLElement
        if let partID {
            guard let match = parts.first(where: { $0.attributes["id"] == partID }) else {
                throw ImportError.partNotFound(partID)
            }
            chosen = match
        } else {
            chosen = parts.max(by: { Self.lyricCount($0) < Self.lyricCount($1) }) ?? parts[0]
        }

        // Tempo, time and key marks may sit in any part (often only the first), so read
        // them from all parts and keep the vocal part's notes.
        var parsed = PartParser()
        for part in parts where part !== chosen { parsed.parse(part, collectNotes: false) }
        parsed.parse(chosen, collectNotes: true)

        var score = Score(
            title: root.child("work")?.value("work-title") ?? root.value("movement-title"),
            tempoMap: TempoMap(events: parsed.tempos.isEmpty ? [TempoEvent(beat: 0, bpm: 120)] : parsed.tempos),
            timeSignatures: parsed.timeSignatures.isEmpty
                ? [TimeSignatureEvent(beat: 0, numerator: 4, denominator: 4)] : parsed.timeSignatures,
            keyFifths: parsed.keyFifths,
            notes: parsed.vocalNotes(),
            dynamics: parsed.dynamics,
            source: SourceInfo(format: .musicXML, fileName: fileName, part: chosen.attributes["id"])
        )
        score.normalize()
        guard !score.notes.isEmpty else { throw ImportError.noNotes }
        return score
    }

    // MARK: - Helpers

    static func root(of data: Data) throws -> XMLElement {
        let xmlData = ZipArchive.isZip(data) ? try MXL.rootScore(in: data) : data
        let root: XMLElement
        do {
            root = try XMLTreeBuilder.parse(xmlData)
        } catch {
            throw ImportError.invalidMusicXML("\(error)")
        }
        if root.name == "score-timewise" {
            throw ImportError.invalidMusicXML("timewise MusicXML is not supported yet; export partwise")
        }
        guard root.name == "score-partwise" else {
            throw ImportError.invalidMusicXML("root element is <\(root.name)>, expected <score-partwise>")
        }
        return root
    }

    static func partNames(_ root: XMLElement) -> [String: String] {
        var names: [String: String] = [:]
        for scorePart in root.child("part-list")?.children("score-part") ?? [] {
            if let id = scorePart.attributes["id"] {
                names[id] = scorePart.value("part-name") ?? id
            }
        }
        return names
    }

    static func lyricCount(_ part: XMLElement) -> Int {
        part.descendants("note").filter { $0.has("lyric") }.count
    }
}

/// Walks the measures of a part, tracking the time cursor.
private struct PartParser {
    struct RawNote {
        var pitch: Int
        var onset: Double
        var duration: Double
        var voice: String
        var velocity: Int
        var tieStart = false
        var tieStop = false
        var slurStarts = 0
        var slurStops = 0
        var lyric: Syllable?
        var lyricExtends = false
        var isChordTone = false
    }

    var tempos: [TempoEvent] = []
    var timeSignatures: [TimeSignatureEvent] = []
    var dynamics: [DynamicMark] = []
    var keyFifths: Int?
    var notes: [RawNote] = []

    mutating func parse(_ part: XMLElement, collectNotes: Bool) {
        var divisions = 1.0
        var cursor = 0.0
        var lastOnset = 0.0
        var measureStart = 0.0
        var measureLength = 0.0

        for measure in part.children("measure") {
            measureStart = cursor
            measureLength = 0
            for element in measure.children {
                switch element.name {
                case "attributes":
                    if let d = element.double("divisions"), d > 0 { divisions = d }
                    if let fifths = element.child("key")?.int("fifths"), keyFifths == nil { keyFifths = fifths }
                    if let time = element.child("time"),
                       let beats = time.value("beats").flatMap(Self.parseBeats),
                       let beatType = time.int("beat-type")
                    {
                        addTimeSignature(TimeSignatureEvent(beat: cursor, numerator: beats, denominator: beatType))
                    }
                case "direction":
                    if let sound = element.child("sound") { readSound(sound, at: cursor) }
                    for directionType in element.children("direction-type") {
                        for dyn in directionType.children("dynamics") {
                            for mark in dyn.children {
                                if let level = Dynamic(rawValue: mark.name) {
                                    addDynamic(DynamicMark(beat: cursor, level: level))
                                }
                            }
                        }
                    }
                case "sound":
                    readSound(element, at: cursor)
                case "backup":
                    cursor -= (element.double("duration") ?? 0) / divisions
                case "forward":
                    cursor += (element.double("duration") ?? 0) / divisions
                    measureLength = max(measureLength, cursor - measureStart)
                case "note":
                    if element.has("grace") || element.has("cue") { continue }
                    let duration = (element.double("duration") ?? 0) / divisions
                    let isChord = element.has("chord")
                    let onset = isChord ? lastOnset : cursor
                    if !isChord {
                        lastOnset = cursor
                        cursor += duration
                        measureLength = max(measureLength, cursor - measureStart)
                    }
                    guard collectNotes, !element.has("rest"), let pitch = Self.midiPitch(element) else { continue }
                    var note = RawNote(
                        pitch: pitch, onset: onset, duration: duration,
                        voice: element.value("voice") ?? "1",
                        velocity: element.attributes["dynamics"].flatMap(Double.init).map {
                            max(1, min(127, Int(($0 / 100.0 * 90.0).rounded())))
                        } ?? 90,
                        isChordTone: isChord)
                    for tie in element.children("tie") {
                        if tie.attributes["type"] == "start" { note.tieStart = true }
                        if tie.attributes["type"] == "stop" { note.tieStop = true }
                    }
                    for notations in element.children("notations") {
                        for tied in notations.children("tied") {
                            if tied.attributes["type"] == "start" { note.tieStart = true }
                            if tied.attributes["type"] == "stop" { note.tieStop = true }
                        }
                        for slur in notations.children("slur") {
                            if slur.attributes["type"] == "start" { note.slurStarts += 1 }
                            if slur.attributes["type"] == "stop" { note.slurStops += 1 }
                        }
                    }
                    let lyrics = element.children("lyric")
                    if let lyric = lyrics.first(where: { ($0.attributes["number"] ?? "1") == "1" }) ?? lyrics.first {
                        let text = lyric.children("text").map(\.text).joined(separator: " ")
                            .trimmingCharacters(in: .whitespacesAndNewlines)
                        if !text.isEmpty {
                            let kind = Syllable.Kind(rawValue: lyric.value("syllabic") ?? "single") ?? .single
                            note.lyric = Syllable(text: text, kind: kind)
                        }
                        note.lyricExtends = lyric.has("extend")
                    }
                    notes.append(note)
                default:
                    continue
                }
            }
            // Keep the cursor at the end of the measure even if voices ended early.
            cursor = measureStart + measureLength
        }
    }

    private mutating func readSound(_ sound: XMLElement, at beat: Double) {
        if let tempo = sound.attributes["tempo"].flatMap(Double.init), tempo > 0 {
            tempos.removeAll { abs($0.beat - beat) < 1e-9 }
            tempos.append(TempoEvent(beat: beat, bpm: tempo))
        }
        if let dyn = sound.attributes["dynamics"].flatMap(Double.init) {
            // <sound dynamics> is a percentage of forte (90 velocity).
            let level: Dynamic = switch dyn {
            case ..<30: .pp
            case ..<50: .p
            case ..<70: .mp
            case ..<90: .mf
            case ..<110: .f
            default: .ff
            }
            addDynamic(DynamicMark(beat: beat, level: level))
        }
    }

    private mutating func addTimeSignature(_ event: TimeSignatureEvent) {
        timeSignatures.removeAll { abs($0.beat - event.beat) < 1e-9 }
        if let last = timeSignatures.last, last.numerator == event.numerator, last.denominator == event.denominator {
            return
        }
        timeSignatures.append(event)
    }

    private mutating func addDynamic(_ mark: DynamicMark) {
        dynamics.removeAll { abs($0.beat - mark.beat) < 1e-9 }
        dynamics.append(mark)
    }

    /// The vocal line: the voice with the most lyrics, top note of chords, ties merged,
    /// melisma notes marked.
    func vocalNotes() -> [Note] {
        let voiceLyrics = Dictionary(grouping: notes, by: \.voice).mapValues { group in
            (group.filter { $0.lyric != nil }.count, group.count)
        }
        let voice = voiceLyrics.max(by: { a, b in
            a.value.0 != b.value.0 ? a.value.0 < b.value.0 : a.value.1 < b.value.1
        })?.key ?? "1"
        var line = notes.filter { $0.voice == voice }
        line.sort { ($0.onset, -$0.pitch) < ($1.onset, -$1.pitch) }

        // Keep the top note of each chord, but keep a lyric from any chord tone.
        var mono: [RawNote] = []
        for note in line {
            if let last = mono.last, abs(last.onset - note.onset) < 1e-9 {
                if mono[mono.count - 1].lyric == nil { mono[mono.count - 1].lyric = note.lyric }
                continue
            }
            mono.append(note)
        }

        // Merge ties.
        var merged: [RawNote] = []
        for note in mono {
            if let last = merged.last, last.tieStart, last.pitch == note.pitch,
               abs(last.onset + last.duration - note.onset) < 1e-6
            {
                merged[merged.count - 1].duration += note.duration
                merged[merged.count - 1].tieStart = note.tieStart
                merged[merged.count - 1].slurStarts += note.slurStarts
                merged[merged.count - 1].slurStops += note.slurStops
                merged[merged.count - 1].lyricExtends = merged[merged.count - 1].lyricExtends || note.lyricExtends
                continue
            }
            merged.append(note)
        }

        // Mark melisma notes: no lyric, inside a slur or a lyric extension, and joined
        // to the previous note without a rest.
        var result: [Note] = []
        var slurDepth = 0
        var extending = false
        var previousEnd = -Double.infinity
        for (index, raw) in merged.enumerated() {
            let joined = abs(raw.onset - previousEnd) < 1e-6
            var continues = false
            if raw.lyric == nil, joined, slurDepth > 0 || extending {
                continues = true
            }
            if raw.lyric != nil { extending = raw.lyricExtends } else if !continues { extending = false }
            slurDepth = max(0, slurDepth + raw.slurStarts - raw.slurStops)
            result.append(Note(
                id: index + 1, pitch: raw.pitch, onset: raw.onset, duration: raw.duration,
                velocity: raw.velocity, lyric: raw.lyric, continuesSyllable: continues))
            previousEnd = raw.onset + raw.duration
        }
        return result
    }

    static func midiPitch(_ note: XMLElement) -> Int? {
        guard let pitch = note.child("pitch"), let step = pitch.value("step"),
              let octave = pitch.int("octave") else { return nil }
        let base: [String: Int] = ["C": 0, "D": 2, "E": 4, "F": 5, "G": 7, "A": 9, "B": 11]
        guard let semitone = base[step.uppercased()] else { return nil }
        let alter = Int((pitch.double("alter") ?? 0).rounded())
        return (octave + 1) * 12 + semitone + alter
    }

    /// `<beats>` may be compound, like "3+2".
    static func parseBeats(_ text: String) -> Int? {
        let parts = text.split(separator: "+").compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
        return parts.isEmpty ? nil : parts.reduce(0, +)
    }
}

/// Compressed MusicXML: a ZIP with META-INF/container.xml naming the root score.
enum MXL {
    static func rootScore(in data: Data) throws -> Data {
        let archive = try ZipArchive(data: data)
        if let container = try archive.extract(path: "META-INF/container.xml"),
           let root = try? XMLTreeBuilder.parse(container),
           let path = root.descendants("rootfile").first?.attributes["full-path"],
           let score = try archive.extract(path: path)
        {
            return score
        }
        // Fallback: the first .musicxml/.xml file outside META-INF.
        for entry in archive.entries where !entry.path.hasPrefix("META-INF")
            && (entry.path.hasSuffix(".musicxml") || entry.path.hasSuffix(".xml"))
        {
            if let score = try archive.extract(path: entry.path) { return score }
        }
        throw ImportError.invalidArchive("no MusicXML score inside the archive")
    }
}
