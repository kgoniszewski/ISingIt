import Foundation
import Testing
import ISingItEngine

@Suite struct ScoreTests {
    @Test func constantTempoConversions() {
        let map = TempoMap(bpm: 120)
        #expect(abs(map.seconds(atBeat: 4) - 2.0) < 1e-9)
        #expect(abs(map.beat(atSeconds: 2.0) - 4) < 1e-9)
        #expect(map.bpm(atBeat: 100) == 120)
    }

    @Test func tempoChangeConversions() {
        let map = TempoMap(events: [TempoEvent(beat: 0, bpm: 120), TempoEvent(beat: 4, bpm: 60)])
        #expect(abs(map.seconds(atBeat: 4) - 2.0) < 1e-9)
        #expect(abs(map.seconds(atBeat: 6) - 4.0) < 1e-9)
        #expect(abs(map.beat(atSeconds: 4.0) - 6) < 1e-9)
        #expect(map.bpm(atBeat: 3.99) == 120)
        #expect(map.bpm(atBeat: 4) == 60)
        for beat in stride(from: 0.0, through: 12.0, by: 0.37) {
            #expect(abs(map.beat(atSeconds: map.seconds(atBeat: beat)) - beat) < 1e-9)
        }
    }

    @Test func tempoMapCleansEvents() {
        let map = TempoMap(events: [TempoEvent(beat: 2, bpm: 90), TempoEvent(beat: 4, bpm: 90), TempoEvent(beat: 6, bpm: -5)])
        #expect(map.events == [TempoEvent(beat: 0, bpm: 90)])  // first moved to 0, redundant/invalid dropped
        #expect(TempoMap(events: []).events == [TempoEvent(beat: 0, bpm: 120)])
    }

    @Test func scaledTempo() {
        let map = TempoMap(events: [TempoEvent(beat: 0, bpm: 100), TempoEvent(beat: 4, bpm: 50)]).scaled(by: 2)
        #expect(map.bpm(atBeat: 0) == 200)
        #expect(map.bpm(atBeat: 5) == 100)
    }

    @Test func normalizeRemovesOverlapsAndDuplicates() {
        var score = Score(notes: [
            Note(id: 1, pitch: 60, onset: 2, duration: 1),
            Note(id: 1, pitch: 62, onset: 0, duration: 3),      // overlaps next, duplicate id
            Note(id: 3, pitch: 64, onset: 2, duration: 1),      // same onset as first: higher pitch wins
            Note(id: 4, pitch: 65, onset: 5, duration: 0),      // zero length dropped
        ])
        score.normalize()
        #expect(score.notes.map(\.pitch) == [62, 64])
        #expect(score.notes[0].duration == 2)  // trimmed to next onset
        for (a, b) in zip(score.notes, score.notes.dropFirst()) { #expect(a.endBeat <= b.onset + 1e-9) }
        #expect(Set(score.notes.map(\.id)).count == score.notes.count)
    }

    @Test func jsonRoundTrip() throws {
        var score = Score(title: "T", tempoMap: TempoMap(events: [TempoEvent(beat: 0, bpm: 100), TempoEvent(beat: 8, bpm: 80)]),
                          keyFifths: 1,
                          notes: [Note(id: 1, pitch: 60, onset: 0, duration: 1, lyric: Syllable(text: "la", kind: .begin, phonemes: ["L", "AA"])),
                                  Note(id: 2, pitch: 62, onset: 1, duration: 1, continuesSyllable: true)],
                          dynamics: [DynamicMark(beat: 0, level: .mp)],
                          sections: [Section(beat: 0, name: "A", preset: "x")],
                          source: SourceInfo(format: .musicXML, fileName: "a.xml", part: "P1"))
        score.normalize()
        let decoded = try Score.fromJSON(score.jsonData())
        #expect(decoded == score)
        #expect(try score.jsonData() == decoded.jsonData())  // stable output
    }

    @Test func dynamicsAndDuration() {
        let score = Score(tempoMap: TempoMap(bpm: 60), notes: [Note(id: 1, pitch: 60, onset: 0, duration: 4)],
                          dynamics: [DynamicMark(beat: 0, level: .p), DynamicMark(beat: 2, level: .f)])
        #expect(score.dynamic(atBeat: 1) == .p)
        #expect(score.dynamic(atBeat: 2) == .f)
        #expect(abs(score.durationSeconds - 4) < 1e-9)
        #expect(abs(Note(id: 1, pitch: 69, onset: 0, duration: 1).frequency() - 440) < 1e-9)
        #expect(abs(Note(id: 1, pitch: 57, onset: 0, duration: 1).frequency(transpose: 12) - 440) < 1e-9)
    }
}
