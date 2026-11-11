import Foundation

/// A grapheme-to-phoneme converter for one language.
public protocol G2P: Sendable {
    /// Phonemes for one word (no stress digits). Never empty for a word with letters.
    func phonemes(for word: String) -> [String]
}

/// English G2P: the bundled CMU Pronouncing Dictionary (134k words), with
/// letter-to-sound rules for words it does not know. The plan replaces the rules with a
/// small Core ML model later; the interface stays the same.
public final class EnglishG2P: G2P, @unchecked Sendable {
    public static let shared = EnglishG2P()

    private let lock = NSLock()
    private var dictionary: [String: [String]]?
    private var userLexicon: [String: [String]] = [:]

    public init() {}

    /// Adds or overrides a pronunciation (for names, slang, or user fixes in the editor).
    public func addPronunciation(_ word: String, phonemes: [String]) {
        lock.lock(); defer { lock.unlock() }
        userLexicon[Self.normalize(word)] = phonemes.map(Phonemes.stripStress)
    }

    /// True if the word is in the dictionary (or the user lexicon).
    public func knows(_ word: String) -> Bool {
        let key = Self.normalize(word)
        lock.lock(); defer { lock.unlock() }
        return userLexicon[key] != nil || loadedDictionary()[key] != nil
    }

    public func phonemes(for word: String) -> [String] {
        let key = Self.normalize(word)
        guard !key.isEmpty else { return [] }
        lock.lock()
        let known = userLexicon[key] ?? loadedDictionary()[key]
        lock.unlock()
        if let known { return known }
        // Compounds and contractions the dictionary lacks: try the parts.
        for separator in ["-", "'"] where key.contains(separator) {
            let parts = key.split(separator: Character(separator)).map(String.init).filter { !$0.isEmpty }
            if parts.count > 1 { return parts.flatMap { phonemes(for: $0) } }
        }
        return LetterToSound.english(key)
    }

    static func normalize(_ word: String) -> String {
        let lowered = word.lowercased()
            .replacingOccurrences(of: "\u{2019}", with: "'")
            .replacingOccurrences(of: "\u{2018}", with: "'")
        let allowed = lowered.filter { $0.isLetter || $0 == "'" || $0 == "-" }
        return allowed.trimmingCharacters(in: CharacterSet(charactersIn: "'-"))
    }

    /// Must be called with the lock held.
    private func loadedDictionary() -> [String: [String]] {
        if let dictionary { return dictionary }
        var dict: [String: [String]] = [:]
        dict.reserveCapacity(140_000)
        if let url = Bundle.module.url(forResource: "cmudict", withExtension: "dict"),
           let data = try? Data(contentsOf: url)
        {
            data.withUnsafeBytes { raw in
                // Parse "word P1 P2 ... # comment" lines; keep the first variant only.
                for line in raw.split(separator: UInt8(ascii: "\n")) {
                    var fields = line.split(separator: UInt8(ascii: " "))
                    if let hash = fields.firstIndex(where: { $0.first == UInt8(ascii: "#") }) {
                        fields = Array(fields[..<hash])
                    }
                    guard fields.count >= 2 else { continue }
                    let word = String(decoding: fields[0], as: UTF8.self)
                    if word.hasSuffix(")") { continue }  // alternate pronunciation "word(2)"
                    dict[word] = fields.dropFirst().map {
                        String(decoding: $0.filter { !(48...57).contains($0) }, as: UTF8.self)
                    }
                }
            }
        }
        dictionary = dict
        return dict
    }
}

