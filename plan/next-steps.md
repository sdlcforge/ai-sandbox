# Next Steps

## Purpose and scope

Tracks pending changes, priorities, and active todos for this project.

## Priorities

(No priorities recorded yet.)

## Todos


### Follow-ups

- 2026-06-06 [001-profiles-spec] Update spec prose for network.preset when V2 'default no network' semantics are defined
- 2026-06-06 [capabilities-spec] PROFILE_CAPABILITIES bash encoding: spec uses space-separated string; implementer should confirm this is workable for iteration (for cap in $PROFILE_CAPABILITIES) vs. newline-delimited sentinel block
- 2026-06-06 [capabilities-spec] Composition hash must include capabilities list in a deterministic way (sort before hashing); confirm hash function signature when implementing profile-installer.js
- 2026-06-06 [003-dockerfile-decomposition] Task 004 owns the path wiring for assembled Dockerfile output (conventional path: $HOME/.cache/ai-sandbox/Dockerfile.<hash>)
- 2026-06-06 [002-profile-installer] Task 005 must prepend 'ai-sandbox:' to PROFILE_IMAGE_TAG; must NOT recompute hash
- 2026-06-06 [004] After Task 005 merges: add --hash "${PROFILE_COMPOSITION_HASH}" arg to assemble-dockerfile.sh invocation in index.sh
- 2026-06-06 [004] static mode full mount suppression (base compose identity mounts) is a follow-up refactor
