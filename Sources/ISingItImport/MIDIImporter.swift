import Foundation
import ISingItScore

/// Summary of one MIDI track, for choosing the melody.
public struct MIDITrackInfo: Sendable, Equatable {
    public var index: Int
    public var name: String?
    public var noteCount: Int
    public var lyricCount: Int
    public var meanPitch: Double
    /// Share of notes that overlap the previous one (0 = strictly monophonic).
    public var polyphony: Double
    public var isDrums: Bool
}

/// Import.MIDI: reads a Standard MIDI File (format 0 or 1) into the Score IR. Uses lyric
/// meta events when present; otherwise the notes come without lyrics and Lyrics.Align
/// attaches pasted text.
public struct MIDIImporter {
    public init() {}

    struct RawNote {
        var tick: Int
        var endTick: Int
        var pitch: Int
        var velocity: Int
        var channel: Int
    }

    struct Track {
        var name: String?
        var notes: [RawNote] = []
        var lyrics: [(tick: Int, text: String)] = []
        var tempos: [(tick: Int, bpm: Double)] = []
        var timeSignatures: [(tick: Int, numerator: Int, denominator: Int)] = []
        var keyFifths: Int?
    }

    struct File {
        var division: Int
        var tracks: [Track]
    }

    public func tracks(in data: Data) throws -> [MIDITrackInfo] {
        let file = try Self.parse(data)
        return file.tracks.enumerated().map { Self.info(index: $0.offset, track: $0.element) }
    }

    /// The index of the track most likely to be the melody: monophonic, not drums,
    /// lyrics preferred, then highest mean pitch.
    public func suggestedMelodyTrack(in data: Data) throws -> Int? {
        Self.suggestMelody(try tracks(in: data))
    }

    static func suggestMelody(_ infos: [MIDITrackInfo]) -> Int? {
        let candidates = infos.filter { $0.noteCount > 0 && !$0.isDrums }
        func score(_ t: MIDITrackInfo) -> Double {
            var s = t.meanPitch
            if t.lyricCount > 0 { s += 1000 }
            if t.polyphony < 0.1 { s += 100 } else { s -= 100 * t.polyphony }
            return s
        }
        return candidates.max(by: { score($0) < score($1) })?.index
    }

