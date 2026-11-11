#!/usr/bin/env python3
"""Intelligibility benchmark: renders the fixture songs and scores them with a speech
recogniser (word error rate, lower is better). Needs `pip install faster-whisper numpy`.

    python3 bench/intelligibility.py --isingit .build/release/isingit [--voices dsp-soprano,dsp-tenor]
                                     [--model small.en] [--set key=value ...] [--json out.json]
"""
import argparse, json, os, re, subprocess, sys, tempfile, wave

import numpy as np

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SONGS = [
    ("Fixtures/MusicXML/twinkle.musicxml", [], "twinkle twinkle little star how i wonder what you are"),
    ("Fixtures/MusicXML/amazing_grace.musicxml", ["--transpose", "-5"], "amazing grace how sweet the sound that saved a wretch like me"),
    ("Fixtures/MusicXML/two_parts.musicxml", [], "mary had a little lamb"),
    ("Fixtures/MusicXML/rests_and_dots.musicxml", [], "hello my friend la"),
    ("Fixtures/MIDI/twinkle_nolyrics.mid", ["--lyrics", "Fixtures/Lyrics/twinkle.txt"], "twinkle twinkle little star how i wonder what you are"),
]


def words(text):
    return re.sub(r"[^a-z' ]", " ", text.lower()).split()


def wer(ref, hyp):
    r, h = words(ref), words(hyp)
    d = np.zeros((len(r) + 1, len(h) + 1), dtype=int)
    d[:, 0] = range(len(r) + 1)
    d[0, :] = range(len(h) + 1)
    for i in range(1, len(r) + 1):
        for j in range(1, len(h) + 1):
            d[i, j] = min(d[i - 1, j] + 1, d[i, j - 1] + 1, d[i - 1, j - 1] + (r[i - 1] != h[j - 1]))
    return d[len(r), len(h)] / max(1, len(r))


def load16k(path):
    w = wave.open(path)
    x = np.frombuffer(w.readframes(w.getnframes()), dtype=np.int16).astype(np.float32) / 32768
    sr = w.getframerate()
    t = np.arange(0, len(x) * 16000 // sr) * sr / 16000
    return np.interp(t, np.arange(len(x)), x).astype(np.float32)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--isingit", default=os.path.join(ROOT, ".build/release/isingit"))
    ap.add_argument("--voices", default="dsp-soprano,dsp-tenor")
    ap.add_argument("--model", default="small.en")
    ap.add_argument("--set", action="append", default=[])
    ap.add_argument("--json")
    ap.add_argument("-v", "--verbose", action="store_true")
    args = ap.parse_args()

    from faster_whisper import WhisperModel
    model = WhisperModel(args.model, device="cpu", compute_type="int8")
    extra = [a for kv in args.set for a in ("--set", kv)]
    results = []
    with tempfile.TemporaryDirectory() as tmp:
        for voice in args.voices.split(","):
            for song, opts, ref in SONGS:
                out = os.path.join(tmp, "out.wav")
                subprocess.run([args.isingit, "render", os.path.join(ROOT, song), "-o", out, "--voice", voice]
                               + [os.path.join(ROOT, o) if o.startswith("Fixtures/") else o for o in opts] + extra,
                               check=True, capture_output=True)
                segments, _ = model.transcribe(load16k(out), beam_size=5, language="en", condition_on_previous_text=False)
                hyp = " ".join(s.text.strip() for s in segments)
                score = wer(ref, hyp)
                results.append({"voice": voice, "song": os.path.basename(song), "wer": score, "heard": hyp})
                if args.verbose:
                    print(f"{voice:12s} {os.path.basename(song):28s} WER {score:5.2f}  heard: {hyp}")
    mean = sum(r["wer"] for r in results) / len(results)
    print(f"mean WER {mean:.3f} over {len(results)} renders")
    if args.json:
        with open(args.json, "w") as f:
            json.dump({"mean_wer": mean, "results": results}, f, indent=2)


if __name__ == "__main__":
    sys.exit(main())
