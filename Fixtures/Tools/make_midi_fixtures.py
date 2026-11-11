#!/usr/bin/env python3
"""Write the iSingIt MIDI test fixtures as raw Standard MIDI Files.

Standard library only (no mido, no numpy). Run from anywhere:

    python3 Fixtures/Tools/make_midi_fixtures.py

Output goes to Fixtures/MIDI/. Resolution is 480 ticks per quarter note.
"""

import os

PPQ = 480
VELOCITY = 100

HERE = os.path.dirname(os.path.abspath(__file__))
MIDI_DIR = os.path.normpath(os.path.join(HERE, os.pardir, "MIDI"))

# Ordering of events that share a tick: note-offs first, then meta events
# (tempo, lyrics), then note-ons. This keeps back-to-back notes clean.
PRIO_OFF, PRIO_META, PRIO_ON = 0, 1, 2

# Twinkle Twinkle Little Star, first two phrases.
# (MIDI pitch, duration in quarter-note beats, lyric syllable or None)
TWINKLE = [
    (60, 1, "Twin-"), (60, 1, "kle"), (67, 1, "twin-"), (67, 1, "kle"),
    (69, 1, "lit-"), (69, 1, "tle"), (67, 2, "star,"),
    (65, 1, "how"), (65, 1, "I"), (64, 1, "won-"), (64, 1, "der"),
    (62, 1, "what"), (62, 1, "you"), (60, 2, "are"),
]

# Bass line, monophonic, C2-G2 region (MIDI 36-43). 16 beats total.
BASS = [
    (36, 2, None), (43, 2, None),
    (43, 2, None), (38, 2, None),
    (41, 2, None), (36, 2, None),
    (36, 4, None),
]

# Chords: (start beat, [pitches], duration in beats). 16 beats total.
CHORDS = [
    (0, [60, 64, 67], 4),   # C
    (4, [55, 59, 62], 4),   # G
    (8, [53, 57, 60], 4),   # F
    (12, [60, 64, 67], 4),  # C
]

# Simple C major scale, one quarter note per syllable.
SCALE = [
    (60, 1, "do"), (62, 1, "re"), (64, 1, "mi"), (65, 1, "fa"),
    (67, 1, "sol"), (69, 1, "la"), (71, 1, "ti"), (72, 1, "do"),
]


def vlq(value):
    """Variable-length quantity: 7 bits per byte, high bit set on all but the last."""
    if value < 0:
        raise ValueError("negative delta time")
    out = [value & 0x7F]
    value >>= 7
    while value:
        out.append(0x80 | (value & 0x7F))
        value >>= 7
    return bytes(reversed(out))


def meta_event(meta_type, payload):
    return bytes([0xFF, meta_type]) + vlq(len(payload)) + payload


def note_events(tick, channel, pitch, duration, velocity=VELOCITY):
    """Return (tick, priority, bytes) tuples for one note-on and its note-off."""
    return [
        (tick, PRIO_ON, bytes([0x90 | channel, pitch, velocity])),
        (tick + duration, PRIO_OFF, bytes([0x80 | channel, pitch, 0x40])),
    ]


def melody_events(notes, channel, lyrics=True, velocity=VELOCITY, start=0):
    """Monophonic line. A lyric meta event (FF 05) goes at each note-on tick."""
    events = []
    tick = start
    for pitch, beats, syllable in notes:
        dur = round(beats * PPQ)
        if lyrics and syllable:
            events.append((tick, PRIO_META, meta_event(0x05, syllable.encode("ascii"))))
        events += note_events(tick, channel, pitch, dur, velocity)
        tick += dur
    return events


def chord_events(chords, channel, velocity=70):
    events = []
    for start, pitches, beats in chords:
        for pitch in pitches:
            events += note_events(round(start * PPQ), channel, pitch, round(beats * PPQ), velocity)
    return events


def build_track(events):
    """Turn absolute-tick events into an MTrk chunk with delta times."""
    ordered = sorted(events, key=lambda e: (e[0], e[1]))  # stable: keeps insertion order
    body = bytearray()
    last = 0
    for tick, _prio, payload in ordered:
        body += vlq(tick - last) + payload
        last = tick
    body += vlq(0) + meta_event(0x2F, b"")  # end of track
    return b"MTrk" + len(body).to_bytes(4, "big") + bytes(body)


def named_track(name, events):
    head = [(0, PRIO_META, meta_event(0x03, name.encode("ascii")))]
    return build_track(head + events)


def conductor_track(name, tempos):
    """Tempo map track: track name, 4/4 time signature, and (tick, bpm) tempo changes."""
    events = [
        (0, PRIO_META, meta_event(0x03, name.encode("ascii"))),
        (0, PRIO_META, meta_event(0x58, bytes([4, 2, 24, 8]))),  # 4/4
    ]
    for tick, bpm in tempos:
        us_per_quarter = 60_000_000 // bpm
        events.append((tick, PRIO_META, meta_event(0x51, us_per_quarter.to_bytes(3, "big"))))
    return build_track(events)


def smf(fmt, tracks):
    header = (
        b"MThd"
        + (6).to_bytes(4, "big")
        + fmt.to_bytes(2, "big")
        + len(tracks).to_bytes(2, "big")
        + PPQ.to_bytes(2, "big")
    )
    return header + b"".join(tracks)


def write(filename, data):
    os.makedirs(MIDI_DIR, exist_ok=True)
    path = os.path.join(MIDI_DIR, filename)
    with open(path, "wb") as f:
        f.write(data)
    print("wrote", path, len(data), "bytes")


def main():
    # twinkle_lyrics.mid: format 1, tempo map + melody with lyrics.
    write("twinkle_lyrics.mid", smf(1, [
        conductor_track("Tempo Map", [(0, 100)]),
        named_track("Melody", melody_events(TWINKLE, channel=0, lyrics=True)),
    ]))

    # twinkle_nolyrics.mid: identical melody, no lyric events.
    write("twinkle_nolyrics.mid", smf(1, [
        conductor_track("Tempo Map", [(0, 100)]),
        named_track("Melody", melody_events(TWINKLE, channel=0, lyrics=False)),
    ]))

    # multitrack.mid: bass (ch 1), chords (ch 2), melody (ch 0).
    write("multitrack.mid", smf(1, [
        conductor_track("Tempo Map", [(0, 100)]),
        named_track("Bass", melody_events(BASS, channel=1, lyrics=False, velocity=90)),
        named_track("Chords", chord_events(CHORDS, channel=2)),
        named_track("Melody", melody_events(TWINKLE, channel=0, lyrics=True)),
    ]))

    # tempo_change.mid: format 0, one track, 120 bpm -> 60 bpm at tick 1920 (beat 5).
    events = [
        (0, PRIO_META, meta_event(0x03, b"Scale")),
        (0, PRIO_META, meta_event(0x58, bytes([4, 2, 24, 8]))),
        (0, PRIO_META, meta_event(0x51, (500_000).to_bytes(3, "big"))),   # 120 bpm
        (4 * PPQ, PRIO_META, meta_event(0x51, (1_000_000).to_bytes(3, "big"))),  # 60 bpm
    ]
    events += melody_events(SCALE, channel=0, lyrics=True)
    write("tempo_change.mid", smf(0, [build_track(events)]))


if __name__ == "__main__":
    main()
