import Foundation
import Testing
import ISingItEngine

@Suite struct MusicXMLImportTests {
    static let twinklePitches = [60, 60, 67, 67, 69, 69, 67, 65, 65, 64, 64, 62, 62, 60]
    static let twinkleSyllables = ["Twin", "kle", "twin", "kle", "lit", "tle", "star,", "how", "I", "won", "der", "what", "you", "are"]

    @Test func twinkle() throws {
        let score = try TestSupport.importFixture("MusicXML/twinkle.musicxml")
        #expect(score.notes.map(\.pitch) == Self.twinklePitches)
        #expect(score.notes.map { $0.lyric?.text } == Self.twinkleSyllables.map { Optional($0) })
        #expect(score.notes[0].lyric?.kind == .begin)
        #expect(score.notes[1].lyric?.kind == .end)
        #expect(score.notes[6].lyric?.kind == .single)
        #expect(score.notes[6].duration == 2)
        #expect(score.notes[13].duration == 2)
        #expect(score.tempoMap.bpm(atBeat: 0) == 100)
        #expect(score.timeSignatures.first?.numerator == 4)
        #expect(score.source?.format == .musicXML)
        // Contiguous, monophonic.
        for (a, b) in zip(score.notes, score.notes.dropFirst()) { #expect(abs(a.endBeat - b.onset) < 1e-9) }
    }

    @Test func mxlEqualsMusicXML() throws {
        let plain = try TestSupport.importFixture("MusicXML/twinkle.musicxml")
        let zipped = try TestSupport.importFixture("MusicXML/twinkle.mxl")
        #expect(plain.notes == zipped.notes)
        #expect(plain.tempoMap == zipped.tempoMap)
        #expect(plain.timeSignatures == zipped.timeSignatures)
        #expect(plain.keyFifths == zipped.keyFifths)
    }

    @Test func amazingGrace() throws {
        let score = try TestSupport.importFixture("MusicXML/amazing_grace.musicxml")
        #expect(score.notes.count == 15)  // the tie is merged into one note
        #expect(score.timeSignatures.first?.numerator == 3)
        #expect(score.timeSignatures.first?.denominator == 4)
        #expect(score.tempoMap.bpm(atBeat: 0) == 72)
        #expect(score.keyFifths == 1)
        // Pickup: first note starts at beat 0 and is shorter than a bar.
        #expect(score.notes[0].onset == 0)
        #expect(score.notes[0].duration < 3)
        // A dotted half exists (3 beats), and the tie produced a note longer than any single written value would be.
        #expect(score.notes.contains { $0.duration == 3 })
        // Melisma after "sweet".
        let sweet = try #require(score.notes.firstIndex { $0.lyric?.text == "sweet" })
        #expect(score.notes[sweet + 1].continuesSyllable)
        #expect(score.notes[sweet + 1].lyric == nil)
        #expect(score.notes.filter(\.continuesSyllable).count == 1)
        // Dynamic <p/>.
        #expect(score.dynamics.contains { $0.level == .p })
        #expect(score.dynamic(atBeat: 0) == .p || score.dynamics.first!.beat > 0)
    }

    @Test func partChoice() throws {
        let data = try TestSupport.fixtureData("MusicXML/two_parts.musicxml")
        let parts = try MusicXMLImporter().parts(in: data)
        #expect(parts.map(\.id) == ["P1", "P2"])
        #expect(parts[0].name == "Soprano")
        #expect(parts[0].lyricCount > 0)
        #expect(parts[1].lyricCount == 0)

        let auto = try MusicXMLImporter().importScore(from: data)
        #expect(auto.source?.part == "P1")
        #expect(auto.notes.allSatisfy { $0.lyric != nil || $0.continuesSyllable })

        let piano = try MusicXMLImporter().importScore(from: data, partID: "P2")
        #expect(piano.source?.part == "P2")
        #expect(piano.notes.allSatisfy { $0.lyric == nil })
        // Chords are reduced to a monophonic line.
        for (a, b) in zip(piano.notes, piano.notes.dropFirst()) { #expect(a.endBeat <= b.onset + 1e-9) }

        #expect(throws: ImportError.partNotFound("P9")) {
            try MusicXMLImporter().importScore(from: data, partID: "P9")
        }
    }

    @Test func restsDotsAndTempoChange() throws {
        let score = try TestSupport.importFixture("MusicXML/rests_and_dots.musicxml")
        #expect(Array(score.notes.prefix(4)).compactMap { $0.lyric?.text } == ["hel", "lo", "my", "friend"])
        // Dotted quarter = 1.5 beats, eighth = 0.5, then a quarter rest.
        #expect(score.notes[0].duration == 1.5)
        #expect(score.notes[1].onset == 1.5)
        #expect(score.notes[1].duration == 0.5)
        #expect(score.notes[2].onset == 3)  // rest of one beat skipped
        // Tempo change to 140 in measure 2 (beat 4).
        #expect(score.tempoMap.events.count == 2)
        #expect(score.tempoMap.bpm(atBeat: 0) == 100)
        #expect(score.tempoMap.bpm(atBeat: 4) == 140)
        #expect(score.notes[0].lyric?.kind == .begin)
    }

    @Test func invalidInput() {
        #expect(throws: ImportError.self) { try MusicXMLImporter().importScore(from: Data("<foo/>".utf8)) }
        #expect(throws: ImportError.self) { try MusicXMLImporter().importScore(from: Data("not xml at all".utf8)) }
    }
}
