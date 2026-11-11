import ISingItEngine
import SwiftUI
import UniformTypeIdentifiers

@main
struct ISingItApp: App {
    var body: some Scene {
        DocumentGroup(newDocument: SongDocument()) { file in
            SongEditorView(document: file.$document)
                .frame(minWidth: 900, minHeight: 560)
        }
        .commands {
            CommandMenu("Playback") {
                // Space also plays and stops while the piano roll has focus.
                Button("Play / Stop") {
                    NotificationCenter.default.post(name: .togglePlayback, object: nil)
                }
                .keyboardShortcut(.return, modifiers: .command)
                Button("Delete Selected Note") {
                    NotificationCenter.default.post(name: .deleteSelectedNote, object: nil)
                }
                .keyboardShortcut(.delete, modifiers: .command)
            }
        }
    }
}

extension Notification.Name {
    static let togglePlayback = Notification.Name("ISingIt.togglePlayback")
    static let deleteSelectedNote = Notification.Name("ISingIt.deleteSelectedNote")
}

extension UTType {
    static let isingitProject = UTType(exportedAs: "app.isingit.project", conformingTo: .json)
    static let musicXML = UTType(importedAs: "org.musicxml.musicxml", conformingTo: .xml)
    static let musicXMLUncompressed = UTType(importedAs: "com.recordare.musicxml.uncompressed", conformingTo: .xml)
    static let compressedMusicXML = UTType(importedAs: "com.recordare.musicxml", conformingTo: .zip)
}
