---
id: SPEC-ID            # e.g. SYNC-001
title: <Feature name>
milestone: v0.1        # v0.1 | v0.2 | v0.3 | v0.4 | v0.5 | later
status: Draft          # Draft | Ready | Outline
depends_on: []         # other spec IDs
adrs: []               # ADR numbers as plain integers, e.g. [4, 5]
targets: []            # Shared, Levels-iOS, Levels-Mac, Levels-Watch, Widgets-iOS, Widgets-Mac, Widgets-Watch
---

# <SPEC-ID>: <Feature name>

## Why

The user problem this solves, in two or three sentences.

## Scope

- In: …
- Out (and where it goes instead): …

## Behaviour

What the user sees and what the system does. Numbered rules (R1, R2, …) a test can check.

## Design

Types, modules, public APIs (Swift signatures), data flow, entitlements and Info.plist keys, threading/concurrency (Swift 6 strict concurrency).

## Edge cases and failure modes

No iCloud account, account change, offline, throttled push, stale data, device removed, clock skew, low power mode, etc. — whatever applies.

## Acceptance criteria

- [ ] AC1 — Given … when … then … (testable)
- [ ] AC2 — …

## Tests

Which ACs are unit tests (Swift Testing), which are UI/integration tests, which need a manual check on real hardware, and why.

## Open questions

Only questions the owner must answer. Mark builder-level calls as **Builder's call:** in the Design section instead.
