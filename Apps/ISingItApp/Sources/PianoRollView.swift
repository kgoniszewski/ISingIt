import ISingItEngine
import SwiftUI

/// Piano roll: notes as bars with their lyrics, a beat grid and the playhead.
///
/// - Click a note to select it; drag it to move (snaps to 1/4 beat and to semitones);
///   drag its right edge to change its length.
/// - Double-click a note to edit its lyric; double-click empty space to add a note.
/// - Click the ruler to move the playhead.
struct PianoRollView: View {
    var score: Score
    var playhead: Double  // song seconds
    @Binding var selection: Int?
    /// Applies an edit. `coalescing` is true for the later steps of a drag, so one drag
    /// is one undo step.
    var onEdit: (_ coalescing: Bool, _ change: (inout Score) -> Void) -> Void
    var onSeek: (Double) -> Void
    var onEditLyric: (Int) -> Void

    @State private var pixelsPerBeat: CGFloat = 64
    @State private var drag: DragState?

    static let rowHeight: CGFloat = 14
    static let rulerHeight: CGFloat = 22
    static let keyboardWidth: CGFloat = 44
    static let pitchRange = 36...96
    static let snap = 0.25

    private struct DragState {
        enum Mode { case move, resize }
        var noteID: Int
        var mode: Mode
        var original: Note
        var startLocation: CGPoint
        var edited = false
    }

    private var lengthInBeats: Double {
        max(16, (score.endBeat / 4).rounded(.up) * 4 + 8)
    }

    var body: some View {
        ScrollView([.horizontal, .vertical]) {
            Canvas { context, size in
                drawGrid(context, size: size)
                drawNotes(context)
                drawPlayhead(context, size: size)
            }
            .frame(
                width: Self.keyboardWidth + CGFloat(lengthInBeats) * pixelsPerBeat,
                height: Self.rulerHeight + CGFloat(Self.pitchRange.count) * Self.rowHeight)
            .contentShape(Rectangle())
            .gesture(SpatialTapGesture(count: 2).onEnded { doubleClick(at: $0.location) })
            .simultaneousGesture(
                DragGesture(minimumDistance: 0)
                    .onChanged(dragChanged)
                    .onEnded { _ in drag = nil })
        }
        .defaultScrollAnchor(UnitPoint(x: 0, y: 0.45))
        .background(Color(nsColor: .textBackgroundColor))
        .toolbar {
            ToolbarItemGroup {
                Button { pixelsPerBeat = max(16, pixelsPerBeat / 1.4) } label: { Image(systemName: "minus.magnifyingglass") }
                    .help("Zoom out")
                Button { pixelsPerBeat = min(400, pixelsPerBeat * 1.4) } label: { Image(systemName: "plus.magnifyingglass") }
                    .help("Zoom in")
            }
        }
    }

    // MARK: - Geometry

    private func x(forBeat beat: Double) -> CGFloat { Self.keyboardWidth + CGFloat(beat) * pixelsPerBeat }
    private func beat(forX x: CGFloat) -> Double { Double((x - Self.keyboardWidth) / pixelsPerBeat) }
    private func y(forPitch pitch: Int) -> CGFloat {
        Self.rulerHeight + CGFloat(Self.pitchRange.upperBound - pitch) * Self.rowHeight
    }
    private func pitch(forY y: CGFloat) -> Int {
        Self.pitchRange.upperBound - Int(((y - Self.rulerHeight) / Self.rowHeight).rounded(.down))
    }
    private func rect(for note: Note) -> CGRect {
        CGRect(x: x(forBeat: note.onset), y: y(forPitch: note.pitch),
               width: max(4, CGFloat(note.duration) * pixelsPerBeat - 1), height: Self.rowHeight - 1)
    }
    private func snapped(_ beat: Double) -> Double { (beat / Self.snap).rounded() * Self.snap }

    // MARK: - Drawing

