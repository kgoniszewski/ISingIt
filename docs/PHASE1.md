# Phase 0 and phase 1 report

Plan phases covered: **phase 0 (foundations)** and **phase 1 (first singing voice)**.
Phase 2 (style presets) has not started; it waits for review of this work.

## Gate checks

| Gate | Status |
|---|---|
| Phase 0: every fixture parses and round-trips through the IR JSON | Met. 9 fixture files (MusicXML, MXL, MIDI) import; JSON round trip is unit-tested |
| Phase 1: a user imports a song, edits it and hears clear singing in the app | Engine side met (CLI renders intelligible singing). App written but **not yet compiled or run**: it needs Xcode with the macOS 27 SDK |

## What was built and how it was checked

All engine work was built and tested on Linux with Swift 6.2: `swift test` runs 56 tests
in 10 suites (importers, ZIP/DEFLATE, G2P, alignment, planner, synth, WAV, render cache,
golden renders). GitHub Actions runs the same on Linux and macOS, and tries an app build
on macOS that is allowed to fail until a macOS 27 SDK runner exists.

## Benchmarks (Linux x86-64, 4 cores)

Speed (`isingit bench`, release build):

| Song | Audio | Render (best) | Real-time factor | Re-render with cache |
|---|---|---|---|---|
| amazing_grace.musicxml | 18.6 s | 0.034 s | 0.0019 (about 540x real time) | 1.2 ms |
| twinkle.musicxml | 10.0 s | 0.017 s | 0.0017 | 0.6 ms |

Intelligibility (`bench/intelligibility.py`, faster-whisper small.en transcribing the
renders; word error rate, lower is better), 5 songs x 4 voices:

| Voice | Mean WER |
|---|---|
| DSP Soprano | 0.17 |
| DSP Alto | 0.37 |
| DSP Tenor | 0.28 |
| DSP Bass | 0.41 |
| All | 0.31 (median 0.2) |

Tuning the consonant model (stop loci and bursts, consonants sung before the first beat)
took the soprano/tenor mean from 0.68 to 0.22. The remaining errors are mostly weak
initial consonants ("grace" heard as "race", "had" as "and") and, on long slow songs,
the recogniser inventing words. Full results: `bench/results/`.

## Not done in phase 1 (by plan or deferred)

- Style presets, FX chains, expression curves, phoneme lane, score view: phase 2.
- Neural voice: phase 3. The DSP voice is a formant synthesizer instead of WORLD +
  phoneme bank (ADR 0002).
- Polish: phase 4. `Language.polish` exists; G2P falls back to English for now.
- AIFF/FLAC export, Metal-drawn piano roll, `.isingit` package format.
- Listening test (mean opinion score) with real listeners.

## Open questions for review

1. Accept the formant voice as the phase 1 DSP voice (ADR 0002)?
2. Engine minimum macOS 15 so hosted CI can test it, app deployment target macOS 27
   (ADR 0001)?
3. Who records the original singer needed for the WORLD voice and neural training data?
