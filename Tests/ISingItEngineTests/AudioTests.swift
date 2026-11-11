import Foundation
import Testing
import ISingItEngine

@Suite struct AudioTests {
    func sine(_ seconds: Double = 0.25, rate: Double = 16_000, amp: Float = 0.7) -> AudioBuffer {
        let n = Int(seconds * rate)
        return AudioBuffer(sampleRate: rate, samples: (0..<n).map { amp * Float(sin(2 * Double.pi * 440 * Double($0) / rate)) })
    }

    @Test(arguments: [WAVFormat.pcm16, .pcm24, .float32])
    func wavRoundTrip(format: WAVFormat) throws {
        let buffer = sine()
        let data = WAVFile.data(buffer, format: format)
        let bytesPer = format == .pcm16 ? 2 : format == .pcm24 ? 3 : 4
        #expect(data.count == 44 + buffer.samples.count * bytesPer)
        let decoded = try WAVFile.read(data)
        #expect(decoded.sampleRate == buffer.sampleRate)
        #expect(decoded.samples.count == buffer.samples.count)
        let tolerance: Float = format == .pcm16 ? 4e-5 : format == .pcm24 ? 1.0 / 8_000_000 : 0
        for (a, b) in zip(buffer.samples, decoded.samples) { #expect(abs(a - b) <= tolerance + 1e-7) }
    }

    @Test func wavFileOnDisk() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("isingit-\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: url) }
        let buffer = sine()
        try WAVFile.write(buffer, to: url, format: .pcm24)
        let decoded = try WAVFile.read(Data(contentsOf: url))
        #expect(decoded.samples.count == buffer.samples.count)
    }

    @Test func wavClipsAndRejectsGarbage() throws {
        let loud = AudioBuffer(sampleRate: 8000, samples: [2, -2, 0])
        let decoded = try WAVFile.read(WAVFile.data(loud))
        #expect(decoded.samples[0] > 0.99 && decoded.samples[1] < -0.99)
        #expect(throws: WAVError.self) { try WAVFile.read(Data("hello".utf8)) }
        #expect(throws: WAVError.self) { try WAVFile.read(Data(repeating: 0, count: 100)) }
        #expect(!WAVError.invalid("x").description.isEmpty)
    }

    @Test func mixGrowsBuffer() {
        var buffer = AudioBuffer(sampleRate: 1000, duration: 1)
        #expect(buffer.samples.count == 1000)
        buffer.mix([Float](repeating: 0.5, count: 500), at: 0.75)
        #expect(buffer.samples.count == 1250)
        #expect(buffer.samples[800] == 0.5)
        buffer.mix([Float](repeating: 0.25, count: 100), at: 0.8, gain: 2)
        #expect(buffer.samples[850] == 1.0)
        #expect(buffer.samples[0] == 0)
        #expect(abs(buffer.duration - 1.25) < 1e-9)
    }

    @Test func peakRmsNormalize() {
        var buffer = AudioBuffer(sampleRate: 100, samples: [0.1, -0.4, 0.2])
        #expect(buffer.peak == 0.4)
        buffer.normalize(peak: 0.8)
        #expect(abs(buffer.peak - 0.8) < 1e-6)
        var silent = AudioBuffer(sampleRate: 100, duration: 1)
        silent.normalize()
        #expect(silent.peak == 0)
        #expect(AudioBuffer(sampleRate: 100).rms == 0)
        #expect(abs(Double(sine().rms) - 0.7 / 2.0.squareRoot()) < 0.01)
    }
}
