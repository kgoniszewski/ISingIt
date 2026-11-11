import Foundation
import ISingItScore

/// A problem found while aligning lyrics, shown in the editor.
public struct AlignmentWarning: Sendable, Equatable, CustomStringConvertible {
    public enum Kind: Sendable, Equatable {
        /// More syllables than notes: these syllables were not placed.
        case leftoverSyllables([String])
        /// More notes than syllables: these note ids have no lyric.
        case notesWithoutLyrics([Int])
    }

    public var kind: Kind

    public var description: String {
        switch kind {
        case .leftoverSyllables(let s): "\(s.count) syllable(s) did not fit on notes: \(s.joined(separator: " "))"
        case .notesWithoutLyrics(let ids): "\(ids.count) note(s) have no lyric"
        }
    }
}

/// Lyrics.Align: splits lyric text into syllables and places one syllable per note.
///
/// Text conventions: words are separated by spaces; "-" inside a word forces a syllable
/// split ("Twin-kle"); a lone "_" holds the previous syllable over the next note (melisma).
public struct LyricsAligner: Sendable {
    public var g2p: any G2P

    public init(g2p: any G2P = EnglishG2P.shared) {
        self.g2p = g2p
    }

    public enum Token: Equatable, Sendable {
        case syllable(Syllable)
        case melisma
    }

    /// Splits text into syllables (with word positions) and melisma markers.
    public func tokenize(_ text: String) -> [Token] {
        var tokens: [Token] = []
        for raw in text.split(whereSeparator: { $0.isWhitespace }) {
            let word = String(raw)
            if word.allSatisfy({ $0 == "_" }) {
                tokens.append(contentsOf: Array(repeating: .melisma, count: word.count))
                continue
            }
            let pieces = hyphenate(word)
            for (i, piece) in pieces.enumerated() {
                let kind: Syllable.Kind =
                    pieces.count == 1 ? .single : i == 0 ? .begin : i == pieces.count - 1 ? .end : .middle
                tokens.append(.syllable(Syllable(text: piece, kind: kind)))
            }
        }
        return tokens
    }

    /// Splits one written word into sung syllables. Explicit hyphens win; otherwise the
    /// number of syllables comes from the word's pronunciation.
    public func hyphenate(_ word: String) -> [String] {
        let explicit = word.split(separator: "-", omittingEmptySubsequences: true).map(String.init)
        if explicit.count > 1 { return explicit }
        let count = Syllabifier.syllabify(g2p.phonemes(for: word)).count
        return Self.splitSpelling(word, into: max(1, count))
    }

    /// Splits the spelling into `count` pieces at vowel-group boundaries (for display).
    static func splitSpelling(_ word: String, into count: Int) -> [String] {
        let chars = Array(word)
        guard count > 1, chars.count > 1 else { return [word] }
        let isVowel: (Character) -> Bool = { "aeiouyAEIOUY".contains($0) }
        // Vowel groups, ignoring a final silent "e".
        var groups: [Range<Int>] = []
        var i = 0
        while i < chars.count {
            if isVowel(chars[i]) {
                var j = i
                while j < chars.count && isVowel(chars[j]) { j += 1 }
                groups.append(i..<j)
                i = j
            } else {
                i += 1
            }
        }
        let letters = chars.filter(\.isLetter)
        if groups.count > 1, let last = groups.last, last.count == 1,
           chars[last.lowerBound].lowercased() == "e", !chars[(last.upperBound)...].contains(where: \.isLetter),
           letters.count > 3, !(last.lowerBound > 0 && "l".contains(chars[last.lowerBound - 1].lowercased()))
        {
            groups.removeLast()
        }
        guard groups.count >= count else {
            // Not enough vowel groups: cut into roughly equal pieces.
            let size = max(1, chars.count / count)
            return (0..<count).map { k in
                let start = min(chars.count, k * size)
                let end = k == count - 1 ? chars.count : min(chars.count, (k + 1) * size)
                return String(chars[start..<end])
            }.filter { !$0.isEmpty }
        }
        // Use the first `count` group boundaries spread over the word.
        let chosen = (0..<count).map { groups[$0 * groups.count / count] }
        var cuts: [Int] = []
        for k in 1..<count {
            let previous = chosen[k - 1], next = chosen[k]
            let consonants = next.lowerBound - previous.upperBound
            // VCV -> V-CV ; VCCV -> VC-CV ; VCCCV -> VC-CCV
            let cut = previous.upperBound + (consonants <= 1 ? 0 : 1)
            cuts.append(cut)
        }
        var pieces: [String] = []
        var start = 0
        for cut in cuts {
            pieces.append(String(chars[start..<cut]))
            start = cut
        }
        pieces.append(String(chars[start...]))
        return pieces.filter { !$0.isEmpty }
    }