/// Simple English letter-to-sound rules for out-of-dictionary words.
enum LetterToSound {
    private static let consonantMap: [Character: [String]] = [
        "b": ["B"], "d": ["D"], "f": ["F"], "h": ["HH"], "j": ["JH"], "k": ["K"], "l": ["L"],
        "m": ["M"], "n": ["N"], "p": ["P"], "q": ["K"], "r": ["R"], "s": ["S"], "t": ["T"],
        "v": ["V"], "w": ["W"], "x": ["K", "S"], "z": ["Z"],
    ]
    // Longest patterns first.
    private static let patterns: [(String, [String])] = [
        ("tion", ["SH", "AH", "N"]), ("sion", ["ZH", "AH", "N"]), ("ough", ["AO"]), ("augh", ["AO"]),
        ("tch", ["CH"]), ("igh", ["AY"]), ("dge", ["JH"]),
        ("ch", ["CH"]), ("sh", ["SH"]), ("th", ["TH"]), ("ph", ["F"]), ("ng", ["NG"]), ("ck", ["K"]),
        ("qu", ["K", "W"]), ("wh", ["W"]), ("wr", ["R"]), ("kn", ["N"]), ("gh", []),
        ("ee", ["IY"]), ("ea", ["IY"]), ("ie", ["IY"]), ("ei", ["EY"]), ("oo", ["UW"]), ("ou", ["AW"]),
        ("ow", ["OW"]), ("ai", ["EY"]), ("ay", ["EY"]), ("oi", ["OY"]), ("oy", ["OY"]), ("au", ["AO"]),
        ("aw", ["AO"]), ("oa", ["OW"]), ("ew", ["UW"]), ("ue", ["UW"]),
        ("er", ["ER"]), ("ir", ["ER"]), ("ur", ["ER"]), ("ar", ["AA", "R"]), ("or", ["AO", "R"]),
    ]
    private static let shortVowel: [Character: String] = ["a": "AE", "e": "EH", "i": "IH", "o": "AA", "u": "AH", "y": "IH"]
    private static let longVowel: [Character: String] = ["a": "EY", "e": "IY", "i": "AY", "o": "OW", "u": "UW", "y": "AY"]

    static func english(_ word: String) -> [String] {
        let letters = Array(word.lowercased().filter { $0.isLetter })
        guard !letters.isEmpty else { return [] }
        let vowelLetters: Set<Character> = ["a", "e", "i", "o", "u", "y"]
        var result: [String] = []
        var i = 0
        // A final "e" after a consonant is silent and makes the previous vowel long.
        let silentFinalE = letters.count > 2 && letters.last == "e" && !vowelLetters.contains(letters[letters.count - 2])
            && letters.dropLast().contains(where: { vowelLetters.contains($0) })
        let end = silentFinalE ? letters.count - 1 : letters.count
        while i < end {
            var matched = false
            for (pattern, phones) in patterns {
                let p = Array(pattern)
                if i + p.count <= end, Array(letters[i..<(i + p.count)]) == p {
                    result += phones
                    i += p.count
                    matched = true
                    break
                }
            }
            if matched { continue }
            let c = letters[i]
            let next: Character? = i + 1 < letters.count ? letters[i + 1] : nil
            if i > 0, letters[i - 1] == c, !vowelLetters.contains(c) { i += 1; continue }  // double consonant
            if vowelLetters.contains(c) {
                if c == "y" && i == 0 { result.append("Y"); i += 1; continue }
                // Long vowel before consonant + silent e ("make", "time").
                let isLong = silentFinalE && i == end - 2 && !vowelLetters.contains(letters[end - 1])
                if c == "y" && i == end - 1 { result.append(letters.count <= 3 ? "AY" : "IY") }
                else if isLong { result.append(longVowel[c]!) }
                else if i == end - 1 && c != "a" && letters.count <= 3 { result.append(longVowel[c]!) }  // "go", "be"
                else { result.append(shortVowel[c]!) }
            } else if c == "c" {
                result.append(next.map { "eiy".contains($0) } == true ? "S" : "K")
            } else if c == "g" {
                result.append(next.map { "eiy".contains($0) } == true && i > 0 ? "JH" : "G")
            } else if let phones = consonantMap[c] {
                result += phones
            }
            i += 1
        }
        if !result.contains(where: Phonemes.isVowel) { result.append("AH") }
        return result
    }
}
