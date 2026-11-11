import AVFoundation
import ISingItEngine
import Observation

/// Renders the song in the background and plays it through AVAudioEngine.
///
/// Every edit triggers a re-render, but the renderer's phrase cache means only the
/// phrases that changed are synthesised again, so playback stays responsive.
@MainActor
@Observable
final class PlaybackEngine {
    private(set) var isPlaying = false
    private(set) var isRendering = false
    /// Playhead in song seconds.
    private(set) var position: Double = 0
    private(set) var lastRender: RenderResult?
    private(set) var errorMessage: String?

    @ObservationIgnored private let renderer = Renderer()
    @ObservationIgnored private let engine = AVAudioEngine()
    @ObservationIgnored private let player = AVAudioPlayerNode()
    @ObservationIgnored private var renderTask: Task<Void, Never>?
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var startedAt: Double = 0
    @ObservationIgnored private var playStartPosition: Double = 0

    init() {
        engine.attach(player)
    }

    /// Re-renders after a short pause in editing.
    func scheduleRender(_ project: Project) {
        renderTask?.cancel()
        renderTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(150))
            guard !Task.isCancelled, let self else { return }
            await self.render(project)
        }
    }

    func render(_ project: Project) async {
        isRendering = true
        defer { isRendering = false }
        let result = await renderer.render(project.score, settings: project.settings)
        guard !Task.isCancelled else { return }
        lastRender = result
        if isPlaying {
            // Keep playing from the same spot with the new audio.
            let current = position
            stop()
            play(from: current)
        }
    }

    func togglePlayback(_ project: Project) {
        if isPlaying {
            stop()
        } else if lastRender == nil {
            Task {
                await render(project)
                play(from: position)
            }
        } else {
            play(from: position)
        }
    }

    func play(from songSeconds: Double) {
        guard let result = lastRender, result.audio.duration > 0 else { return }
        let audio = result.audio
        guard let format = AVAudioFormat(standardFormatWithSampleRate: audio.sampleRate, channels: 1) else { return }
        let startSample = max(0, min(audio.samples.count - 1, Int((songSeconds + result.plan.leadIn) * audio.sampleRate)))
        let frameCount = audio.samples.count - startSample
        guard frameCount > 0, let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frameCount)) else { return }
        buffer.frameLength = AVAudioFrameCount(frameCount)
        audio.samples.withUnsafeBufferPointer { source in
            buffer.floatChannelData![0].update(from: source.baseAddress! + startSample, count: frameCount)
        }
        engine.disconnectNodeOutput(player)
        engine.connect(player, to: engine.mainMixerNode, format: format)
        do {
            if !engine.isRunning { try engine.start() }
        } catch {
            errorMessage = "Audio output failed: \(error.localizedDescription)"
            return
        }
        player.stop()
        player.scheduleBuffer(buffer, at: nil, options: []) { [weak self] in
            Task { @MainActor in self?.finished() }
        }
        player.play()
        isPlaying = true
        playStartPosition = songSeconds
        startedAt = CACurrentMediaTime()
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
    }

    func stop() {
        player.stop()
        isPlaying = false
        timer?.invalidate()
        timer = nil
    }

    func seek(to songSeconds: Double) {
        let wasPlaying = isPlaying
        stop()
        position = max(0, songSeconds)
        if wasPlaying { play(from: position) }
    }

    private func tick() {
        guard isPlaying else { return }
        position = playStartPosition + (CACurrentMediaTime() - startedAt)
    }

    private func finished() {
        // scheduleBuffer's handler also fires on stop(); only rewind at the real end.
        guard isPlaying, let result = lastRender,
              position + 0.1 >= result.audio.duration - result.plan.leadIn else { return }
        stop()
        position = 0
    }

    func clearError() { errorMessage = nil }

    /// Renders the song at full level and returns it as a 24-bit WAV file.
    func wavData(_ project: Project) async -> Data {
        var settings = project.settings
        settings.normalize = true
        let result = await renderer.render(project.score, settings: settings)
        return WAVFile.data(result.audio, format: .pcm24)
    }
}
