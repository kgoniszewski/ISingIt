// swift-tools-version: 6.0
//
// iSingIt engine package.
//
// The engine is split into one module per pipeline stage (see docs/ARCHITECTURE.md).
// Every module is plain Swift + Foundation so the whole engine builds and tests on
// macOS and on Linux; Apple-only frameworks (AVFoundation, Core ML, SwiftUI) live
// only in the app target under Apps/.

import PackageDescription

let package = Package(
    name: "ISingIt",
    platforms: [
        // The shipping app targets macOS 27 (see Apps/ISingItApp/project.yml). The engine
        // itself uses nothing newer than macOS 15, so CI runners with an older SDK can test it.
        .macOS(.v15)
    ],
    products: [
        .library(name: "ISingItEngine", targets: ["ISingItEngine"]),
        .executable(name: "isingit", targets: ["isingit"]),
    ],
    targets: [
        // Shared score format: the single source of truth every stage reads.
        .target(name: "ISingItScore"),

        // Import.MusicXML / Import.MIDI (+ a minimal ZIP reader for .mxl).
        .target(name: "ISingItImport", dependencies: ["ISingItScore"]),

        // Lyrics.Align and Lyrics.G2P (English: CMUdict + letter-to-sound rules).
        .target(
            name: "ISingItLyrics",
            dependencies: ["ISingItScore"],
            resources: [.copy("Resources/cmudict.dict"), .copy("Resources/cmudict-LICENSE.txt")]
        ),

        // Performance.Planner: beats to seconds, phoneme timing, pitch and loudness curves.
        .target(name: "ISingItPerformance", dependencies: ["ISingItScore", "ISingItLyrics"]),

        // Synth.DSP: phase 1 formant voice.
        .target(name: "ISingItSynth", dependencies: ["ISingItPerformance"]),

        // Audio buffers and WAV export.
        .target(name: "ISingItAudio"),

        // Render: phrase scheduler and content-hash cache.
        .target(
            name: "ISingItRender",
            dependencies: ["ISingItScore", "ISingItLyrics", "ISingItPerformance", "ISingItSynth", "ISingItAudio"]
        ),

        // Umbrella module the app, the plugin and the CLI import.
        .target(
            name: "ISingItEngine",
            dependencies: [
                "ISingItScore", "ISingItImport", "ISingItLyrics", "ISingItPerformance",
                "ISingItSynth", "ISingItAudio", "ISingItRender",
            ]
        ),

        .executableTarget(name: "isingit", dependencies: ["ISingItEngine"]),

        .testTarget(
            name: "ISingItEngineTests",
            dependencies: ["ISingItEngine"]
        ),
    ]
)
