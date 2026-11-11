import Foundation
import ISingItEngine

// isingit: command-line front end of the engine, for batch renders, tests and benchmarks.

let usage = """
isingit \(ISingIt.engineVersion) - sing MusicXML and MIDI files

USAGE
  isingit render <file> [-o out.wav] [options]   Render a song to WAV
  isingit ir <file> [options]                    Print the Score IR as JSON
  isingit inspect <file>                         List parts/tracks and lyrics status
  isingit plan <file> [options]                  Print the timed phonemes per phrase
  isingit phonemes <text...>                     Show G2P output for words
  isingit bench <file> [--runs N] [options]      Measure render speed (real-time factor)
  isingit voices                                 List voices

OPTIONS
  --part <id>           MusicXML part id or MIDI track index (default: automatic)
  --lyrics <file>       Lyrics text file to place on the notes (replaces file lyrics)
  --lyrics-text <text>  Lyrics given inline
  --voice <id>          Voice (default dsp-soprano; see `isingit voices`)
  --transpose <n>       Transpose in semitones
  --tempo-scale <x>     Tempo multiplier
  --sample-rate <hz>    Output sample rate (default 44100)
  --format <f>          pcm16 | pcm24 | float32 (default pcm16)
  --set <key=value>     Override a performance setting, e.g. --set vibratoDepthCents=40
                        (repeatable; keys: \(PerformanceSettings.keys.joined(separator: ", ")))
  --no-normalize        Keep the engine's level instead of normalizing to -1 dBFS
"""

struct CLIError: Error, CustomStringConvertible {
    var description: String
}

struct Options {
    var command = ""
    var positional: [String] = []
    var output: String?
    var part: String?
    var lyricsFile: String?
    var lyricsText: String?
    var voice = VoiceProfile.dspSoprano
    var transpose = 0.0
    var tempoScale = 1.0
    var sampleRate = 44_100.0
    var format = WAVFormat.pcm16
    var normalize = true
    var runs = 3
    var overrides: [String: Double] = [:]

    init(_ args: [String]) throws {
        var it = args.makeIterator()
        guard let command = it.next() else { throw CLIError(description: usage) }
        self.command = command
        func value(_ flag: String) throws -> String {
            guard let v = it.next() else { throw CLIError(description: "\(flag) needs a value") }
            return v
        }
        func number(_ flag: String) throws -> Double {
            let v = try value(flag)
            guard let d = Double(v) else { throw CLIError(description: "\(flag): '\(v)' is not a number") }
            return d
        }
        while let arg = it.next() {
            switch arg {
            case "-o", "--output": output = try value(arg)
            case "--part", "--track": part = try value(arg)
            case "--lyrics": lyricsFile = try value(arg)
            case "--lyrics-text": lyricsText = try value(arg)
            case "--voice":
                let id = try value(arg)
                guard let v = VoiceProfile.named(id) else {
                    throw CLIError(description: "Unknown voice '\(id)'. Voices: \(VoiceProfile.builtIn.map(\.id).joined(separator: ", "))")
                }
                voice = v
            case "--transpose": transpose = try number(arg)
            case "--tempo-scale": tempoScale = try number(arg)
            case "--sample-rate": sampleRate = try number(arg)
            case "--runs": runs = Int(try number(arg))
            case "--no-normalize": normalize = false
            case "--set":
                let pair = try value(arg).split(separator: "=", maxSplits: 1).map(String.init)
                guard pair.count == 2, let number = Double(pair[1]) else {
                    throw CLIError(description: "--set expects key=number")
                }
                guard PerformanceSettings.keys.contains(pair[0]) else {
                    throw CLIError(description: "Unknown setting '\(pair[0])'. Settings: \(PerformanceSettings.keys.joined(separator: ", "))")
                }
                overrides[pair[0]] = number
            case "--format":
                switch try value(arg) {
                case "pcm16": format = .pcm16
                case "pcm24": format = .pcm24
                case "float32": format = .float32
                case let f: throw CLIError(description: "Unknown format '\(f)'")
                }
            case "-h", "--help": throw CLIError(description: usage)
            default:
                if arg.hasPrefix("-") && arg.count > 1 && Double(arg) == nil { throw CLIError(description: "Unknown option \(arg)") }
                positional.append(arg)
            }
        }
    }

    var renderSettings: RenderSettings {
        var s = RenderSettings()
        s.voice = voice
        s.sampleRate = sampleRate
        s.normalize = normalize
        s.performance.transpose = transpose
        s.performance.tempoScale = tempoScale
        s.performance = (try? s.performance.applying(overrides)) ?? s.performance
        return s
    }

    func inputURL() throws -> URL {
        guard let path = positional.first else { throw CLIError(description: "Missing input file.\n\n\(usage)") }
        return URL(fileURLWithPath: path)
    }

    /// Imports the input and applies pasted lyrics, printing alignment warnings.
    func loadScore() throws -> Score {
        var score = try ScoreImporter.importFile(at: try inputURL(), part: part)
        var text = lyricsText
        if let lyricsFile { text = try String(contentsOfFile: lyricsFile, encoding: .utf8) }
        if let text {
            for warning in LyricsAligner().align(text, to: &score) {
                FileHandle.standardError.write("warning: \(warning)\n".data(using: .utf8)!)
            }
        }
        return score
    }
}

