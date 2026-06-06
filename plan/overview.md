# Overview: Profiles Feature Documentation

## Purpose and scope

Write three documentation files that specify and document the ai-sandbox **profiles** feature as designed in conversation. No code is being written in this round — this is the specification and reference documentation pass that will guide implementation.

Files produced:
- `docs/ai-sandbox-profiles-spec.md` (new) — canonical specification
- `README.md` (update) — restructured to Flow standards, profiles section added
- `docs/architecture.md` (update) — profiles architecture section added

## Current status

Not started. No plan existed prior to this round.

## Overview

Single documentation phase, two sequential tasks.

### Phase 01 — Documentation

| # | Task | Branch | Depends on | Parallel-eligible with |
|---|------|--------|------------|------------------------|
| 001 | Write profiles spec | `task/001-profiles-spec` | — | — |
| 002 | Update reference docs | `task/002-update-reference-docs` | 001 | — |

**Critical path:** 001 → 002

Task 001 is the source of truth. Task 002 reads the written spec to ensure README and architecture doc reference it accurately and consistently.
