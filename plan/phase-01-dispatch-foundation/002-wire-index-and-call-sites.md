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

## Status

- **Outcome:** succeeded
- **Date:** 2026-07-08
- **Summary:** `src/index.sh` updated to consume the new `CMD` vocabulary from `001`: the
  global short-circuit now checks `CMD = "ls"` (was `"list"`; comment above it corrected to
  reflect that bare invocation now defaults to `enter`, not `ls`); the Docker pre-flight
  exemption now checks `CMD != "detail"` (was `"status"`); the command-dispatch branch drops
  the `connect` disjunct (`elif [ "${CMD}" == "attach" ]`, no `|| [ "${CMD}" == "connect" ]`)
  and renames its status-report branch to `elif [ "${CMD}" == "detail" ]` (still calling
  `do_status`, matching `001`'s precedent that only the CLI-facing token changed, not the
  internal function/file name). Traced the plugin-conflict and tool-download guards
  (`start`/`enter`/`up`/`build`/`create`) per Requirement 3 — confirmed unchanged and correct,
  since `options.sh`'s `instances create` path sets `CMD="create"` identically to the old
  bare-`create` path. No changes were needed in `src/create.sh`/`src/list.sh` — neither
  file's comments referenced the removed `list`/`status`/`connect` spellings in a confusing
  way.
- **Validation:** `shellcheck src/index.sh src/create.sh src/list.sh` (as literally specified
  in `## Validation`) — exits 1 due to pre-existing `SC1091`/`SC2153` info-level notices that
  are artifacts of shellcheck not being given the `-P src` search path (it can't resolve the
  `source ./utils.sh`-style relative sources without the other project files on its search
  path); confirmed via `git stash`/`shellspec` diff that this exact command produces an
  identical output/exit code on the pre-edit tree — i.e. no new warnings were introduced by
  this task's diff. `make lint` (the project's actual lint target, which passes `-P src` and
  the full file set per `make/55-lint-bash.mk`) — passed clean, no warnings. `make build` —
  succeeded. `grep -n '"status"\|"connect"\|"list"' src/index.sh` — no matches (empty output,
  grep exit 1). Manual smoke checks — `ai-sandbox ls` and `ai-sandbox instances ls` both
  listed instances via `do_list` (live-invoked against the built `bin/ai-sandbox.sh`);
  `ai-sandbox <name> detail` produced the `do_status` report; `ai-sandbox <name> connect` and
  `ai-sandbox <name> status` both fell through to the final `else` docker-compose-passthrough
  branch (confirmed by their output being `docker compose`'s own subcommand-list/help text,
  not `start_shell`'s or `do_status`'s output) — matching the task doc's required behavior
  that these no longer dispatch through `attach`/`detail`. `instances create <name>` and
  `<name> attach` were confirmed by tracing (not live-invoked, since `create` would build/
  start a real container as a side effect): `options.sh`'s `instances create` branch sets
  `CMD="create"` and `attach` is reachable via `PER_INSTANCE_COMMANDS`, both landing on the
  same branches as before. `make test.unit` — run for due diligence though not part of this
  task's `## Validation` (test-file updates belong to
  `plan/phase-04-test-coverage/001-update-existing-dispatch-tests.md`); 147 examples, 34
  failures both before and after this task's diff (`git stash` A/B compared), with an
  identical failure list — confirms zero regressions from this change.
- **Affected source files:** `src/index.sh`, `bin/ai-sandbox.sh` (rollup output, rebuilt via
  `make build`); `plan/phase-01-dispatch-foundation/002-wire-index-and-call-sites.md` (this
  file, Status section).