    public func importScore(from data: Data, fileName: String? = nil, track trackIndex: Int? = nil) throws -> Score {
        let file = try Self.parse(data)
        let infos = file.tracks.enumerated().map { Self.info(index: $0.offset, track: $0.element) }
        let chosenIndex: Int
        if let trackIndex {
            guard file.tracks.indices.contains(trackIndex) else { throw ImportError.partNotFound("track \(trackIndex)") }
            chosenIndex = trackIndex
        } else {
            guard let suggested = Self.suggestMelody(infos) else { throw ImportError.noNotes }
            chosenIndex = suggested
        }
        let division = Double(file.division)
        let beat = { (tick: Int) in Double(tick) / division }

        // Tempo, time and key events can sit in any track (usually track 0).
        var tempos: [TempoEvent] = []
        var timeSignatures: [TimeSignatureEvent] = []
        var keyFifths: Int?
        for track in file.tracks {
            tempos += track.tempos.map { TempoEvent(beat: beat($0.tick), bpm: $0.bpm) }
            timeSignatures += track.timeSignatures.map {
                TimeSignatureEvent(beat: beat($0.tick), numerator: $0.numerator, denominator: $0.denominator)
            }
            if keyFifths == nil { keyFifths = track.keyFifths }
        }
        timeSignatures.sort { $0.beat < $1.beat }

        let track = file.tracks[chosenIndex]
        var raw = track.notes.sorted { ($0.tick, -$0.pitch) < ($1.tick, -$1.pitch) }
        // Monophonic: keep the highest note per onset.
        var mono: [RawNote] = []
        for note in raw {
            if let last = mono.last, last.tick == note.tick { continue }
            mono.append(note)
        }
        raw = mono

        // Lyric events: attach to the note starting at (or just after) the event tick.
        let tolerance = max(1, file.division / 16)
        var lyricFor: [Int: Syllable] = [:]
        var continuing = false
        var noteCursor = 0
        for (tick, rawText) in track.lyrics.sorted(by: { $0.tick < $1.tick }) {
            var text = rawText.replacingOccurrences(of: "/", with: " ")
                .replacingOccurrences(of: "\\", with: " ")
                .replacingOccurrences(of: "\r", with: " ")
                .replacingOccurrences(of: "\n", with: " ")
            let trailingSpace = text.hasSuffix(" ")
            text = text.trimmingCharacters(in: .whitespaces)
            if text.isEmpty || text == "-" { continue }
            while noteCursor < raw.count && raw[noteCursor].tick < tick - tolerance { noteCursor += 1 }
            guard noteCursor < raw.count, raw[noteCursor].tick <= tick + tolerance * 4 else { continue }
            let hyphen = text.hasSuffix("-") && !trailingSpace
            if hyphen { text.removeLast() }
            let kind: Syllable.Kind = switch (continuing, hyphen) {
            case (false, false): .single
            case (false, true): .begin
            case (true, true): .middle
            case (true, false): .end
            }
            continuing = hyphen
            lyricFor[noteCursor] = Syllable(text: text, kind: kind)
            noteCursor += 1
        }

        let hasLyrics = !lyricFor.isEmpty
        var notes: [Note] = []
        for (i, n) in raw.enumerated() {
            let lyric = lyricFor[i]
            // With lyric events present, an unlabelled note joined to the previous one is a melisma.
            let joined = i > 0 && raw[i - 1].endTick >= n.tick - tolerance
            notes.append(Note(
                id: i + 1, pitch: n.pitch, onset: beat(n.tick), duration: beat(max(n.endTick, n.tick + 1)) - beat(n.tick),
                velocity: n.velocity, lyric: lyric,
                continuesSyllable: hasLyrics && lyric == nil && joined && i > 0))
        }

        var score = Score(
            title: track.name ?? file.tracks.first?.name,
            tempoMap: TempoMap(events: tempos.isEmpty ? [TempoEvent(beat: 0, bpm: 120)] : tempos),
            timeSignatures: timeSignatures.isEmpty ? [TimeSignatureEvent(beat: 0, numerator: 4, denominator: 4)] : timeSignatures,
            keyFifths: keyFifths,
            notes: notes,
            source: SourceInfo(format: .midi, fileName: fileName, part: String(chosenIndex)))
        score.normalize()
        guard !score.notes.isEmpty else { throw ImportError.noNotes }
        return score
    }

    // MARK: - Parsing

    static func info(index: Int, track: Track) -> MIDITrackInfo {
        let notes = track.notes.sorted { $0.tick < $1.tick }
        var overlaps = 0
        var maxEnd = Int.min
        for n in notes {
            if n.tick < maxEnd { overlaps += 1 }
            maxEnd = max(maxEnd, n.endTick)
        }
        return MIDITrackInfo(
            index: index, name: track.name, noteCount: notes.count, lyricCount: track.lyrics.count,
            meanPitch: notes.isEmpty ? 0 : Double(notes.map(\.pitch).reduce(0, +)) / Double(notes.count),
            polyphony: notes.isEmpty ? 0 : Double(overlaps) / Double(notes.count),
            isDrums: !notes.isEmpty && notes.allSatisfy { $0.channel == 9 })
    }

    static func parse(_ data: Data) throws -> File {
        let b = [UInt8](data)
        var p = 0
        func need(_ n: Int) throws { if p + n > b.count { throw ImportError.invalidMIDI("unexpected end of file") } }
        func u32() throws -> Int { try need(4); defer { p += 4 }; return Int(b[p]) << 24 | Int(b[p + 1]) << 16 | Int(b[p + 2]) << 8 | Int(b[p + 3]) }
        func u16() throws -> Int { try need(2); defer { p += 2 }; return Int(b[p]) << 8 | Int(b[p + 1]) }

        // RIFF-wrapped MIDI (.rmi): skip to the MThd chunk.
        if b.count > 20, b[0] == 0x52, b[1] == 0x49, b[2] == 0x46, b[3] == 0x46,
           let start = (0..<(b.count - 4)).first(where: { b[$0] == 0x4D && b[$0 + 1] == 0x54 && b[$0 + 2] == 0x68 && b[$0 + 3] == 0x64 })
        {
            p = start
        }
        guard try u32() == 0x4D54_6864 else { throw ImportError.invalidMIDI("missing MThd header") }
        let headerLength = try u32()
        let headerStart = p
        _ = try u16()  // format
        let trackCount = try u16()
        let division = try u16()
        guard division & 0x8000 == 0 else { throw ImportError.invalidMIDI("SMPTE time division is not supported") }
        guard division > 0 else { throw ImportError.invalidMIDI("zero time division") }
        p = headerStart + headerLength

        var tracks: [Track] = []
        while tracks.count < trackCount, p + 8 <= b.count {
            let id = try u32()
            let length = try u32()
            let end = min(b.count, p + length)
            if id != 0x4D54_726B { p = end; continue }  // skip unknown chunks
            tracks.append(try parseTrack(b, from: p, to: end))
            p = end
        }
        guard !tracks.isEmpty else { throw ImportError.invalidMIDI("no tracks") }
        return File(division: division, tracks: tracks)
    }

