# ADR 0002: Phase 1 DSP voice is a formant synthesizer, not WORLD + phoneme bank

Status: accepted (phase 1), needs director sign-off

## Context
The plan's baseline voice is the WORLD vocoder driven by a small recorded phoneme bank.
No singer has been recorded yet, and the training-data question (licences, English and
Polish singers) is still open. Without recordings, WORLD has nothing to resynthesise.

## Decision
Phase 1 ships a Klatt-style source-filter formant voice (`ISingItSynth.FormantVoice`):
a KLGLOTT88 glottal pulse at the planned pitch excites five cascaded formant resonators
that follow per-phoneme targets (with coarticulation smoothing, diphthong glides,
formant tuning on high notes); fricatives and stop bursts add band-pass noise. Four
voice profiles (soprano, alto, tenor, bass) scale the formants and glottal shape.

It needs no data, renders about 100 to 500 times faster than real time, and is
intelligible: the speech-recogniser benchmark (`bench/intelligibility.py`) gives a mean
word error rate of about 0.22 on the fixture songs (see docs/PHASE1.md).

## Consequences
- It sounds synthetic. It is the "fast preview" voice the plan keeps after phase 3.
- The voice interface (`VoiceSynthesizer`, `PhrasePlan`) is the one the WORLD voice or the
  neural voice will implement; nothing upstream changes when they arrive.
- WORLD + phoneme bank remains an option once an original singer is recorded.
