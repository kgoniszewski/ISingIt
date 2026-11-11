import Foundation
import Testing
import ISingItEngine

@Suite struct MIDIImportTests {
    @Test func lyricsWithHyphenKinds() throws {
        let score = try TestSupport.importFixture("MIDI/twinkle_lyrics.mid")
        #expect(score.notes.map(\.pitch) == MusicXMLImportTests.twinklePitches)
        let kinds = score.notes.map { $0.lyric?.kind }
        #expect(kinds[0] == .begin)
        #expect(kinds[1] == .end)
        #expect(kinds[6] == .single)
        #expect(score.notes[0].lyric?.text == "Twin")
        #expect(score.notes[1].lyric?.text == "kle")
        #expect(score.notes.compactMap(\.lyric).count == 14)
        #expect(score.tempoMap.bpm(atBeat: 0) == 100)
        #expect(score.source?.format == .midi)
    }

    @Test func noLyricsFixture() throws {
        let score = try TestSupport.importFixture("MIDI/twinkle_nolyrics.mid")
        #expect(score.notes.map(\.pitch) == MusicXMLImportTests.twinklePitches)
        #expect(score.notes.allSatisfy { $0.lyric == nil })
    }

    @Test func multitrackSuggestion() throws {
        let data = try TestSupport.fixtureData("MIDI/multitrack.mid")
        let importer = MIDIImporter()
        let tracks = try importer.tracks(in: data)
        let suggested = try #require(try importer.suggestedMelodyTrack(in: data))
        let info = tracks[suggested]
        #expect(info.lyricCount > 0)
        #expect(info.noteCount > 0)
        // The suggestion has the highest mean pitch among tracks with notes.
        #expect(info.meanPitch == tracks.filter { $0.noteCount > 0 }.map(\.meanPitch).max())
        let score = try importer.importScore(from: data)
        #expect(score.source?.part == String(suggested))
        #expect(score.notes.contains { $0.lyric != nil })
    }

    @Test func explicitTrackChoice() throws {
        let data = try TestSupport.fixtureData("MIDI/multitrack.mid")
        let importer = MIDIImporter()
        let tracks = try importer.tracks(in: data)
        let suggested = try #require(try importer.suggestedMelodyTrack(in: data))
        let other = try #require(tracks.first { $0.noteCount > 0 && $0.index != suggested })
        let score = try importer.importScore(from: data, track: other.index)
        #expect(score.notes.count == other.noteCount || score.notes.count <= other.noteCount)
        #expect(score.notes.allSatisfy { $0.lyric == nil })
        #expect(score.source?.part == String(other.index))
        #expect(throws: ImportError.self) { try importer.importScore(from: data, track: 99) }
        // Same via the generic entry point.
        let viaFacade = try ScoreImporter.importData(data, fileName: "multitrack.mid", part: String(other.index))
        #expect(viaFacade.notes == score.notes)
    }

    @Test func tempoChangeSeconds() throws {
        let score = try TestSupport.importFixture("MIDI/tempo_change.mid")
        #expect(score.notes.count == 8)
        #expect(score.notes.map(\.pitch) == [60, 62, 64, 65, 67, 69, 71, 72])
        #expect(score.tempoMap.events.count == 2)
        #expect(score.tempoMap.bpm(atBeat: 0) == 120)
        let change = score.tempoMap.events[1]
        #expect(change.bpm == 60)
        // Four beats at 120 bpm = 2 s; the following beats take 1 s each.
        #expect(abs(score.tempoMap.seconds(atBeat: change.beat) - change.beat * 0.5) < 1e-9)
        #expect(abs(score.tempoMap.seconds(atBeat: 8) - (change.beat * 0.5 + (8 - change.beat))) < 1e-9)
        #expect(abs(score.tempoMap.seconds(atBeat: score.notes[7].onset)
                    - (change.beat * 0.5 + (score.notes[7].onset - change.beat))) < 1e-9)
    }

    @Test func garbageThrows() {
        let importer = MIDIImporter()
        #expect(throws: ImportError.self) { try importer.importScore(from: Data("this is not midi".utf8)) }
        #expect(throws: ImportError.self) { try importer.importScore(from: Data()) }
        #expect(throws: ImportError.self) { try importer.tracks(in: Data([0x4D, 0x54, 0x68, 0x64, 0, 0])) }
        // Truncated real file.
        if let data = try? TestSupport.fixtureData("MIDI/twinkle_lyrics.mid") {
            #expect(throws: ImportError.self) { try importer.importScore(from: data.prefix(data.count / 2)) }
        }
        #expect(throws: ImportError.self) {
            try ScoreImporter.importData(Data("zzz".utf8), fileName: "mystery.bin")
        }
    }
}
