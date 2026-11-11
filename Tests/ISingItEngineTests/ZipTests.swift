import Foundation
import Testing
import ISingItEngine

@Suite struct ZipTests {
    @Test func inflateViaMXL() throws {
        let data = try TestSupport.fixtureData("MusicXML/twinkle.mxl")
        #expect(ScoreImporter.kind(of: URL(fileURLWithPath: "x.bin"), data: data) == .musicXML)
        let score = try MusicXMLImporter().importScore(from: data)
        #expect(score.notes.count == 14)
        #expect(score.notes.first?.lyric?.text == "Twin")
    }

    @Test func corruptArchiveThrows() throws {
        let data = try TestSupport.fixtureData("MusicXML/twinkle.mxl")
        // Truncated: central directory is gone.
        #expect(throws: ImportError.self) { try MusicXMLImporter().importScore(from: data.prefix(data.count - 40)) }
        // ZIP magic but nothing else.
        #expect(throws: ImportError.self) { try MusicXMLImporter().importScore(from: Data([0x50, 0x4B, 0x03, 0x04, 1, 2, 3])) }
        // Corrupt the deflate payload (just after the first local header).
        var bytes = [UInt8](data)
        let nameLen = Int(bytes[26]) | Int(bytes[27]) << 8, extraLen = Int(bytes[28]) | Int(bytes[29]) << 8
        let start = 30 + nameLen + extraLen
        for i in start..<min(bytes.count, start + 64) { bytes[i] = 0xFF }
        #expect(throws: (any Error).self) { try MusicXMLImporter().importScore(from: Data(bytes)) }
    }
}
