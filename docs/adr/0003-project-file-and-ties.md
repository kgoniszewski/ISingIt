# ADR 0003: Phase 1 project file is one JSON file; ties are merged at import

Status: accepted (phase 1), needs director sign-off

## Decision
- `.isingit` is a single JSON file (`Project`: format version, Score IR, render settings).
  The plan's package format with a render cache can replace it later; the format
  version field allows migration.
- Tied notes are merged into one longer note at import (a singer sings them as one note),
  so the Score IR has no tie flag. Slurred notes without lyrics, and notes under a lyric
  extension line, become melisma notes (`continuesSyllable`).
- Notes without lyrics are sung on "la".
- The first phrase may begin before song time zero, because consonants are sung ahead of
  the first beat. The renderer adds this lead-in (`PerformancePlan.leadIn`) to the front
  of the audio; song time t plays at audio time t + leadIn.
