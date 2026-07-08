# Current Dispatch Audit

Findings from reading `src/options.sh`, `src/index.sh`, `src/create.sh`, `src/list.sh`,
`src/new-profile.sh`, `src/help.sh`, `src/status.sh`, `src/utils.sh`, and
`test/unit/ai_sandbox_spec.sh` against the restructure requirements. Recorded here so a
re-invocation (after the open question in
[profiles-delete-ambiguity.md](./profiles-delete-ambiguity.md) is resolved) does not need to
redo this investigation.

## Confirmed table contents (as of this session)

- `GLOBAL_COMMANDS` (`src/options.sh` line 76): `create list help kill-local-ai new-profile`.
- `RESERVED_NAMES` (`src/options.sh` line 78): `create list help kill-local-ai new-profile status detail`
  — confirmed drifted from the real tables: every `PER_INSTANCE_COMMANDS` word except
  `status`/`detail` is missing (`enter start stop delete attach connect build clean fix-ssh
  user-exec root-exec up`). `test/unit/ai_sandbox_spec.sh` lines 923-941 test only the
  `status`/`detail` collisions that happen to already be covered — there is no test today
  proving e.g. `create enter` is rejected, because it isn't.
- `PER_INSTANCE_COMMANDS` (`src/options.sh` line 165): `start enter attach connect fix-ssh
  build user-exec root-exec status detail stop delete clean up`.
- `detail` → `status` normalization happens in exactly one place (`src/options.sh` lines
  213-221), right after Phase 2's `CMD` assignment, plus a second, deliberately duplicated
  normalization inline in Phase 3's flag-parser loop (lines 336-341) for the case where a
  per-instance command word gets pushed past a leading flag and is promoted later. Both
  call sites must be updated together when `status` is dropped as a recognized word.
- `status.sh`'s `do_status()` is the implementation for both spellings today; `STATUS_JSON`,
  `STATUS_TEST_CHECK` globals and the `status.sh` filename are internal identifiers, not
  CLI-facing spellings. **Assumption applied:** dropping the `status` CLI word does not
  require renaming these internals — only the recognized command token changes. Flagged
  for manager confirmation in the structured report; low risk either way.

## Bare no-args behavior — resolved discrepancy

`src/options.sh` Phase 2 (`n_remaining -eq 0` → `CMD="list"`) and
`test/unit/ai_sandbox_spec.sh` line 649 (`It 'defaults CMD to list on bare invocation'`)
both confirm: **today, a truly bare `ai-sandbox` invocation lists all sandboxes**, not
"enter the default instance."

This contradicts:
- `README.md`'s Quick Start block, which shows bare `ai-sandbox` as "Enter the sandbox
  (builds image if needed, starts container, connects)".
- The general expectation set by `src/help.sh`'s own usage banner (which, read carefully,
  is actually consistent with the code — it lists bare invocation as "List all sandboxes"
  on its own separate line from the per-instance-with-no-verb "default: enter" case — so
  `help.sh` matches the code; only the README Quick Start is wrong).

The user request's requirement 3 anticipated exactly this uncertainty and instructed:
"confirm exactly what 'no args at all' currently does ... and preserve that specific
behavior unless it's the old `list` command's behavior being renamed." Having confirmed
bare no-args *is* today's `list` behavior (not a separate enter path), and given
requirement 6 directs fixing README/code mismatches in favor of correct, consistent
documented behavior, this plan's resolution (applied as a firm decision, not a blocking
question) is:

- Bare `ai-sandbox` (zero args) now enters the default/unnamed instance (the behavior the
  README's Quick Start has always advertised and that per-instance dispatch's "no verb
  given → enter" pattern already establishes for named instances).
- The old bare-list behavior is what the new explicit `ai-sandbox ls` word replaces — bare
  `ls` is required to get the grouped listing going forward.
- `test/unit/ai_sandbox_spec.sh` line 649's assertion (`CMD should eq list` on bare
  invocation) must be updated to assert `CMD should eq enter` with empty `SANDBOX_NAME`,
  and a new test added asserting bare `ls` produces the grouped listing.
- README's Quick Start block itself was already correct in spirit (bare invocation enters)
  — no change needed there beyond removing the now-invalid `down`/`logs` passthrough
  example (see below) and reflecting the new noun-based commands elsewhere in the CLI
  reference table.

This is called out as `assumptions_applied` / `flagged_for_manager` in the structured
report — it is a real, user-facing default-behavior change (from "list" to "enter" on bare
invocation) even though the requirement text points at exactly this resolution.

## README `down` / `logs` passthrough claim

