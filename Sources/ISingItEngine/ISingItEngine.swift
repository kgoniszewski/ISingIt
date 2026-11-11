// Umbrella module: `import ISingItEngine` gives the app, the Audio Unit and the CLI the
// whole engine.
@_exported import ISingItAudio
@_exported import ISingItImport
@_exported import ISingItLyrics
@_exported import ISingItPerformance
@_exported import ISingItRender
@_exported import ISingItScore
@_exported import ISingItSynth

public enum ISingIt {
    /// Engine version; part of the render cache key so a new engine never reuses old audio.
    public static let engineVersion = Renderer.engineVersion
}
