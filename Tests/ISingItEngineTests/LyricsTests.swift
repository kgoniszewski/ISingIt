import Foundation
import Testing
import ISingItEngine

@Suite struct LyricsTests {
    let g2p = EnglishG2P.shared

    @Test func dictionaryWords() {
        #expect(g2p.knows("star"))
        #expect(g2p.phonemes(for: "star") == ["S", "T", "AA", "R"])
        #expect(g2p.phonemes(for: "Star!") == ["S", "T", "AA", "R"])  // case and punctuation ignored
        #expect(g2p.phonemes(for: "twinkle") == ["T", "W", "IH", "NG", "K", "AH", "L"])
        #expect(g2p.phonemes(for: "you").last == "UW")
        #expect(g2p.phonemes(for: "") == [])
    }

    @Test func outOfVocabularyWordsHaveVowels() {
        for word in ["blorptastic", "zxqv", "flibbertigibbet", "qwrt", "kleenex's", "snarfle"] {
            let p = g2p.phonemes(for: word)
            #expect(!p.isEmpty, "\(word)")
            #expect(p.contains(where: Phonemes.isVowel), "\(word) -> \(p)")
            #expect(p.allSatisfy { Phonemes.english.contains($0) }, "\(word) -> \(p)")
        }
        #expect(!g2p.knows("blorptastic"))
    }

    @Test func userLexicon() {
        let g = EnglishG2P()
        g.addPronunciation("isingit", phonemes: ["AY", "S", "IH", "NG", "IH", "T"])
        #expect(g.knows("isingit"))
        #expect(g.phonemes(for: "ISingIt") == ["AY", "S", "IH", "NG", "IH", "T"])
    }

    @Test func syllabify() {
        #expect(Syllabifier.syllabify(["T", "W", "IH", "NG", "K", "AH", "L"]) == [["T", "W", "IH", "NG"], ["K", "AH", "L"]])
        #expect(Syllabifier.syllabify(["L", "IH", "T", "AH", "L"]) == [["L", "IH"], ["T", "AH", "L"]])
        #expect(Syllabifier.syllabify(["S", "T", "AA", "R"]) == [["S", "T", "AA", "R"]])
        #expect(Syllabifier.syllabify([]) == [])
        #expect(Syllabifier.syllabify(["S", "T"]) == [["S", "T"]])  // no vowel
        // Maximal onset: "a-stro" style cluster stays together.
        #expect(Syllabifier.syllabify(["AH", "S", "T", "R", "AA"]) == [["AH"], ["S", "T", "R", "AA"]])
    }

    @Test func syllabifierFit() {
        let two = [["F", "AY"], ["ER"]]
        #expect(Syllabifier.fit(two, into: 2) == two)
        let merged = Syllabifier.fit(two, into: 1)
        #expect(merged == [["F", "AY", "ER"]])
        let stretched = Syllabifier.fit([["S", "T", "AA", "R"]], into: 3)
        #expect(stretched.count == 3)
        #expect(stretched.allSatisfy { $0.contains(where: Phonemes.isVowel) })
        #expect(stretched.last?.last == "R")  // coda moves to the end
        #expect(stretched.first == ["S", "T", "AA"])
        #expect(Syllabifier.fit([], into: 2) == [[], []])
        #expect(Syllabifier.fit(two, into: 0) == [])
    }

    @Test func tokenizeConventions() {
        let aligner = LyricsAligner()
        let tokens = aligner.tokenize("Twin-kle star _ _ la-la-la")
        #expect(tokens.count == 8)
        guard case .syllable(let first) = tokens[0], case .syllable(let second) = tokens[1] else {
            Issue.record("expected syllables"); return
        }
        #expect(first == Syllable(text: "Twin", kind: .begin))
        #expect(second == Syllable(text: "kle", kind: .end))
        #expect(tokens[2] == .syllable(Syllable(text: "star", kind: .single)))
        #expect(tokens[3] == .melisma)
        #expect(tokens[4] == .melisma)
        #expect(tokens[5] == .syllable(Syllable(text: "la", kind: .begin)))
        #expect(tokens[6] == .syllable(Syllable(text: "la", kind: .middle)))
        #expect(tokens[7] == .syllable(Syllable(text: "la", kind: .end)))
    }

