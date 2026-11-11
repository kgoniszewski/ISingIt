import ISingItEngine
import SwiftUI
import UniformTypeIdentifiers

/// The app's document: an iSingIt project. Opening MusicXML or MIDI imports it into a new
/// project; saving always writes `.isingit`.
struct SongDocument: FileDocument {
    static let readableContentTypes: [UTType] = [
        .isingitProject, .musicXML, .musicXMLUncompressed, .compressedMusicXML, .midi,
    ]
    static let writableContentTypes: [UTType] = [.isingitProject]

    var project: Project

    init() {
        project = Project(score: Score(title: "Untitled", tempoMap: TempoMap(bpm: 100)))
    }

    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents else {
            throw CocoaError(.fileReadCorruptFile)
        }
        let name = configuration.file.filename ?? "song"
        do {
            project = try Project.open(data, fileName: name)
        } catch {
            throw CocoaError(.fileReadCorruptFile, userInfo: [NSLocalizedDescriptionKey: "\(error)"])
        }
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: try project.jsonData())
    }
}
