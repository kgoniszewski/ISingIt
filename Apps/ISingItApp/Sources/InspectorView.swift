import ISingItEngine
import SwiftUI

/// Right-hand panel: song, voice and performance settings, the selected note, and the
/// last render's statistics.
struct InspectorView: View {
    @Binding var document: SongDocument
    var selection: Int?
    var playback: PlaybackEngine
    var warnings: [AlignmentWarning]
    var onEdit: ((inout Score) -> Void) -> Void
    var onEditSettings: ((inout RenderSettings) -> Void) -> Void

    private var score: Score { document.project.score }
    private var settings: RenderSettings { document.project.settings }

    var body: some View {
        Form {
            Section("Song") {
                LabeledContent("Title") {
                    TextField("Title", text: Binding(
                        get: { score.title ?? "" },
                        set: { value in onEdit { $0.title = value } }))
                    .labelsHidden()
                }
                LabeledContent("Tempo") {
                    TextField("BPM", value: Binding(
                        get: { score.tempoMap.events.first?.bpm ?? 120 },
                        set: { bpm in
                            onEdit { s in
                                var events = s.tempoMap.events
                                events[0].bpm = max(20, min(400, bpm))
                                s.tempoMap = TempoMap(events: events)
                            }
                        }), format: .number.precision(.fractionLength(0...1)))
                    .labelsHidden()
                    .frame(width: 70)
                }
                LabeledContent("Notes", value: "\(score.notes.count)")
                LabeledContent("Length", value: String(format: "%.1f s", score.durationSeconds))
            }

            Section("Voice") {
                Picker("Voice", selection: Binding(
                    get: { settings.voice },
                    set: { voice in onEditSettings { $0.voice = voice } })
                ) {
                    ForEach(VoiceProfile.builtIn) { Text($0.name).tag($0) }
                }
                Stepper(value: Binding(
                    get: { settings.performance.transpose },
                    set: { value in onEditSettings { $0.performance.transpose = value } }), in: -24...24
                ) {
                    LabeledContent("Transpose", value: "\(Int(settings.performance.transpose)) st")
                }
                slider("Tempo", value: \.tempoScale, range: 0.5...2, format: "%.2fx")
                slider("Vibrato depth", value: \.vibratoDepthCents, range: 0...80, format: "%.0f cents")
                slider("Vibrato rate", value: \.vibratoRateHz, range: 3...8, format: "%.1f Hz")
                slider("Glide", value: \.portamento, range: 0.01...0.25, format: "%.2f s")
                slider("Breath", value: \.breathiness, range: 0...0.4, format: "%.2f")
                slider("Consonants", value: \.consonantScale, range: 0.5...2, format: "%.2fx")
                Text("Style presets (rocker, rapper, classic, reggae) arrive in phase 2.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            if let id = selection, let note = score.notes.first(where: { $0.id == id }) {
                Section("Selected note") {
                    LabeledContent("Pitch", value: Self.noteName(note.pitch))
                    LabeledContent("Start", value: String(format: "beat %.2f", note.onset + 1))
                    LabeledContent("Length", value: String(format: "%.2f beats", note.duration))
                    LabeledContent("Lyric", value: note.lyric?.text ?? (note.continuesSyllable ? "(held)" : "(none)"))
                    if let phonemes = note.lyric?.phonemes {
                        LabeledContent("Phonemes", value: phonemes.joined(separator: " "))
                    }
                    Slider(value: Binding(
                        get: { Double(note.velocity) },
                        set: { v in onEdit { s in
                            if let i = s.notes.firstIndex(where: { $0.id == id }) { s.notes[i].velocity = Int(v) }
                        } }), in: 1...127) { Text("Velocity") }
                }
            }

            if !warnings.isEmpty {
                Section("Lyrics") {
                    ForEach(Array(warnings.enumerated()), id: \.offset) { _, warning in
                        Label(warning.description, systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.orange)
                    }
                }
            }

            if let result = playback.lastRender {
                Section("Render") {
                    LabeledContent("Phrases", value: "\(result.plan.phrases.count)")
                    LabeledContent("Re-rendered", value: "\(result.phrasesRendered) (cached \(result.cacheHits))")
                    LabeledContent("Speed", value: String(format: "%.0fx real time", 1 / max(result.realTimeFactor, 1e-4)))
                }
            }
        }
        .formStyle(.grouped)
    }

    private func slider(_ title: String, value: WritableKeyPath<PerformanceSettings, Double>, range: ClosedRange<Double>, format: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            LabeledContent(title, value: String(format: format, settings.performance[keyPath: value]))
            Slider(value: Binding(
                get: { settings.performance[keyPath: value] },
                set: { v in onEditSettings { $0.performance[keyPath: value] = v } }), in: range)
        }
    }

    static func noteName(_ pitch: Int) -> String {
        let names = ["C", "C#", "D", "D#", "E", "F", "F#", "G", "G#", "A", "A#", "B"]
        return "\(names[pitch % 12])\(pitch / 12 - 1) (\(pitch))"
    }
}
