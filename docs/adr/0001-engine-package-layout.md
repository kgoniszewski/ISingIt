# ADR 0001: One Swift package, one module per pipeline stage, buildable on Linux

Status: accepted by the director on 2026-11-11 (docs/reviews/phase1-director-review.md)

## Context
The plan calls for one Swift engine package shared by the app, the AUv3 plugin and the
CLI, with each stage a module with a typed input and output.

## Decision
- `Package.swift` at the repo root, one target per stage (`ISingItScore`, `ISingItImport`,
  `ISingItLyrics`, `ISingItPerformance`, `ISingItSynth`, `ISingItAudio`, `ISingItRender`)
  plus the umbrella `ISingItEngine` and the `isingit` executable.
- Engine modules use only Swift and Foundation (no AVFoundation, Accelerate or Core ML
  yet), so the whole engine builds and tests on Linux CI as well as macOS. Apple-only
  code lives in the app (`Apps/ISingItApp`) and, later, in clearly separated modules.
- The engine's minimum platform is macOS 15 so it can be tested on today's hosted CI
  runners; the app's deployment target is macOS 27 as decided.
- No third-party Swift dependencies. ZIP/DEFLATE for `.mxl` and the MIDI and WAV codecs
  are small pure-Swift implementations.
- The app is generated with XcodeGen (`Apps/ISingItApp/project.yml`) so no `.xcodeproj`
  is checked in.

## Consequences
When Accelerate (vDSP) or Core ML are added, they go behind `#if canImport(...)` or in a
macOS-only module, so the Linux test job keeps covering the rest.
