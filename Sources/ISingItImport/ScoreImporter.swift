import Foundation
import ISingItScore

/// Picks the right importer from a file's extension or contents.
public enum ScoreImporter {
    public enum Kind: Sendable { case musicXML, midi, project }

    public static func kind(of url: URL, data: Data) -> Kind? {
        switch url.pathExtension.lowercased() {
        case "mid", "midi", "smf", "rmi": return .midi
        case "musicxml", "xml", "mxl": return .musicXML
        case "isingit", "json": return .project
        default:
            if data.starts(with: [0x4D, 0x54, 0x68, 0x64]) { return .midi }
            if ZipArchive.isZip(data) { return .musicXML }
            if let head = String(data: data.prefix(512), encoding: .utf8), head.contains("<score-partwise") {
                return .musicXML
            }
            return nil
        }
    }

    /// Imports a MusicXML, MIDI or iSingIt project (Score JSON) file.
    /// - Parameter part: MusicXML part id or MIDI track index; nil picks automatically.
    public static func importFile(at url: URL, part: String? = nil) throws -> Score {
        let data = try Data(contentsOf: url)
        return try importData(data, fileName: url.lastPathComponent, url: url, part: part)
    }

    public static func importData(_ data: Data, fileName: String, url: URL? = nil, part: String? = nil) throws -> Score {
        let probeURL = url ?? URL(fileURLWithPath: fileName)
        switch kind(of: probeURL, data: data) {
        case .midi:
            let track: Int?
            if let part {
                guard let index = Int(part) else { throw ImportError.partNotFound(part) }
                track = index
            } else {
                track = nil
            }
            return try MIDIImporter().importScore(from: data, fileName: fileName, track: track)
        case .musicXML:
            return try MusicXMLImporter().importScore(from: data, fileName: fileName, partID: part)
        case .project:
            return try Score.fromJSON(data)
        case nil:
            throw ImportError.unsupportedFile(fileName)
        }
    }
}
