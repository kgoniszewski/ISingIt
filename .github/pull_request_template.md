## Summary

<!-- What does this change and why? -->

## Phase / Issue

<!-- Roadmap phase (e.g. Phase 1) and linked issue: Closes #123 -->

## How tested

<!-- Commands run (swift test, isingit render ...), listening checks, golden updates. -->

## Benchmarks

<!-- Output of `isingit bench Fixtures/MusicXML/amazing_grace.musicxml` if render speed could change; otherwise "n/a". -->

## Checklist

- [ ] `swift build` and `swift test` pass locally
- [ ] New behavior has tests (Swift Testing)
- [ ] Golden files regenerated and reviewed if audio output changed (`ISINGIT_UPDATE_GOLDEN=1 swift test --filter RenderGoldenTests`)
- [ ] Docs / ADR updated if architecture changed
