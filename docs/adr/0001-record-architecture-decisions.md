# ADR-0001: Record architecture decisions as ADRs and features as specs

- **Status:** Accepted
- **Date:** 2026-11-23
- **Deciders:** project owner

## Context

Levels is a personal tool first (owner's own devices; App Store later, maybe). It spans four platforms and several extensions, and most of its hard parts are platform constraints (background execution, push throttling, sandboxing) that must be decided once and remembered.

## Decision

- Architectural decisions live in `docs/adr/NNNN-<slug>.md`, using `docs/adr/template.md`. Numbers are never reused; a changed decision gets a new ADR that supersedes the old one.
- Buildable features live in `docs/specs/<ID>-<slug>.md`, using `docs/specs/template.md`. ID prefixes: `SYNC` (CloudKit sync and data), `RPT` (battery reading and reporting), `MAC` (Mac agent), `UI` (app, widget and complication UI), `ALR` (alerts), `HIS` (history), `NRB` (BLE nearby mode), `FAM` (family sharing), `QA` (cross-cutting quality).
- Specs for v0.1–v0.2 are build-ready (`status: Ready` after review). Specs for v0.3 and later are `status: Outline` until their milestone starts.
- `docs/adr/README.md` and `docs/specs/README.md` index everything.

## Consequences

- A builder (human or agent) can implement a spec without asking the owner, because the "why" and the platform facts are written down.
- Specs and ADRs must be updated when the code deviates; a deviation without a document change is a defect.
