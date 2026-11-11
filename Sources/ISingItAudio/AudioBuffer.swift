import Foundation

/// Mono floating-point audio.
public struct AudioBuffer: Sendable, Equatable {
    public var sampleRate: Double
    public var samples: [Float]

    public init(sampleRate: Double, samples: [Float] = []) {
        self.sampleRate = sampleRate
        self.samples = samples
    }

    public init(sampleRate: Double, duration: Double) {
        self.sampleRate = sampleRate
        self.samples = [Float](repeating: 0, count: max(0, Int((duration * sampleRate).rounded(.up))))
    }

    public var duration: Double { Double(samples.count) / sampleRate }

    public var peak: Float { samples.reduce(0) { max($0, abs($1)) } }

    public var rms: Float {
        guard !samples.isEmpty else { return 0 }
        let sum = samples.reduce(0.0) { $0 + Double($1) * Double($1) }
        return Float((sum / Double(samples.count)).squareRoot())
    }

    /// Adds `other` starting at `time` seconds, growing the buffer if needed.
    public mutating func mix(_ other: [Float], at time: Double, gain: Float = 1) {
        let offset = max(0, Int((time * sampleRate).rounded()))
        if offset + other.count > samples.count {
            samples += [Float](repeating: 0, count: offset + other.count - samples.count)
        }
        for i in other.indices { samples[offset + i] += other[i] * gain }
    }

    /// Scales so the peak is at `level` (no-op for silence).
    public mutating func normalize(peak level: Float = 0.89) {
        let p = peak
        guard p > 1e-6 else { return }
        let g = level / p
        for i in samples.indices { samples[i] *= g }
    }
}

public enum WAVFormat: Sendable {
    case pcm16, pcm24, float32
}

public enum WAVError: Error, CustomStringConvertible {
    case invalid(String)
    public var description: String {
        switch self { case .invalid(let why): "Invalid WAV file: \(why)" }
    }
}

/// Reads and writes RIFF WAV files. Pure Swift so export works the same everywhere; the
/// Mac app adds AIFF and FLAC through AVAudioFile.
public enum WAVFile {
    public static func data(_ buffer: AudioBuffer, format: WAVFormat = .pcm16) -> Data {
        let channels = 1
        let bits: Int = switch format { case .pcm16: 16; case .pcm24: 24; case .float32: 32 }
        let bytesPerSample = bits / 8
        let dataSize = buffer.samples.count * bytesPerSample * channels
        var d = Data(capacity: 44 + dataSize)
        func u32(_ v: Int) { var x = UInt32(v).littleEndian; withUnsafeBytes(of: &x) { d.append(contentsOf: $0) } }
        func u16(_ v: Int) { var x = UInt16(v).littleEndian; withUnsafeBytes(of: &x) { d.append(contentsOf: $0) } }
        d.append(contentsOf: Array("RIFF".utf8)); u32(36 + dataSize); d.append(contentsOf: Array("WAVE".utf8))
        d.append(contentsOf: Array("fmt ".utf8)); u32(16)
        u16(format == .float32 ? 3 : 1); u16(channels); u32(Int(buffer.sampleRate))
        u32(Int(buffer.sampleRate) * bytesPerSample * channels); u16(bytesPerSample * channels); u16(bits)
        d.append(contentsOf: Array("data".utf8)); u32(dataSize)
        switch format {
        case .pcm16:
            for s in buffer.samples {
                var v = Int16(max(-32768, min(32767, (Double(s) * 32767).rounded()))).littleEndian
                withUnsafeBytes(of: &v) { d.append(contentsOf: $0) }
            }
        case .pcm24:
            for s in buffer.samples {
                let v = Int32(max(-8_388_608, min(8_388_607, (Double(s) * 8_388_607).rounded())))
                d.append(UInt8(truncatingIfNeeded: v)); d.append(UInt8(truncatingIfNeeded: v >> 8)); d.append(UInt8(truncatingIfNeeded: v >> 16))
            }
        case .float32:
            for s in buffer.samples {
                var v = s.bitPattern.littleEndian
                withUnsafeBytes(of: &v) { d.append(contentsOf: $0) }
            }
        }
        return d
    }

    public static func write(_ buffer: AudioBuffer, to url: URL, format: WAVFormat = .pcm16) throws {
        try data(buffer, format: format).write(to: url)
    }

    /// Reads a PCM 16/24-bit or float32 WAV; multi-channel files are mixed to mono.
    public static func read(_ data: Data) throws -> AudioBuffer {
        let b = [UInt8](data)
        guard b.count >= 12, String(decoding: b[0..<4], as: UTF8.self) == "RIFF",
              String(decoding: b[8..<12], as: UTF8.self) == "WAVE" else { throw WAVError.invalid("not RIFF/WAVE") }
        func u16(_ i: Int) -> Int { Int(b[i]) | Int(b[i + 1]) << 8 }
        func u32(_ i: Int) -> Int { u16(i) | u16(i + 2) << 16 }
        var p = 12
        var formatTag = 0, channels = 0, rate = 0, bits = 0
        while p + 8 <= b.count {
            let id = String(decoding: b[p..<(p + 4)], as: UTF8.self)
            let size = u32(p + 4)
            let body = p + 8
            if id == "fmt " {
                formatTag = u16(body); channels = u16(body + 2); rate = u32(body + 4); bits = u16(body + 14)
                if formatTag == 0xFFFE, size >= 26 { formatTag = u16(body + 24) }
            } else if id == "data" {
                guard channels > 0, bits > 0 else { throw WAVError.invalid("data before fmt") }
                let bytes = bits / 8
                let frameCount = min(size, b.count - body) / (bytes * channels)
                var samples = [Float](repeating: 0, count: frameCount)
                for f in 0..<frameCount {
                    var sum: Float = 0
                    for c in 0..<channels {
                        let i = body + (f * channels + c) * bytes
                        switch (formatTag, bits) {
                        case (1, 16): sum += Float(Int16(bitPattern: UInt16(u16(i)))) / 32768
                        case (1, 24):
                            let v = Int32(bitPattern: UInt32(b[i]) << 8 | UInt32(b[i + 1]) << 16 | UInt32(b[i + 2]) << 24) >> 8
                            sum += Float(v) / 8_388_608
                        case (3, 32): sum += Float(bitPattern: UInt32(u32(i)))
                        default: throw WAVError.invalid("unsupported format \(formatTag)/\(bits)-bit")
                        }
                    }
                    samples[f] = sum / Float(channels)
                }
                return AudioBuffer(sampleRate: Double(rate), samples: samples)
            }
            p = body + size + (size & 1)
        }
        throw WAVError.invalid("no data chunk")
    }
}
