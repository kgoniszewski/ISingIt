# iSingIt test fixtures

Small songs for engine tests. Regenerate the MIDI files and the `.mxl` with:

    python3 Fixtures/Tools/make_midi_fixtures.py
    python3 Fixtures/Tools/make_mxl.py

All melodies are public domain (Twinkle Twinkle Little Star; New Britain, the Amazing Grace tune). The other fixtures are hand-written.

| File | What it tests |
|---|---|
| `MIDI/twinkle_lyrics.mid` | Format 1 import: tempo and time-signature meta, one melody track with per-note lyric events (hyphen convention) |
| `MIDI/twinkle_nolyrics.mid` | Same melody without lyric events (pasting lyrics into a lyric-less track) |
| `MIDI/multitrack.mid` | Melody-track suggestion: bass (ch 1), 3-note chords (ch 2), melody (ch 0, highest mean pitch, has lyrics) |
| `MIDI/tempo_change.mid` | Format 0 single track, tempo 120 bpm changing to 60 bpm at tick 1920 (beat 5), do-re-mi lyrics |
| `MusicXML/twinkle.musicxml` | Basic partwise import: 4/4, divisions 1, `<sound tempo="100"/>`, syllabic begin/end/single |
| `MusicXML/twinkle.mxl` | Compressed MusicXML: `META-INF/container.xml` pointing at `twinkle.musicxml` (ZIP_DEFLATED) |
| `MusicXML/amazing_grace.musicxml` | Pickup measure, 3/4, G major (1 sharp), tempo 72, dotted half, a tie, a slur melisma (`<extend/>`, second note without lyric), `<dynamics><p/>` |
| `MusicXML/two_parts.musicxml` | Part selection: P1 "Soprano" with lyrics, P2 "Piano" without lyrics and with `<chord/>` notes |
| `MusicXML/rests_and_dots.musicxml` | Dotted quarter, eighth, quarter rests, half note; lyrics "hel-lo my friend"; mid-piece tempo change to 140 in measure 2 |
| `Lyrics/twinkle.txt` | Plain-text lyrics for the paste-lyrics test |
