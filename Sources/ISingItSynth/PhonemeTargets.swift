import Foundation

/// Acoustic targets for one phoneme in the formant voice (adult male reference values;
/// a voice's formant scale shifts them).
struct PhonemeTarget {
    /// Formant frequencies F1...F3 in Hz.
    var formants: (Double, Double, Double)
    /// Formant bandwidths in Hz.
    var bandwidths: (Double, Double, Double) = (70, 90, 140)
    /// Voicing amplitude (0...1).
    var voicing: Double = 1
    /// Frication noise amplitude and band.
    var frication: Double = 0
    var fricationCenter: Double = 5000
    var fricationBandwidth: Double = 3000
    /// Aspiration noise through the vocal tract.
    var aspiration: Double = 0
    /// Diphthongs glide to these formants at the end of the segment.
    var endFormants: (Double, Double, Double)?
    /// Stops and affricates: fraction of the segment that is closure (silence or voice bar).
    var closure: Double = 0
    /// Voiceless stops: aspiration after the burst.
    var burstAspiration: Double = 0
    /// Nasal murmur: muffles the upper spectrum.
    var nasal = false
    /// Takes its formants from the next phoneme (HH, and stop releases).
    var borrowsFormants = false
    /// Velar stops: F1 low and F3 pinched towards F2.
    var velar = false

    static func vowel(_ f1: Double, _ f2: Double, _ f3: Double, to end: (Double, Double, Double)? = nil) -> PhonemeTarget {
        PhonemeTarget(formants: (f1, f2, f3), endFormants: end)
    }

    static let neutral = (500.0, 1500.0, 2500.0)

    static let table: [String: PhonemeTarget] = {
        var t: [String: PhonemeTarget] = [:]
        // Vowels (Peterson & Barney style averages, opened slightly for singing).
        t["IY"] = .vowel(280, 2250, 2950)
        t["IH"] = .vowel(400, 1950, 2550)
        t["EH"] = .vowel(540, 1800, 2480)
        t["AE"] = .vowel(660, 1700, 2410)
        t["AH"] = .vowel(620, 1200, 2400)
        t["AA"] = .vowel(730, 1100, 2450)
        t["AO"] = .vowel(580, 860, 2410)
        t["UH"] = .vowel(450, 1030, 2240)
        t["UW"] = .vowel(320, 880, 2240)
        t["ER"] = .vowel(490, 1350, 1700)
        t["EY"] = .vowel(500, 1750, 2500, to: (330, 2150, 2700))
        t["AY"] = .vowel(730, 1150, 2450, to: (420, 1950, 2550))
        t["OW"] = .vowel(560, 880, 2400, to: (380, 820, 2300))
        t["AW"] = .vowel(730, 1150, 2450, to: (420, 900, 2300))
        t["OY"] = .vowel(560, 860, 2410, to: (420, 1950, 2550))

        // Nasals.
        t["M"] = PhonemeTarget(formants: (260, 1100, 2200), bandwidths: (60, 300, 300), voicing: 0.5, nasal: true)
        t["N"] = PhonemeTarget(formants: (260, 1600, 2600), bandwidths: (60, 300, 300), voicing: 0.5, nasal: true)
        t["NG"] = PhonemeTarget(formants: (260, 2000, 2700), bandwidths: (60, 300, 300), voicing: 0.45, nasal: true)

        // Liquids and glides.
        t["L"] = PhonemeTarget(formants: (360, 1050, 2700), bandwidths: (80, 150, 200), voicing: 0.75)
        t["R"] = PhonemeTarget(formants: (420, 1200, 1600), bandwidths: (80, 120, 150), voicing: 0.75)
        t["W"] = PhonemeTarget(formants: (300, 700, 2200), bandwidths: (70, 100, 150), voicing: 0.7)
        t["Y"] = PhonemeTarget(formants: (280, 2200, 2950), bandwidths: (70, 100, 150), voicing: 0.7)

        // Aspirate.
        t["HH"] = PhonemeTarget(formants: neutral, voicing: 0, aspiration: 1.4, borrowsFormants: true)

        // Fricatives.
        t["F"] = PhonemeTarget(formants: (400, 1300, 2500), voicing: 0, frication: 0.22, fricationCenter: 7000, fricationBandwidth: 6000)
        t["TH"] = PhonemeTarget(formants: (400, 1500, 2600), voicing: 0, frication: 0.16, fricationCenter: 6500, fricationBandwidth: 6000)
        t["S"] = PhonemeTarget(formants: (400, 1600, 2600), voicing: 0, frication: 0.55, fricationCenter: 6800, fricationBandwidth: 3000)
        t["SH"] = PhonemeTarget(formants: (400, 1800, 2500), voicing: 0, frication: 0.5, fricationCenter: 3300, fricationBandwidth: 2200)
        t["V"] = PhonemeTarget(formants: (350, 1300, 2400), voicing: 0.45, frication: 0.12, fricationCenter: 7000, fricationBandwidth: 6000)
        t["DH"] = PhonemeTarget(formants: (350, 1500, 2500), voicing: 0.5, frication: 0.08, fricationCenter: 6500, fricationBandwidth: 6000)
        t["Z"] = PhonemeTarget(formants: (350, 1600, 2600), voicing: 0.35, frication: 0.38, fricationCenter: 6800, fricationBandwidth: 3000)
        t["ZH"] = PhonemeTarget(formants: (350, 1800, 2500), voicing: 0.35, frication: 0.35, fricationCenter: 3300, fricationBandwidth: 2200)

        // Stops: closure, then a burst shaped by place of articulation.
        // Labials and alveolars use their formant loci (the transitions into the next vowel
        // are the main cue); velars take the next vowel's F2 with F3 pinched close to it.
        t["P"] = PhonemeTarget(formants: (280, 850, 2100), voicing: 0, frication: 0.6, fricationCenter: 1200, fricationBandwidth: 2400, closure: 0.5, burstAspiration: 0.45)
        t["B"] = PhonemeTarget(formants: (250, 850, 2100), voicing: 0.2, frication: 0.4, fricationCenter: 1200, fricationBandwidth: 2400, closure: 0.5)
        t["T"] = PhonemeTarget(formants: (280, 1800, 2700), voicing: 0, frication: 0.9, fricationCenter: 4800, fricationBandwidth: 3500, closure: 0.5, burstAspiration: 0.45)
        t["D"] = PhonemeTarget(formants: (250, 1750, 2700), voicing: 0.2, frication: 0.75, fricationCenter: 4300, fricationBandwidth: 3500, closure: 0.5)
        t["K"] = PhonemeTarget(formants: neutral, voicing: 0, frication: 0.8, fricationCenter: 2500, fricationBandwidth: 1600, closure: 0.5, burstAspiration: 0.45, borrowsFormants: true, velar: true)
        t["G"] = PhonemeTarget(formants: neutral, voicing: 0.2, frication: 0.75, fricationCenter: 2300, fricationBandwidth: 1600, closure: 0.5, borrowsFormants: true, velar: true)

        // Affricates: closure then a SH-like release.
        t["CH"] = PhonemeTarget(formants: (400, 1800, 2500), voicing: 0, frication: 0.5, fricationCenter: 3300, fricationBandwidth: 2200, closure: 0.4)
        t["JH"] = PhonemeTarget(formants: (350, 1800, 2500), voicing: 0.35, frication: 0.35, fricationCenter: 3300, fricationBandwidth: 2200, closure: 0.4)
        return t
    }()

    static func of(_ phoneme: String) -> PhonemeTarget {
        table[phoneme] ?? .vowel(620, 1200, 2400)
    }
}
