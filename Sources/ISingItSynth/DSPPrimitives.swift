import Foundation

/// Klatt two-pole resonator with unity gain at DC.
struct Resonator {
    private var a = 1.0, b = 0.0, c = 0.0
    private var y1 = 0.0, y2 = 0.0

    mutating func set(frequency: Double, bandwidth: Double, sampleRate: Double) {
        let f = min(frequency, sampleRate * 0.45)
        let r = exp(-Double.pi * bandwidth / sampleRate)
        c = -r * r
        b = 2 * r * cos(2 * Double.pi * f / sampleRate)
        a = 1 - b - c
    }

    @inline(__always) mutating func process(_ x: Double) -> Double {
        let y = a * x + b * y1 + c * y2
        y2 = y1
        y1 = y
        return y
    }
}

/// RBJ biquad (band-pass, constant 0 dB peak gain).
struct Biquad {
    private var b0 = 0.0, b1 = 0.0, b2 = 0.0, a1 = 0.0, a2 = 0.0
    private var x1 = 0.0, x2 = 0.0, y1 = 0.0, y2 = 0.0

    mutating func setBandpass(center: Double, bandwidth: Double, sampleRate: Double) {
        let w0 = 2 * Double.pi * center / sampleRate
        let q = max(0.3, center / max(1, bandwidth))
        let alpha = sin(w0) / (2 * q)
        let a0 = 1 + alpha
        b0 = alpha / a0
        b1 = 0
        b2 = -alpha / a0
        a1 = -2 * cos(w0) / a0
        a2 = (1 - alpha) / a0
    }

    @inline(__always) mutating func process(_ x: Double) -> Double {
        let y = b0 * x + b1 * x1 + b2 * x2 - a1 * y1 - a2 * y2
        x2 = x1; x1 = x
        y2 = y1; y1 = y
        return y
    }
}

/// One-pole low-pass.
struct OnePole {
    private var a = 1.0
    private var y = 0.0

    mutating func set(cutoff: Double, sampleRate: Double) {
        a = 1 - exp(-2 * Double.pi * cutoff / sampleRate)
    }

    @inline(__always) mutating func process(_ x: Double) -> Double {
        y += a * (x - y)
        return y
    }
}

struct DCBlocker {
    private var x1 = 0.0, y1 = 0.0

    @inline(__always) mutating func process(_ x: Double) -> Double {
        let y = x - x1 + 0.995 * y1
        x1 = x
        y1 = y
        return y
    }
}

/// Small deterministic random generator, so a phrase always renders to the same audio.
struct SplitMix {
    private var state: UInt64

    init(seed: UInt64) { state = seed &+ 0x9E37_79B9_7F4A_7C15 }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    /// Uniform in -1...1.
    mutating func uniform() -> Double {
        Double(next() >> 11) / Double(1 << 52) - 1
    }
}
