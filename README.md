# iSingIt

iSingIt is a vocal synthesis studio for macOS. Give it a melody (MusicXML sheet music or a
MIDI file) and lyrics, and it sings them. It is free software under the GNU GPL v3.

> Status: **phase 1 (first singing voice)** of the [architecture plan](docs/ARCHITECTURE.md).
> The engine sings English with a simple DSP voice. Style presets (rocker, rapper,
> classic, reggae) come in phase 2 and neural voices in phase 3.

## What works today

- Import MusicXML (`.musicxml`, `.xml`, compressed `.mxl`) and MIDI (`.mid`) with lyrics,
  or paste lyrics onto the notes.
- English pronunciation from the CMU Pronouncing Dictionary (134k words) with
  letter-to-sound rules for unknown words.
- A performance planner that times consonants before the beat, adds legato glides,
  delayed vibrato and phrase breathing.
- A formant (source-filter) DSP voice in four ranges: soprano, alto, tenor, bass.
- Phrase-by-phrase rendering with a content-hash cache, so an edit only re-renders the
  phrases it touched. Renders far faster than real time.
- `isingit` command-line tool, and a SwiftUI Mac app with a piano roll, lyric editing,
  playback and WAV export (see "Mac app" below for its build status).

## Command line

```sh
swift build -c release
.build/release/isingit render Fixtures/MusicXML/amazing_grace.musicxml --voice tenor -o grace.wav
.build/release/isingit render Fixtures/MIDI/twinkle_nolyrics.mid --lyrics Fixtures/Lyrics/twinkle.txt
.build/release/isingit inspect Fixtures/MIDI/multitrack.mid
.build/release/isingit phonemes twinkle little star
.build/release/isingit render song.mid --set vibratoDepthCents=45 --transpose -3
.build/release/isingit bench Fixtures/MusicXML/amazing_grace.musicxml
```

Run `isingit --help` for every option.

## Mac app

The app lives in `Apps/ISingItApp` and is generated with [XcodeGen](https://github.com/yonaskolb/XcodeGen):

```sh
brew install xcodegen
xcodegen generate --spec Apps/ISingItApp/project.yml
open Apps/ISingItApp/ISingItApp.xcodeproj
```

It targets macOS 27 on Apple Silicon and needs Xcode with the macOS 27 SDK.

## Layout

| Path | What |
|---|---|
| `Sources/ISingItScore` | Score IR: notes, syllables, tempo map, dynamics (Codable JSON) |
| `Sources/ISingItImport` | MusicXML, MXL (ZIP) and MIDI importers |
| `Sources/ISingItLyrics` | Lyric alignment, English G2P, syllabification |
| `Sources/ISingItPerformance` | Performance planner: phoneme timing, pitch, loudness |
| `Sources/ISingItSynth` | Voices: the phase 1 formant DSP voice |
| `Sources/ISingItAudio` | Audio buffers and WAV read/write |
| `Sources/ISingItRender` | Phrase renderer and cache |
| `Sources/ISingItEngine` | Umbrella module and project file |
| `Sources/isingit` | Command-line tool |
| `Apps/ISingItApp` | SwiftUI Mac app |
| `Fixtures` | Test songs (public domain melodies) |
| `bench` | Benchmarks, including the intelligibility test |
| `docs` | Architecture, decision records, phase reports |

## Development

The engine is plain Swift + Foundation, so it builds and tests on macOS and Linux:

```sh
swift build
swift test
```

The intelligibility benchmark renders the fixture songs and transcribes them with a
speech recogniser (word error rate, lower is better):

```sh
pip install faster-whisper numpy
python3 bench/intelligibility.py -v
```

## Licences

iSingIt is GPL-3.0. The bundled CMU Pronouncing Dictionary is BSD-licensed; its licence
is in `Sources/ISingItLyrics/Resources/cmudict-LICENSE.txt`.