    private static func parseTrack(_ b: [UInt8], from start: Int, to end: Int) throws -> Track {
        var track = Track()
        var p = start
        var tick = 0
        var status: UInt8 = 0
        var open: [Int: [(tick: Int, velocity: Int)]] = [:]  // key: channel << 8 | pitch

        func vlq() throws -> Int {
            var value = 0
            for _ in 0..<4 {
                guard p < end else { throw ImportError.invalidMIDI("truncated variable-length value") }
                let byte = b[p]
                p += 1
                value = value << 7 | Int(byte & 0x7F)
                if byte & 0x80 == 0 { return value }
            }
            throw ImportError.invalidMIDI("variable-length value too long")
        }
        func text(_ bytes: ArraySlice<UInt8>) -> String {
            String(bytes: bytes, encoding: .utf8) ?? String(bytes: bytes, encoding: .isoLatin1) ?? ""
        }
        func close(_ key: Int, at tick: Int) {
            guard var stack = open[key], !stack.isEmpty else { return }
            let started = stack.removeFirst()
            open[key] = stack
            track.notes.append(RawNote(tick: started.tick, endTick: tick, pitch: key & 0xFF, velocity: started.velocity, channel: key >> 8))
        }

        while p < end {
            tick += try vlq()
            guard p < end else { break }
            var byte = b[p]
            if byte & 0x80 != 0 {
                status = byte
                p += 1
            } else if status == 0 {
                throw ImportError.invalidMIDI("running status without a previous status")
            }
            switch status {
            case 0xFF:
                guard p < end else { throw ImportError.invalidMIDI("truncated meta event") }
                let type = b[p]
                p += 1
                let length = try vlq()
                guard p + length <= end else { throw ImportError.invalidMIDI("truncated meta event") }
                let payload = b[p..<(p + length)]
                switch type {
                case 0x03 where track.name == nil:
                    let name = text(payload).trimmingCharacters(in: .whitespacesAndNewlines)
                    if !name.isEmpty { track.name = name }
                case 0x05:
                    track.lyrics.append((tick, text(payload)))
                case 0x51 where length == 3:
                    let micros = Int(payload[payload.startIndex]) << 16 | Int(payload[payload.startIndex + 1]) << 8 | Int(payload[payload.startIndex + 2])
                    if micros > 0 { track.tempos.append((tick, 60_000_000.0 / Double(micros))) }
                case 0x58 where length >= 2:
                    track.timeSignatures.append((tick, Int(payload[payload.startIndex]), 1 << Int(payload[payload.startIndex + 1])))
                case 0x59 where length >= 1:
                    track.keyFifths = Int(Int8(bitPattern: payload[payload.startIndex]))
                default:
                    break
                }
                p += length
                status = 0  // meta events cancel running status
            case 0xF0, 0xF7:
                let length = try vlq()
                p += length
                status = 0
            default:
                let kind = status & 0xF0
                let channel = Int(status & 0x0F)
                let dataLength = (kind == 0xC0 || kind == 0xD0) ? 1 : 2
                guard p + dataLength <= end else { throw ImportError.invalidMIDI("truncated channel event") }
                byte = b[p]
                let data1 = Int(byte)
                let data2 = dataLength == 2 ? Int(b[p + 1]) : 0
                p += dataLength
                let key = channel << 8 | data1
                if kind == 0x90 && data2 > 0 {
                    open[key, default: []].append((tick, data2))
                } else if kind == 0x80 || (kind == 0x90 && data2 == 0) {
                    close(key, at: tick)
                }
            }
        }
        for (key, stack) in open {
            for _ in stack { close(key, at: tick) }
        }
        return track
    }
}
