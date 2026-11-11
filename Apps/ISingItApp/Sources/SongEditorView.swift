import ISingItEngine
import SwiftUI
import UniformTypeIdentifiers

/// The main window: piano roll in the middle, transport in the toolbar, settings in the
/// inspector.
struct SongEditorView: View {
    @Binding var document: SongDocument
    @Environment(\.undoManager) private var undoManager
    @State private var playback = PlaybackEngine()
    @State private var selection: Int?
    @State private var lyricEditing: LyricEdit?
    @State private var showingLyricsSheet = false
    @State private var pastedLyrics = ""
    @State private var alignmentWarnings: [AlignmentWarning] = []
    @State private var exporting = false
    @State private var exportDocument = WAVExportDocument()
    @FocusState private var rollFocused: Bool
    @State private var showInspector = true

    struct LyricEdit: Identifiable {
        var id: Int
        var text: String
    }

    private var project: Project { document.project }

    var body: some View {
        PianoRollView(
            score: project.score,
            playhead: playback.position,
            selection: $selection,
            onEdit: { coalescing, change in edit(coalescing: coalescing, change) },
            onSeek: { playback.seek(to: $0) },
            onEditLyric: { id in
                let lyric = project.score.notes.first { $0.id == id }?.lyric
                lyricEditing = LyricEdit(id: id, text: lyric.map { $0.kind.continuesWord ? $0.text + "-" : $0.text } ?? "")
            })
        // Space and Delete are handled here, not as menu shortcuts, so they still type
        // normally in text fields.
        .focusable()
        .focusEffectDisabled()
        .focused($rollFocused)
        .onKeyPress(.space) {
            playback.togglePlayback(project)
            return .handled
        }
        .onKeyPress(keys: [.delete, .deleteForward]) { _ in
            deleteSelection()
            return .handled
        }
        .inspector(isPresented: $showInspector) {
            InspectorView(
                document: $document, selection: selection, playback: playback,
                warnings: alignmentWarnings,
                onEdit: { change in edit(coalescing: false, change) },
                onEditSettings: { change in editSettings(change) })
            .inspectorColumnWidth(min: 240, ideal: 280, max: 360)
        }
        .toolbar {
            ToolbarItemGroup(placement: .navigation) {
                Button {
                    playback.togglePlayback(project)
                } label: {
                    Label(playback.isPlaying ? "Stop" : "Play", systemImage: playback.isPlaying ? "stop.fill" : "play.fill")
                }
                .help("Play or stop (Space)")
                Button {
                    playback.seek(to: 0)
                } label: {
                    Label("Rewind", systemImage: "backward.end.fill")
                }
                if playback.isRendering { ProgressView().controlSize(.small) }
            }
            ToolbarItemGroup {
                Button { showingLyricsSheet = true } label: { Label("Lyrics", systemImage: "text.quote") }
                    .help("Paste lyrics onto the notes")
                Button {
                    // Render first, so the save panel writes the finished file itself.
                    let current = project
                    Task {
                        exportDocument = WAVExportDocument(data: await playback.wavData(current))
                        exporting = true
                    }
                } label: { Label("Export", systemImage: "square.and.arrow.up") }
                    .help("Export the vocal as a WAV file")
                Button { showInspector.toggle() } label: { Label("Inspector", systemImage: "sidebar.right") }
            }
        }
        .sheet(item: $lyricEditing) { item in
            LyricFieldSheet(text: item.text) { newText in
                setLyric(newText, on: item.id)
                lyricEditing = nil
            } onCancel: {
                lyricEditing = nil
            }
        }
        .sheet(isPresented: $showingLyricsSheet) {
            LyricsSheet(text: $pastedLyrics) {
                var warnings: [AlignmentWarning] = []
                let text = pastedLyrics
                edit(coalescing: false) { score in warnings = LyricsAligner().align(text, to: &score) }
                alignmentWarnings = warnings
                showingLyricsSheet = false
            } onCancel: {
                showingLyricsSheet = false
            }
        }
        .fileExporter(
            isPresented: $exporting, document: exportDocument, contentType: .wav,
            defaultFilename: (project.score.title ?? "vocal") + ".wav"
        ) { _ in }
        .onAppear {
            rollFocused = true
            playback.scheduleRender(project)
        }
        .onChange(of: project) { _, newValue in playback.scheduleRender(newValue) }
        .onReceive(NotificationCenter.default.publisher(for: .togglePlayback)) { _ in playback.togglePlayback(project) }
        .onReceive(NotificationCenter.default.publisher(for: .deleteSelectedNote)) { _ in deleteSelection() }
        .alert("Playback problem", isPresented: Binding(
            get: { playback.errorMessage != nil },
            set: { if !$0 { playback.clearError() } })
        ) {
            Button("OK") { playback.clearError() }
        } message: {
            Text(playback.errorMessage ?? "")
        }
    }

