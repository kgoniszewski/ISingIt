# Architecture

The source of truth is the architecture plan document: https://claude.ai/artifact/37d7NQymKT4wwKSAefSAfT
This file summarises how the code maps onto it.

## Pipeline

```
MusicXML / MXL ─┐
                ├─► Score IR ─► Lyrics.Align ─► Lyrics.G2P ─► Performance.Planner ─► Synth (voice) ─► Render ─► Audio
MIDI + lyrics ──┘   (ISingItScore)   (ISingItLyrics)            (ISingItPerformance)   (ISingItSynth)  (ISingItRender)
```

| Plan module | Swift module | Phase 1 state |
|---|---|---|
| Import.MusicXML | `ISingItImport.MusicXMLImporter` | Done: parts, voices, chords, ties, slurs, lyrics, tempo, time, key, dynamics, `.mxl` |
| Import.MIDI | `ISingItImport.MIDIImporter` | Done: format 0/1, lyric meta events, melody track suggestion |
| Score | `ISingItScore.Score` | Done (JSON format version 1) |
| Lyrics.Align | `ISingItLyrics.LyricsAligner` | Done: `-` and `_` conventions, warnings |
| Lyrics.G2P | `ISingItLyrics.EnglishG2P`, `Phonemizer` | English done (CMUdict + rules). Core ML model for unknown words and Polish later |
| Performance.Planner | `ISingItPerformance.PerformancePlanner` | Done |
| Performance.Style | – | Phase 2 (presets). `PerformanceSettings` holds the knobs presets will set |
| Synth.DSP | `ISingItSynth.FormantVoice` | Done as a formant voice, see ADR 0002 |
| Synth.Neural | – | Phase 3, same `VoiceSynthesizer` protocol |
| Audio.FX | – | Phase 2 |
| Render | `ISingItRender.Renderer` | Done: parallel phrase rendering, content-hash cache |
| Audio.Export | `ISingItAudio.WAVFile` | WAV done; AIFF/FLAC through AVAudioFile in the app later |

The interface between performance and voice is `PhrasePlan`: timed phonemes plus
frame-level (200 Hz) f0, loudness and breathiness. That is exactly what a DiffSinger-style
neural model consumes, so the neural voice can replace the DSP one without changes
upstream.

## Decisions

See [docs/adr](adr/).