func printJSON<T: Encodable>(_ value: T) throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    print(String(decoding: try encoder.encode(value), as: UTF8.self))
}

func format(_ seconds: Double) -> String { String(format: "%.2f s", seconds) }

func run() async throws {
    let options = try Options(Array(CommandLine.arguments.dropFirst()))
    switch options.command {
    case "render":
        let input = try options.inputURL()
        let score = try options.loadScore()
        let result = await Renderer().render(score, settings: options.renderSettings)
        let output = options.output.map { URL(fileURLWithPath: $0) }
            ?? input.deletingPathExtension().appendingPathExtension("wav")
        try WAVFile.write(result.audio, to: output, format: options.format)
        print("Rendered \(score.notes.count) notes in \(result.plan.phrases.count) phrases with \(options.voice.name): "
            + "\(format(result.audio.duration)) of audio in \(format(result.renderSeconds)) "
            + "(real-time factor \(String(format: "%.3f", result.realTimeFactor))) -> \(output.path)")

    case "ir":
        var score = try options.loadScore()
        Phonemizer(language: score.language).apply(to: &score)
        try printJSON(score)

    case "inspect":
        let input = try options.inputURL()
        let data = try Data(contentsOf: input)
        switch ScoreImporter.kind(of: input, data: data) {
        case .midi:
            let importer = MIDIImporter()
            let suggested = try importer.suggestedMelodyTrack(in: data)
            for t in try importer.tracks(in: data) {
                let mark = t.index == suggested ? " <- melody" : ""
                print("track \(t.index): \(t.name ?? "(unnamed)"), \(t.noteCount) notes, \(t.lyricCount) lyrics, "
                    + "mean pitch \(String(format: "%.1f", t.meanPitch)), polyphony \(String(format: "%.2f", t.polyphony))"
                    + (t.isDrums ? ", drums" : "") + mark)
            }
        case .musicXML:
            for p in try MusicXMLImporter().parts(in: data) {
                print("part \(p.id): \(p.name), \(p.noteCount) notes, \(p.lyricCount) with lyrics")
            }
        default:
            break
        }
        let score = try options.loadScore()
        let tempo = score.tempoMap.events.map { "\(Int($0.bpm.rounded())) bpm at beat \($0.beat)" }.joined(separator: ", ")
        print("vocal line: \(score.notes.count) notes, \(score.notes.filter { $0.lyric != nil }.count) syllables, "
            + "\(format(score.durationSeconds)); tempo \(tempo)")
        let lyrics = score.notes.compactMap { n -> String? in
            guard let l = n.lyric else { return n.continuesSyllable ? "_" : nil }
            return l.kind.continuesWord ? l.text + "-" : l.text
        }
        if !lyrics.isEmpty { print("lyrics: " + lyrics.joined(separator: " ")) }

    case "plan":
        let score = try options.loadScore()
        let plan = Renderer().plan(score, settings: options.renderSettings)
        for (i, phrase) in plan.phrases.enumerated() {
            print("phrase \(i + 1): \(format(phrase.startTime)) - \(format(phrase.endTime)), notes \(phrase.noteRange)")
            let line = phrase.segments.map {
                "\($0.phoneme)[\(Int((($0.start + phrase.startTime) * 1000).rounded()))-\(Int((($0.end + phrase.startTime) * 1000).rounded()))]"
            }
            print("  " + line.joined(separator: " "))
        }

    case "phonemes":
        let g2p = EnglishG2P.shared
        for word in options.positional {
            let phonemes = g2p.phonemes(for: word)
            let syllables = Syllabifier.syllabify(phonemes).map { $0.joined(separator: " ") }
            let source = g2p.knows(word) ? "dictionary" : "rules"
            print("\(word): \(syllables.joined(separator: " | ")) (\(source))")
        }

    case "bench":
        let score = try options.loadScore()
        var settings = options.renderSettings
        settings.normalize = false
        var times: [Double] = []
        var duration = 0.0
        for _ in 0..<max(1, options.runs) {
            let result = await Renderer().render(score, settings: settings)  // fresh cache each run
            times.append(result.renderSeconds)
            duration = result.audio.duration
        }
        let cached = Renderer()
        _ = await cached.render(score, settings: settings)
        let warm = await cached.render(score, settings: settings)
        let best = times.min() ?? 0
        let mean = times.reduce(0, +) / Double(times.count)
        try printJSON([
            "audio_seconds": duration,
            "runs": Double(times.count),
            "render_seconds_best": best,
            "render_seconds_mean": mean,
            "real_time_factor_best": duration > 0 ? best / duration : 0,
            "cached_rerender_seconds": warm.renderSeconds,
            "notes": Double(score.notes.count),
        ])

    case "voices":
        for v in VoiceProfile.builtIn {
            print("\(v.id): \(v.name), range MIDI \(v.range.lowerBound)-\(v.range.upperBound)")
        }

    case "-h", "--help", "help":
        print(usage)

    default:
        throw CLIError(description: "Unknown command '\(options.command)'.\n\n\(usage)")
    }
}

do {
    try await run()
} catch {
    FileHandle.standardError.write("isingit: \(error)\n".data(using: .utf8)!)
    exit(1)
}
