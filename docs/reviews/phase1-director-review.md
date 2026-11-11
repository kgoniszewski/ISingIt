# Director review: phase 0 and phase 1

Reviewed by the director (Fable 5.2) on 2026-11-11, by reading the code and running the
Linux test suite. The Mac app could not be compiled in this review.

## Decision records

| ADR | Verdict | Reason |
|---|---|---|
| 0001 Engine package layout | Accepted | Matches the plan's module boundaries; Linux-buildable engine gives cheap CI. The app builds in Swift 5 language mode with complete concurrency checking until it has compiled cleanly on a Mac, then moves to Swift 6 mode |
| 0002 Formant DSP voice | Accepted | WORLD needs recordings that do not exist yet. The `VoiceSynthesizer`/`PhrasePlan` interface keeps the swap cheap |
| 0003 Project file and ties | Accepted | Single JSON file is enough for phase 1; format version allows migration |

## Gates

- Phase 0 (every fixture parses and round-trips through the IR JSON): **met**.
- Phase 1 (a user imports a song, edits it and hears clear singing in the app):
  **not yet confirmed**. The engine sings intelligibly from the command line, but the
  app has never been compiled or run. The gate closes when the owner builds the app on a
  Mac with the macOS 27 SDK and confirms import, edit and playback.

## Fixed during review

1. Space and Delete were bare-key menu shortcuts, which would have swallowed spaces
   typed into text fields. They are now key handlers on the piano roll; the menu uses
   Command-Return and Command-Delete.
2. WAV export wrote to the save panel's URL after the panel closed, which the sandbox can
   refuse. The song is now rendered first and the save panel writes the file itself.
3. The playback error alert could not be dismissed.
4. Dragging notes on top of each other fed overlapping notes to the planner. The renderer
   now sings a normalised copy of the score.

## For phase 2 issues

- Menu commands reach every open document window (they use notifications). Move to
  focused scene values.
- Weak initial consonants: "grace" is heard as "race", "had" as "and". Alto and bass
  voices are less intelligible than soprano and tenor.
- Golden references were generated on Linux; confirm the macOS runner stays within
  tolerance.
- Piano roll draws with SwiftUI Canvas; the plan's Metal renderer is only needed if long
  songs scroll slowly.
- Settings changes are not undoable; note edits are.
- No listening test with people has been run yet.
