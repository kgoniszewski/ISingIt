import Foundation

/// ARPAbet phoneme classes used by the planner and the synthesizer.
public enum PhonemeClass: String, Sendable, Codable {
    case vowel, stop, affricate, fricative, nasal, liquid, glide, aspirate, silence
}

public enum Phonemes {
    public static let vowels: Set<String> = [
        "AA", "AE", "AH", "AO", "AW", "AY", "EH", "ER", "EY", "IH", "IY", "OW", "OY", "UH", "UW",
    ]
    public static let diphthongs: Set<String> = ["AW", "AY", "EY", "OW", "OY"]
    public static let stops: Set<String> = ["P", "B", "T", "D", "K", "G"]
    public static let affricates: Set<String> = ["CH", "JH"]
    public static let fricatives: Set<String> = ["F", "V", "TH", "DH", "S", "Z", "SH", "ZH"]
    public static let nasals: Set<String> = ["M", "N", "NG"]
    public static let liquids: Set<String> = ["L", "R"]
    public static let glides: Set<String> = ["W", "Y"]
    public static let voiced: Set<String> = ["B", "D", "G", "JH", "V", "DH", "Z", "ZH", "M", "N", "NG", "L", "R", "W", "Y"]

    /// Every English phoneme the engine knows (CMUdict's 39).
    public static let english: Set<String> = vowels.union(stops).union(affricates).union(fricatives)
        .union(nasals).union(liquids).union(glides).union(["HH"])

    public static func `class`(of phoneme: String) -> PhonemeClass {
        if vowels.contains(phoneme) { return .vowel }
        if stops.contains(phoneme) { return .stop }
        if affricates.contains(phoneme) { return .affricate }
        if fricatives.contains(phoneme) { return .fricative }
        if nasals.contains(phoneme) { return .nasal }
        if liquids.contains(phoneme) { return .liquid }
        if glides.contains(phoneme) { return .glide }
        if phoneme == "HH" { return .aspirate }
        return .silence
    }

    public static func isVowel(_ phoneme: String) -> Bool { vowels.contains(phoneme) }

    /// Strips CMUdict stress digits: "AY1" -> "AY".
    public static func stripStress(_ phoneme: String) -> String {
        String(phoneme.filter { !$0.isNumber })
    }
}

/// Splits a phoneme sequence into syllables (one vowel each) using the maximal-onset
/// principle with English onset clusters.
public enum Syllabifier {
    static let legalOnsets: Set<[String]> = {
        var set: Set<[String]> = []
        for c in Phonemes.english where !Phonemes.isVowel(c) && c != "NG" { set.insert([c]) }
        let pairs = [
            "P L", "P R", "B L", "B R", "K L", "K R", "G L", "G R", "F L", "F R", "T R", "D R", "TH R",
            "SH R", "S P", "S T", "S K", "S M", "S N", "S L", "S W", "S F", "K W", "T W", "D W", "G W",
            "TH W", "P Y", "B Y", "F Y", "M Y", "K Y", "HH Y", "V Y", "N Y", "L Y", "HH W",
            "S P L", "S P R", "S T R", "S K R", "S K W", "S K Y", "S P Y",
        ]
        for p in pairs { set.insert(p.split(separator: " ").map(String.init)) }
        return set
    }()

    public static func syllabify(_ phonemes: [String]) -> [[String]] {
        let vowelIndices = phonemes.indices.filter { Phonemes.isVowel(phonemes[$0]) }
        guard !vowelIndices.isEmpty else { return phonemes.isEmpty ? [] : [phonemes] }
        var boundaries: [Int] = [0]  // start index of each syllable
        for (a, b) in zip(vowelIndices, vowelIndices.dropFirst()) {
            let cluster = Array(phonemes[(a + 1)..<b])
            var onsetLength = 0
            for length in stride(from: cluster.count, through: 1, by: -1)
            where legalOnsets.contains(Array(cluster.suffix(length))) {
                onsetLength = length
                break
            }
            boundaries.append(b - onsetLength)
        }
        var result: [[String]] = []
        for (i, start) in boundaries.enumerated() {
            let end = i + 1 < boundaries.count ? boundaries[i + 1] : phonemes.count
            result.append(Array(phonemes[start..<end]))
        }
        return result
    }

    /// Fits `syllables` into exactly `count` groups: merges neighbours when there are too
    /// many (e.g. "fire" sung on one note), or repeats the last vowel when there are too
    /// few (a word stretched over more notes than it has syllables).
    public static func fit(_ syllables: [[String]], into count: Int) -> [[String]] {
        guard count > 0 else { return [] }
        if syllables.count == count { return syllables }
        if syllables.isEmpty { return Array(repeating: [], count: count) }
        if syllables.count > count {
            var groups = Array(repeating: [String](), count: count)
            for (j, syllable) in syllables.enumerated() {
                groups[j * count / syllables.count].append(contentsOf: syllable)
            }
            return groups
        }
        var result = syllables
        let lastVowel = syllables.last?.last(where: Phonemes.isVowel) ?? "AH"
        // Move the final coda to the last added syllable so the word ends correctly.
        var last = result.removeLast()
        var coda: [String] = []
        while let p = last.last, !Phonemes.isVowel(p) { coda.insert(last.removeLast(), at: 0) }
        result.append(last)
        while result.count < count { result.append([lastVowel]) }
        result[result.count - 1] += coda
        return result
    }
}