    // MARK: - Editing with undo

    private func edit(coalescing: Bool, _ change: (inout Score) -> Void) {
        let before = document.project.score
        change(&document.project.score)
        guard !coalescing, before != document.project.score else { return }
        registerUndo(before, name: "Edit Notes")
    }

    private func registerUndo(_ score: Score, name: String) {
        Self.registerUndo(restoring: score, in: $document, manager: undoManager, name: name)
    }

    /// Registers an undo that restores `score`; undoing registers the redo the same way.
    static func registerUndo(restoring score: Score, in document: Binding<SongDocument>, manager: UndoManager?, name: String) {
        guard let manager else { return }
        manager.registerUndo(withTarget: UndoTarget.shared) { _ in
            MainActor.assumeIsolated {
                let current = document.wrappedValue.project.score
                document.wrappedValue.project.score = score
                registerUndo(restoring: current, in: document, manager: manager, name: name)
            }
        }
        manager.setActionName(name)
    }

    private func editSettings(_ change: (inout RenderSettings) -> Void) {
        change(&document.project.settings)
    }

    private func setLyric(_ text: String, on id: Int) {
        edit(coalescing: false) { score in
            guard let i = score.notes.firstIndex(where: { $0.id == id }) else { return }
            var trimmed = text.trimmingCharacters(in: .whitespaces)
            if trimmed == "_" {
                score.notes[i].lyric = nil
                score.notes[i].continuesSyllable = true
                return
            }
            let continues = trimmed.hasSuffix("-")
            if continues { trimmed.removeLast() }
            let previousContinues = score.notes[..<i].last(where: { $0.lyric != nil })?.lyric?.kind.continuesWord ?? false
            let kind: Syllable.Kind = switch (previousContinues, continues) {
            case (false, false): .single
            case (false, true): .begin
            case (true, true): .middle
            case (true, false): .end
            }
            score.notes[i].continuesSyllable = false
            score.notes[i].lyric = trimmed.isEmpty ? nil : Syllable(text: trimmed, kind: kind)
            // Clear phonemes for the whole word so G2P runs again.
            for j in score.notes.indices where abs(j - i) <= 4 { score.notes[j].lyric?.phonemes = nil }
        }
    }

    private func deleteSelection() {
        guard let id = selection else { return }
        edit(coalescing: false) { $0.notes.removeAll { $0.id == id } }
        selection = nil
    }
}

/// Undo needs a class target; the closure does the real work.
@MainActor final class UndoTarget {
    static let shared = UndoTarget()
}

/// A rendered WAV file handed to the save panel.
struct WAVExportDocument: FileDocument {
    static let readableContentTypes: [UTType] = [.wav]
    var data = Data()

    init(data: Data = Data()) { self.data = data }

    init(configuration: ReadConfiguration) throws {
        data = configuration.file.regularFileContents ?? Data()
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}

struct LyricFieldSheet: View {
    @State var text: String
    var onCommit: (String) -> Void
    var onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Lyric").font(.headline)
            TextField("Syllable", text: $text)
                .textFieldStyle(.roundedBorder)
                .onSubmit { onCommit(text) }
            Text("End with \"-\" when the word continues on the next note; type \"_\" to hold the previous syllable.")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel, action: onCancel)
                Button("OK") { onCommit(text) }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 340)
    }
}

struct LyricsSheet: View {
    @Binding var text: String
    var onApply: () -> Void
    var onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Paste lyrics").font(.headline)
            Text("One syllable is placed on each note. Use \"-\" to split words yourself (\"Twin-kle\") and \"_\" to hold a syllable over an extra note.")
                .font(.caption).foregroundStyle(.secondary)
            TextEditor(text: $text)
                .font(.body)
                .frame(minHeight: 160)
                .border(Color.secondary.opacity(0.3))
            HStack {
                Spacer()
                Button("Cancel", role: .cancel, action: onCancel)
                Button("Place on Notes", action: onApply).keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 480)
    }
}