    private func drawGrid(_ context: GraphicsContext, size: CGSize) {
        for pitch in Self.pitchRange {
            let isBlack = [1, 3, 6, 8, 10].contains(pitch % 12)
            let row = CGRect(x: 0, y: y(forPitch: pitch), width: size.width, height: Self.rowHeight)
            if isBlack { context.fill(Path(row), with: .color(.primary.opacity(0.05))) }
            let key = CGRect(x: 0, y: row.minY, width: Self.keyboardWidth - 2, height: Self.rowHeight - 1)
            context.fill(Path(key), with: .color(isBlack ? .primary.opacity(0.6) : .primary.opacity(0.08)))
            if pitch % 12 == 0 {
                context.draw(Text("C\(pitch / 12 - 1)").font(.system(size: 9)).foregroundStyle(.secondary),
                             at: CGPoint(x: Self.keyboardWidth / 2, y: row.midY))
            }
        }
        let beatsPerBar = score.timeSignatures.first?.beatsPerBar ?? 4
        var beat = 0.0
        while beat <= lengthInBeats {
            let isBar = beat.truncatingRemainder(dividingBy: beatsPerBar) == 0
            var line = Path()
            line.move(to: CGPoint(x: x(forBeat: beat), y: Self.rulerHeight))
            line.addLine(to: CGPoint(x: x(forBeat: beat), y: size.height))
            context.stroke(line, with: .color(.primary.opacity(isBar ? 0.25 : 0.08)), lineWidth: 1)
            if isBar {
                context.draw(Text("\(Int(beat / beatsPerBar) + 1)").font(.system(size: 10)).foregroundStyle(.secondary),
                             at: CGPoint(x: x(forBeat: beat) + 8, y: Self.rulerHeight / 2))
            }
            beat += 1
        }
        var ruler = Path()
        ruler.move(to: CGPoint(x: 0, y: Self.rulerHeight))
        ruler.addLine(to: CGPoint(x: size.width, y: Self.rulerHeight))
        context.stroke(ruler, with: .color(.primary.opacity(0.3)))
    }

    private func drawNotes(_ context: GraphicsContext) {
        for note in score.notes {
            let r = rect(for: note)
            let selected = note.id == selection
            let shape = RoundedRectangle(cornerRadius: 3).path(in: r)
            context.fill(shape, with: .color(selected ? Color.accentColor : Color.accentColor.opacity(0.55)))
            if selected { context.stroke(shape, with: .color(.primary), lineWidth: 1.5) }
            let label: String
            if let lyric = note.lyric {
                label = lyric.kind.continuesWord ? lyric.text + "-" : lyric.text
            } else {
                label = note.continuesSyllable ? "_" : "la"
            }
            var text = context
            text.clip(to: Path(r))
            text.draw(Text(label).font(.system(size: 10, weight: .medium)).foregroundStyle(.white),
                      at: CGPoint(x: r.minX + 3, y: r.midY), anchor: .leading)
        }
    }

    private func drawPlayhead(_ context: GraphicsContext, size: CGSize) {
        let beat = score.tempoMap.beat(atSeconds: max(0, playhead))
        let px = x(forBeat: beat)
        var line = Path()
        line.move(to: CGPoint(x: px, y: 0))
        line.addLine(to: CGPoint(x: px, y: size.height))
        context.stroke(line, with: .color(.red), lineWidth: 1.5)
    }

    // MARK: - Interaction

    private func note(at point: CGPoint) -> Note? {
        score.notes.last { rect(for: $0).insetBy(dx: 0, dy: -1).contains(point) }
    }

    private func dragChanged(_ value: DragGesture.Value) {
        if drag == nil {
            let start = value.startLocation
            if start.y < Self.rulerHeight {
                onSeek(score.tempoMap.seconds(atBeat: max(0, beat(forX: start.x))))
                return
            }
            guard let hit = note(at: start) else {
                selection = nil
                return
            }
            selection = hit.id
            let nearEnd = rect(for: hit).maxX - start.x < 6
            drag = DragState(noteID: hit.id, mode: nearEnd ? .resize : .move, original: hit, startLocation: start)
            return
        }
        guard let drag else { return }
        // A plain click is a selection, not an edit.
        guard abs(value.translation.width) > 2 || abs(value.translation.height) > 2 else { return }
        let coalescing = drag.edited
        self.drag?.edited = true
        let dx = beat(forX: value.location.x) - beat(forX: drag.startLocation.x)
        let dPitch = pitch(forY: value.location.y) - pitch(forY: drag.startLocation.y)
        onEdit(coalescing) { score in
            guard let i = score.notes.firstIndex(where: { $0.id == drag.noteID }) else { return }
            switch drag.mode {
            case .move:
                score.notes[i].onset = max(0, snapped(drag.original.onset + dx))
                score.notes[i].pitch = min(Self.pitchRange.upperBound, max(Self.pitchRange.lowerBound, drag.original.pitch + dPitch))
            case .resize:
                score.notes[i].duration = max(Self.snap, snapped(drag.original.duration + dx))
            }
            score.notes.sort { $0.onset < $1.onset }
        }
    }

    private func doubleClick(at point: CGPoint) {
        if let hit = note(at: point) {
            selection = hit.id
            onEditLyric(hit.id)
            return
        }
        guard point.y > Self.rulerHeight, point.x > Self.keyboardWidth else { return }
        let onset = max(0, (beat(forX: point.x) / Self.snap).rounded(.down) * Self.snap)
        let pitch = pitch(forY: point.y)
        let id = (score.notes.map(\.id).max() ?? 0) + 1
        onEdit(false) { score in
            score.notes.append(Note(id: id, pitch: pitch, onset: onset, duration: 1, lyric: Syllable(text: "la")))
            score.notes.sort { $0.onset < $1.onset }
        }
        selection = id
    }
}