`README.md`'s CLI reference table documents `ai-sandbox down` and `ai-sandbox logs -f` as
supported. Tracing `src/options.sh`: neither `down` nor `logs` appears in
`GLOBAL_COMMANDS`, `PER_INSTANCE_COMMANDS`, or any noun word. A bare `ai-sandbox down`
today parses as `SANDBOX_NAME="down"` (a per-instance name), not a passthrough word — it
would attempt to enter/act on an instance literally named "down", not forward to
`docker compose down`. The passthrough fallback (`src/index.sh` line 389, the final `else`
branch forwarding `${ARGS[@]}` to `docker compose ...`) only fires when `SANDBOX_NAME` is
already resolved as a real instance name and a *second* bare word follows that isn't a
recognized per-instance verb, e.g. `ai-sandbox myname down`. So passthrough is real but
always requires an instance-name prefix; the README's example (no name prefix) does not
work as written today.

**Resolution direction (per requirement 6):** fix the README to show passthrough correctly
scoped to a named instance (e.g. `ai-sandbox mybox down`, `ai-sandbox mybox logs -f`), and
drop the unscoped `ai-sandbox down` / `ai-sandbox logs -f` examples from the Quick Start.
Do not add new passthrough capability — the existing mechanism (once instance/profile name
resolution is layered in per requirement 3) already unambiguously supports scoped
passthrough; nothing further is required.

## Name-resolution / verb-gating design sketch

For the phase-2 (profiles-resource) task breakdown once the open question resolves:

- `instance_exists <name>` — factor the ad hoc `docker ps -a --filter
  "name=^ai-sandbox-<name>$"` check already inlined in `src/create.sh`'s `do_create()` into
  a reusable `src/utils.sh` helper, so both the collision check (requirement 5) and the
  new name-kind resolver can call it.
- `profile_exists <name>` — new helper in the profiles module, consulting the same
  three-location discovery order as `bin/profile-installer.js` (project-local
  `./profiles/<name>.yaml`, `$XDG_CONFIG_HOME/ai-sandbox/profiles/<name>.yaml`, bundled).
- A new resolution step in `src/options.sh` (or a thin wrapper called early from
  `src/index.sh`, before the Docker pre-flight) determines, for a bare-name-then-verb
  invocation, whether `SANDBOX_NAME` resolves to an instance, a profile, or neither, and
  gates `CMD` against a per-kind allowed-verb list:
  - Profile-appropriate verbs: `detail` (show composed/raw YAML), `delete` (remove the
    profile file) — pending the open question about surface syntax.
  - Instance-only verbs: `enter start stop delete attach detail build clean fix-ssh
    user-exec root-exec up` and passthrough.
  - Unknown name (resolves to neither): clear error, distinct from "reserved word" and
    from "unknown per-instance command."
- Architecturally significant: profile-kind dispatch for `detail`/`delete` must NOT require
  a live Docker daemon or run the Docker pre-flight / profile-installer.js resolution
  phases that `src/index.sh` currently runs unconditionally for every non-short-circuited
  command — those phases exist to prepare a container invocation and are meaningless for a
  bare YAML file. This mirrors today's existing short-circuit pattern for `list`/`help`/
  `kill-local-ai` (`src/index.sh` lines 28-51, which already run before the Docker
  pre-flight) and should be extended to cover profile-kind dispatch.

## Reserved-word derivation — words needing inclusion beyond the obvious tables

The single-source-of-truth reserved-word function (requirement 5) must include, in
addition to the existing per-name verb table:

- The new noun words `instances` and `profiles` themselves (an instance or profile
  literally named "instances" would be unreachable via `ai-sandbox instances ls`, since
  that word is consumed as the noun).
- `ls` (the new bare-listing word).
- `create` — even though `create` is no longer a free-standing global command word (it
  only appears as the second token after `instances`/`profiles`), it must still be
  reserved. Without this, `ai-sandbox create` alone (no noun) would fall through to the
  "first arg doesn't match any noun or per-name verb, so treat it as a bare instance name"
  branch, defaulting to `CMD=enter` against an instance literally named `create` —
  reproducing the exact `ai-sandbox create enter` bug this plan is fixing, just with
  `create` in the name slot instead of `enter`.
- `help` and `kill-local-ai` (existing global commands, unchanged).

## Other project docs referencing dropped spellings

- `README.md`: CLI reference table rows for `status`/`detail` and `attach`/`connect`
  (currently documents both spellings as valid); `new-profile` row; the `create`
  Quick-Start-adjacent examples if any; the `down`/`logs` passthrough example above.
- `docs/architecture.md`: "Command flow" step 11 mentions `status` explicitly
  (`start/enter/attach/build/user-exec/root-exec/status/stop/clean`) and the "Status as
  both human and machine interface" section's opening sentence ("`ai-sandbox status` (and
  its pure alias `detail`...)") — both need rewording once `status` is dropped and `detail`
  is canonical.
- `src/help.sh`: full command tables (global + per-instance) need a rewrite to the new
  grammar.
