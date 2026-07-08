## Goals

Rework `src/options.sh`'s command-parsing tables to the new noun-based grammar without yet
implementing profile-specific behavior. Land the pieces that are independent of the open
[profiles-delete question](../notes/profiles-delete-ambiguity.md):

- Replace `GLOBAL_COMMANDS`/old `create`-verb-first parsing with the `instances`/`profiles`
  noun words, each supporting (at minimum) `ls` and `create <name> [options]`.
- Add the bare `ls` word (no noun) producing a grouped listing; fix bare no-args to enter
  the default instance instead of listing (see
  [current-dispatch-audit.md](../notes/current-dispatch-audit.md) for the rationale —
  this corrects a README/code mismatch, not a new behavior invented for this plan).
- Collapse aliases: drop `status` (keep `detail` as the only spelling; `detail` becomes the
  canonical `CMD` value, replacing today's `detail`→`status` normalization direction) and
  drop `connect` (keep `attach` only).
- Replace the hand-maintained `RESERVED_NAMES` literal with a single function/array derived
  from the real live tables (global words, noun words, the shared per-name verb table) so
  the collision check and the dispatch logic structurally cannot drift apart again. Include
  `ls`, `instances`, `profiles`, and `create` in the derivation per the audit note, not just
  the obvious per-name verbs.
- Implement the name-collision check for `instances create <name>` (existing behavior,
  moved/renamed from the old `create <name>` path) and thread through the same reserved-word
  function.
- Rename/adapt `src/create.sh`'s `do_create()` and `src/list.sh`'s `do_list()` call sites to
  the new `CMD` values; update `docs/architecture.md`'s "Command flow" step numbering is
  NOT in scope here (that's the `docs-and-help` phase) but the dispatch behavior it
  describes must match after this phase lands.

## Inputs

- `src/options.sh`, `src/index.sh`, `src/create.sh`, `src/list.sh` (current state fully
  read this session; see the audit note for line-level references).
- `test/unit/ai_sandbox_spec.sh` existing coverage of `parse_options` (bare invocation,
  `create <name>` reserved-name rejection, `detail`/`status` alias normalization) — these
  tests will need corresponding updates in the `tests` phase, but this phase's tasks should
  not edit the test file themselves (kept as a separate phase for review clarity, per the
  user request's explicit "add/update test coverage" scope item being called out
  separately from the dispatch-mechanism changes).
- The resolution of the [bare no-args behavior change](../notes/current-dispatch-audit.md)
  (applied as a firm decision in this plan, flagged for manager/user confirmation in the
  structured report, not blocking).

## Outputs

- `src/options.sh` with: a single reserved-word derivation function/array consumed by both
  the collision check and dispatch; `instances`/`profiles` noun parsing for `ls`/`create`;
  bare `ls` recognized; bare no-args → enter default instance; `status`/`connect` no longer
  recognized anywhere.
- `src/index.sh` dispatch phase updated for the new `CMD` vocabulary (`detail` replacing
  `status` as the canonical value; `attach` as the only attach spelling).
- A stable, documented interface (function signature and expected inputs/outputs) for the
  per-name "resolve to instance or profile, then verb-gate" mechanism the `profiles-resource`
  phase will complete — this phase should stub or partially wire it (e.g. always resolving
  to "instance" until the profiles phase adds `profile_exists`), so downstream phases have a
  concrete extension point rather than needing to invent the mechanism from scratch.
- No profile-specific CRUD behavior yet (that's the next phase) — `profiles ls`/`profiles
  create` may land here if straightforward, or be deferred to `profiles-resource` if they
  turn out to depend on the profiles-module split; task breakdown will decide once the open
  question resolves.