    @Test func hyphenate() {
        let aligner = LyricsAligner()
        #expect(aligner.hyphenate("Twin-kle") == ["Twin", "kle"])
        #expect(aligner.hyphenate("star") == ["star"])
        let wonder = aligner.hyphenate("wonder")
        #expect(wonder.count == 2)
        #expect(wonder.joined() == "wonder")
        let little = aligner.hyphenate("little")
        #expect(little.count == 2)
        #expect(little.joined() == "little")
    }

    @Test func alignTwinkleText() throws {
        var score = try TestSupport.importFixture("MusicXML/twinkle.musicxml")
        for i in score.notes.indices { score.notes[i].lyric = nil }
        let text = try String(contentsOf: TestSupport.fixture("Lyrics/twinkle.txt"), encoding: .utf8)
        let warnings = LyricsAligner().align(text, to: &score)
        #expect(warnings.isEmpty)
        #expect(score.notes.compactMap(\.lyric).count == 14)
        #expect(score.notes[0].lyric?.text == "Twin")
        #expect(score.notes[0].lyric?.kind == .begin)
        #expect(score.notes[1].lyric?.kind == .end)
        #expect(score.notes[6].lyric?.text == "star,")
        #expect(score.notes[13].lyric?.text == "are")
    }

    @Test func alignWarningsAndMelisma() {
        var score = TestSupport.score([(60, 0, 1, nil), (62, 1, 1, nil), (64, 2, 1, nil)])
        // Too many syllables.
        var warnings = LyricsAligner().align("a b c d e", to: &score)
        #expect(warnings.map(\.kind) == [.leftoverSyllables(["d", "e"])])
        // Too few syllables.
        warnings = LyricsAligner().align("la", to: &score)
        #expect(warnings.map(\.kind) == [.notesWithoutLyrics([2, 3])])
        #expect(!warnings[0].description.isEmpty)
        // Melisma with "_".
        warnings = LyricsAligner().align("ah _ oh", to: &score)
        #expect(warnings.isEmpty)
        #expect(score.notes[0].lyric?.text == "ah")
        #expect(score.notes[1].lyric == nil)
        #expect(score.notes[1].continuesSyllable)
        #expect(score.notes[2].lyric?.text == "oh")
        #expect(!score.notes[2].continuesSyllable)
        // A leading "_" has nothing to hold.
        warnings = LyricsAligner().align("_ la la", to: &score)
        #expect(warnings.map(\.kind).contains(.notesWithoutLyrics([1])))
    }

    @Test func keepsSourceMelismas() throws {
        var score = try TestSupport.importFixture("MusicXML/amazing_grace.musicxml")
        let count = score.notes.filter { $0.lyric != nil }.count
        let text = score.notes.compactMap { $0.lyric?.text }.joined(separator: " ")
        let warnings = LyricsAligner().align(text, to: &score, keepMelismas: true)
        #expect(warnings.isEmpty)
        #expect(score.notes.filter { $0.lyric != nil }.count == count)
        #expect(score.notes.filter(\.continuesSyllable).count == 1)
    }

    @Test func phonemizerSplitsMultiNoteWords() throws {
        var score = TestSupport.score([(60, 0, 1, nil), (60, 1, 1, nil), (67, 2, 1, nil)])
        score.notes[0].lyric = Syllable(text: "Twin", kind: .begin)
        score.notes[1].lyric = Syllable(text: "kle", kind: .end)
        score.notes[2].lyric = Syllable(text: "star", kind: .single)
        Phonemizer().apply(to: &score)
        #expect(score.notes[0].lyric?.phonemes == ["T", "W", "IH", "NG"])
        #expect(score.notes[1].lyric?.phonemes == ["K", "AH", "L"])
        #expect(score.notes[2].lyric?.phonemes == ["S", "T", "AA", "R"])
        // Existing phonemes are kept unless overwrite is set.
        score.notes[2].lyric?.phonemes = ["AH"]
        Phonemizer().apply(to: &score)
        #expect(score.notes[2].lyric?.phonemes == ["AH"])
        Phonemizer().apply(to: &score, overwrite: true)
        #expect(score.notes[2].lyric?.phonemes == ["S", "T", "AA", "R"])
    }

    @Test func phonemizerFullSong() throws {
        var score = try TestSupport.importFixture("MusicXML/twinkle.musicxml")
        Phonemizer(language: .english).apply(to: &score)
        for note in score.notes {
            let p = try #require(note.lyric?.phonemes)
            #expect(p.filter(Phonemes.isVowel).count >= 1)
        }
    }
}