    /// Places lyric text on the score's notes, replacing existing lyrics.
    /// - Parameter keepMelismas: keep melisma marks that came from the source (slurs).
    @discardableResult
    public func align(_ text: String, to score: inout Score, keepMelismas: Bool = true) -> [AlignmentWarning] {
        var tokens = tokenize(text)[...]
        var unlabelled: [Int] = []
        var previousHadSyllable = false
        for i in score.notes.indices {
            score.notes[i].lyric = nil
            let joined = i > 0 && abs(score.notes[i - 1].endBeat - score.notes[i].onset) < 1e-6
            if keepMelismas && score.notes[i].continuesSyllable && previousHadSyllable && joined {
                continue
            }
            score.notes[i].continuesSyllable = false
            guard let token = tokens.popFirst() else {
                unlabelled.append(score.notes[i].id)
                previousHadSyllable = false
                continue
            }
            switch token {
            case .syllable(let syllable):
                score.notes[i].lyric = syllable
                previousHadSyllable = true
            case .melisma:
                score.notes[i].continuesSyllable = previousHadSyllable
                if !previousHadSyllable { unlabelled.append(score.notes[i].id) }
            }
        }
        var warnings: [AlignmentWarning] = []
        let leftovers = tokens.compactMap { if case .syllable(let s) = $0 { s.text } else { nil } }
        if !leftovers.isEmpty { warnings.append(AlignmentWarning(kind: .leftoverSyllables(leftovers))) }
        if !unlabelled.isEmpty { warnings.append(AlignmentWarning(kind: .notesWithoutLyrics(unlabelled))) }
        return warnings
    }
}

/// Lyrics.G2P stage: fills `Syllable.phonemes` for every lyric in the score. Words that
/// span several notes are converted as a whole, then split back into the score's
/// syllables, so "twin-kle" is sung T W IH NG | K AH L.
public struct Phonemizer: Sendable {
    public var g2p: any G2P

    public init(g2p: any G2P = EnglishG2P.shared) {
        self.g2p = g2p
    }

    public init(language: Language) {
        switch language {
        case .english, .polish:  // Polish G2P arrives in phase 4; English rules are the fallback.
            self.g2p = EnglishG2P.shared
        }
    }

    public func apply(to score: inout Score, overwrite: Bool = false) {
        var word: [Int] = []  // note indices of the current word's syllables

        func flush() {
            guard !word.isEmpty else { return }
            defer { word.removeAll() }
            if !overwrite, word.allSatisfy({ score.notes[$0].lyric?.phonemes != nil }) { return }
            let text = word.map { score.notes[$0].lyric!.text }.joined()
            let phonemes = g2p.phonemes(for: text)
            let groups = Syllabifier.fit(Syllabifier.syllabify(phonemes), into: word.count)
            for (k, index) in word.enumerated() {
                score.notes[index].lyric!.phonemes = groups[k].isEmpty ? ["AH"] : groups[k]
            }
        }

        for i in score.notes.indices {
            guard let lyric = score.notes[i].lyric else { continue }
            if lyric.kind == .single || lyric.kind == .begin { flush() }
            word.append(i)
            if !lyric.kind.continuesWord { flush() }
        }
        flush()
    }
}
