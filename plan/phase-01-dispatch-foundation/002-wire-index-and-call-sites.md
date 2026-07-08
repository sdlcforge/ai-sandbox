# Wire Index And Call Sites

## Purpose and scope

Update `src/index.sh`'s command-dispatch phase and the `src/create.sh`/`src/list.sh` call
sites to consume the new `CMD` vocabulary produced by `001-rewrite-dispatch-grammar.md`
(`detail` replacing `status`, `attach` as the only attach spelling, `ls` replacing `list`,
`instances create`/bare-`create`-via-noun replacing free-standing `create`). Depends on
`001` landing first (this task assumes the new `CMD` values already exist). No standard
skill applies — this is novel dispatch-wiring work specific to this codebase.

## Requirements

1. **Global short-circuit block** (`src/index.sh` lines ~28-51 today): change the
   `if [ "${CMD}" = "list" ]` short-circuit to `if [ "${CMD}" = "ls" ]`, calling the same
   `do_list` function (still instance-only output in this phase — the grouped
   instances+profiles listing lands in `profiles-resource`). Leave the `help`,
   `kill-local-ai`, and `new-profile` short-circuits unchanged (the latter is removed in
   `profiles-resource`, not here).
2. **Docker pre-flight exemption** (`src/index.sh` line ~56 today): change
   `if [ "${CMD}" != "status" ]` to `if [ "${CMD}" != "detail" ]` — `detail` still tolerates
   the Docker daemon being down, same as `status` did.
3. **Command dispatch branch** (`src/index.sh` lines ~352-390 today): update every `CMD`
   comparison:
   - `elif [ "${CMD}" == "attach" ] || [ "${CMD}" == "connect" ]` → drop the `connect`
     disjunct entirely: `elif [ "${CMD}" == "attach" ]`.
   - `elif [ "${CMD}" == "status" ]` → `elif [ "${CMD}" == "detail" ]` (still calls
     `do_status`; the internal function name and `src/status.sh` filename are unchanged —
     only the CLI-facing token changes, per the confirmed assumption in
     `plan/notes/current-dispatch-audit.md`).
   - The plugin-conflict pre-flight guard (`if { [ "${CMD}" == "start" ] || [ "${CMD}" ==
     "enter" ] || [ "${CMD}" == "up" ]; } ...`) and the tool-download guard
     (`if [ "${CMD}" = "enter" ] || ... || [ "${CMD}" = "create" ]`) reference `CMD` values
     that are unchanged by this plan (`start`/`enter`/`up`/`build`/`create`) — verify these
     guards still fire correctly given `create` now only arrives via `instances create`
     (the `CMD` value itself is still literally `"create"`, so no change needed here, but
     confirm by tracing `001`'s new `instances create` parse path sets `CMD=create`
     identically to the old bare `create` path).
4. **`do_create()` / `do_list()` call sites** (`src/create.sh`, `src/list.sh`): no
   functional changes are required to `do_create()` or `do_list()` themselves in this
   task — they are dispatched into by the same `CMD` values (`create`, `ls`→still calls
   `do_list`) they always were; only `src/index.sh`'s branch conditions changed. If, while
   making the `src/index.sh` changes above, any comment or local variable name in
   `src/create.sh`/`src/list.sh` references the removed `list`/`status`/`connect` spellings
   in a way that would confuse a future reader (e.g. a comment saying "called for `list`"),
   update the comment for accuracy, but do not rename functions or files (`do_list`,
   `list.sh`, `do_create`, `create.sh` all keep their names — only CLI-facing tokens
   changed, consistent with the `status.sh`/`do_status()` precedent).
5. Double-check no other file under `src/` references the removed CLI tokens as dispatch
   conditions (`grep -rn '"status"\|"connect"\|"list"' src/` and manually assess each hit —
   internal identifiers like `STATUS_JSON`/`STATUS_TEST_CHECK`/`status.sh` are expected and
   out of scope per the confirmed assumption above; only CLI dispatch conditions need
   updating).

## Validation

- `shellcheck src/index.sh src/create.sh src/list.sh` passes with no new warnings.
- `make build` succeeds.
- `grep -n '"status"\|"connect"\|"list"' src/index.sh` shows no remaining CLI-dispatch
  comparisons against those tokens (label/env-var references like
  `ai.sandbox.instance`/`STATUS_JSON` are unrelated and expected to remain).
- Manual smoke checks (build the rolled-up script and invoke against a throwaway sandbox
  name, or trace through the code): `ai-sandbox ls`, `ai-sandbox instances ls`,
  `ai-sandbox instances create <name>`, `ai-sandbox <name> detail`, `ai-sandbox <name>
  attach` all reach the same underlying handlers (`do_list`, `do_create`, `do_status`,
  `start_shell` respectively) that the old `list`/`create`/`status`/`attach` spellings
  reached.
- `ai-sandbox <name> connect` and `ai-sandbox <name> status` no longer dispatch through the
  `attach`/`detail` branches — since `001` already made these fall through to the per-name
  literal-instance-name path, confirm `src/index.sh`'s final `else` (docker-compose
  passthrough) branch is what now handles an unrecognized trailing word like `connect`
  after a valid name (same as any other unrecognized per-instance word today, e.g. `ai-sandbox
  mybox logs -f`).

## Metadata

architectural_impact: true

## References

- `plan/phase-01-dispatch-foundation/001-rewrite-dispatch-grammar.md` — prerequisite task;
  this task's `CMD` vocabulary assumptions depend on it having landed.
- `docs/architecture.md`'s "Command flow" section (step 11) documents the dispatch branch
  this task updates — not edited by this task (that's `docs-and-help`), but useful context
  for what "documented topology" this task's `architectural_impact: true` flag refers to.
