# Session Summary: cli-restructure

## What was planned and why

The `ai-sandbox` CLI's command surface had drifted: alias pairs duplicated meaning
(`status`/`detail`, `attach`/`connect`), the `RESERVED_NAMES` list was a hand-maintained
literal that had already fallen out of sync with the live command tables, and profile
management was scaffold-only (`new-profile` could create a profile but nothing could list
or delete one). This session restructured the CLI onto a noun-based grammar — plural
resource nouns `instances` and `profiles`, each supporting `ls`/`create` sub-verbs for the
two operations that previously had no name to dispatch through — while extending the
existing flat name-then-verb dispatch mechanism (previously instance-only) to also resolve
profile names and gate verbs by resolved kind. The plan collapsed the redundant alias pairs
outright (no backward-compatible aliasing was wanted), replaced the drifted
`RESERVED_NAMES` literal with a single source of truth derived from the live command
tables (`compute_reserved_names()`), and added genuine profile CRUD (`profiles ls`, and
profile deletion via the shared per-name dispatch). Documentation
(README.md, `docs/architecture.md`, `docs/ai-sandbox-profiles-spec.md`, `src/help.sh`) and
ShellSpec test coverage were folded in as required consequences of the grammar change.
Marketplace/plugin CRUD was explicitly kept out of scope (those remain flags on
instance/profile create, not independent resources).

Work was organized into four phases, in strict dependency order: `dispatch-foundation`,
`profiles-resource`, `docs-and-help`, and `test-coverage`.

## What shipped

### Phase 1 — dispatch-foundation (2 tasks)

**Task 001 — rewrite-dispatch-grammar** (merge `ba8b015`)
Rewrote `src/options.sh`'s `parse_options()` to the new noun-based grammar:
`RESERVED_NAMES` is now derived by `compute_reserved_names()` from the live
`GLOBAL_COMMANDS`/`PER_INSTANCE_COMMANDS`/`NOUN_WORDS` tables plus `EXTRA_RESERVED_WORDS`
(`create`, `ls`); added `instances ls`/`instances create <name>` noun parsing; removed
`status`/`connect` from all tables and both `detail`<->`status` normalization sites; added
a standalone bare `ls` word; changed bare no-args behavior from `CMD=list` to
`CMD=enter`/`SANDBOX_NAME=empty`; wired `resolve_name_kind()` as a stub (always returns
instance) as the extension point for the profiles-resource phase.

**Task 002 — wire-index-and-call-sites** (merge `e6922ec`)
Wired `src/index.sh`'s command-dispatch phase to the new noun-based `CMD` vocabulary from
task 001: the global `ls` short-circuit, the Docker preflight `detail` exemption, and the
dispatch branch's `attach`/`detail` conditions now use the new tokens, and the `connect`
disjunct was dropped. `src/create.sh` and `src/list.sh` needed no changes. Verified via live
smoke tests; `make lint` clean; `make test.unit` showed identical 34 pre-existing failures
before/after (owned by phase-04).

**Post-phase-review bugfixes (not part of the original 8-task breakdown, no TODO.yaml
entries):**
- `3d003fe` — fixed a real dispatch bug where `<name> ls` collided with the global `ls`
  short-circuit and silently discarded the instance name.
- `e61596a` — fixed a broken `make test.integration` preflight gate that still invoked the
  removed `status` CLI word instead of `detail`.
- `cb04b53` — fixed a stale comment in `src/status.sh`.

### Phase 2 — profiles-resource (2 tasks)

**Task 001 — build-profiles-module** (merge `4973adf`)
Renamed `src/new-profile.sh` to `src/profiles.sh`, converting `new_profile()` into
`profiles_create()` with a positional `<name>` arg; added `profile_exists()`/
`do_profiles_list()` plus a factored-out `instance_exists()` helper in `src/utils.sh`. Wired
`profiles ls`/`profiles create <name>` into `src/options.sh`'s noun-based dispatch grammar
parallel to `instances`, explicitly excluding a profiles-delete noun-level verb per the
plan's resolved ambiguity (see Key Decisions below). Added early short-circuits in
`src/index.sh`; dropped `new-profile` as a global command with no alias. Collision checks
reject a name colliding with any instance, profile, or reserved word regardless of which
noun's `create` is used. All required validation passed; manual smoke checks covered every
task-doc scenario.

**Task 002 — complete-name-resolution-and-verb-gating** (merge `3d3fb07`)
Completed `resolve_name_kind()` to consult `instance_exists()`/`profile_exists()` (instance
wins on collision); added a Phase 3.5 verb-gating step restricting profile-kind names to
`detail`/`delete` and rejecting unknown-kind names with a distinct error; added
`do_profiles_detail()`/`profiles_delete()`/`_profile_resolve_location()` to
`src/profiles.sh`; added a profile-kind short-circuit in `src/index.sh` ahead of the Docker
preflight; distinguished bare `ls` (new grouped `do_list_all()`) from `instances ls` (now
`CMD=instances-ls`). All manual smoke checks passed against the built script with both live
and simulated-down Docker daemon, without touching the real `flow-rook` instance.
shellcheck/`make lint`/`make build` clean.

**Post-phase-review bugfixes (not part of the original 8-task breakdown, no TODO.yaml
entries):** phase-review found three interconnected bugs, fixed across two commits:
- `430db94` — fixed a **CRITICAL correctness bug** where Docker-unreachable was
  misclassified as "instance doesn't exist," breaking the documented Docker-down tolerance
  and the auto-start preflight; also fixed a **major efficiency regression** where
  `resolve_name_kind()` was called twice per invocation, doubling `docker ps -a` daemon
  round-trips.
- `fa429e3` — fixed a **major security vulnerability**: profile `detail`/`delete` followed
  symlinks unguarded, allowing a malicious repo to plant a `profiles/<name>.yaml` symlink
  and exfiltrate arbitrary host file contents via `ai-sandbox <name> detail` before Docker
  isolation ever engaged.

### Phase 3 — docs-and-help (2 tasks)

**Task 001 — update-readme-and-profiles-spec** (merge `bdb6aa7`)
Rewrote README.md's CLI reference table and Quick Start block, plus renamed/updated the
`new-profile`-command section of `docs/ai-sandbox-profiles-spec.md`, to match the noun-based
CLI grammar confirmed landed in `src/options.sh` and `src/index.sh`. All prose mentions of
dropped spellings updated or confirmed unrelated. One same-diff self-fix corrected a stale
"profiles not yet implemented" claim. All validation greps pass; the CLI reference table was
manually cross-checked against dispatch source (not `src/help.sh`, owned by parallel sibling
task 002 which hadn't landed yet).

**Task 002 — update-architecture-and-help-text** (merge `3d3c78f`)
Rewrote `docs/architecture.md`'s Command flow step 11 and adjacent Docker-preflight step 3
to describe the noun-word parsing phase, `resolve_name_kind()`'s resolve-then-verb-gate
mechanism, `detail` replacing `status`, `attach` without `connect`, and the profile-kind
short-circuit that skips the Docker preflight entirely. Removed "pure alias" framing,
retired remaining stale `status` mentions. Fully rewrote `src/help.sh`'s `print_help()`
heredoc to match the noun-based grammar. All validation checks plus a manual help-output
cross-check pass.

**Post-phase-review bugfix (not part of the original 8-task breakdown, no TODO.yaml
entry):**
- `8300dd9` — fixed a factual inaccuracy in `docs/architecture.md` about dispatch
  short-circuit ordering, an incomplete per-instance-verb enumeration, and an overstated
  "never touches Docker" claim.

### Phase 4 — test-coverage (2 tasks)

**Task 001 — update-existing-dispatch-tests** (merge `9773543`)
Fixed all 54 baseline-failing `test/unit/ai_sandbox_spec.sh` examples in the
`parse_options()` Describe block: 28 via Requirements 1-4 plus a followup-flagged (`rUS7`)
unknown-name-as-instance mocking carve-out, and 24 via mechanically rewriting retired bare
`create <name>` invocations to `instances create <name>` (manager-authorized as
same-category existing-test-update work; see Key Decisions). `shellspec` `parse_options()`
block now 62/62 green. `make test.unit`: 183 examples, 2 failures remaining — both
`new_profile()` (renamed to `profiles_create()` in phase-02), explicitly already covered by
task 002's scope.

**Task 002 — add-new-grammar-and-gating-tests** (merge `24610a9`)
Added new ShellSpec coverage covering all five Requirements: `instances create` end-to-end
parse behavior; `profiles ls`/`create` parsing plus a `Describe profiles_create()` block
replacing the old `new_profile()` block (matching phase-02's rename) and a
`Describe profiles_delete()` block covering bundled-profile refusal and successful deletion;
a structural test proving `compute_reserved_names()` is a genuine derivation (including an
injection test); cross-kind and same-kind name-collision checks for both `instances create`
and `profiles create`; and per-name verb-gating coverage asserting profile-appropriate verbs
are allowed, instance-only verbs and default `enter` are rejected against a
profile-resolved name with a distinct error, and any verb against an unresolvable name
produces its own distinct unknown error. Confirmed no test references a
`profiles delete <name>` noun-level parse path. Full suite green: 175/175, shellcheck clean.
This was the final task in the cli-restructure plan.

## Key decisions

**Profiles-delete-ambiguity resolution (the most load-bearing decision of the session).**
The first `analyze-change-request` invocation surfaced a genuine contradiction within the
settled requirements: should profile deletion be `ai-sandbox profiles delete <name>` (a
noun-level three-token form) or `ai-sandbox <name> delete` (via the shared flat-namespace
per-name dispatch, symmetric with instance deletion)? This could not be resolved by
guessing and was escalated to the user, who chose **Option B**: `profiles`/`instances` noun
words support *only* `ls` and `create`; profile deletion is exclusively
`ai-sandbox <name> delete` via the shared dispatch mechanism. No
`ai-sandbox profiles delete <name>` form exists. This decision shaped phase-02's task
breakdown (the `profiles_delete()` implementation and its dispatch wiring) and phase-04's
test coverage (explicit confirmation that no test references a noun-level
`profiles delete <name>` parse path). Full resolution detail is recorded in
`plan/notes/profiles-delete-ambiguity.md`'s "## Resolution" section.

**Manager-authorized scope expansions during phase-04.** Two additional test-fixing scopes
were folded into task 001 ("existing test updates") rather than deferred or treated as new
scope: 18 unknown-name-rejection tests (consequence of Requirement 2's deliberate behavior
change — an unknown-kind name now errors for any verb, not just `detail`/`delete`, flagged
in followup `rUS7`) and 24 retired bare-`create <name>` tests requiring mechanical rewrite
to `instances create <name>`. Both were judged same-category existing-test-update work
rather than new-grammar work, keeping them within task 001's charter instead of spawning
additional tasks.

## Follow-up items

From `plan/followups.yaml`:

- **help.sh cross-reference** (`Bak3`, dispatch-foundation) — flagged during phase-01 task
  002 that `src/help.sh` still documented old `list`/`status`/`connect` spellings; this was
  already in scope for phase-03 task 002 and has since been **resolved** by that task's
  rewrite of `print_help()`.
- **Pre-existing `local -n` nameref bash-3.2-incompatibility** (`QyPz`/`bgCr`,
  profiles-resource) — `profiles_create()`'s preserved auto-discovery internals
  (`_cp_entries_to_json()`) use `local -n` (bash 4.3+ nameref syntax), which throws under
  macOS system bash 3.2 (`bin/ai-sandbox.sh`'s shebang target). Harmlessly swallowed in the
  smoke-tested empty-array case, but would silently produce empty skills/hooks/agents JSON
  for a profile with real discoverable entries. Pre-existing, explicitly out of scope for
  the tasks that touched this file, **not fixed** — still tracked as a latent bug.
- **Stale `NO_CHROMIUM`/`NO_DOCKER`/`ENABLE_DOCKER_PROXY` globals list** (`PVKp`,
  docs-and-help) — `docs/architecture.md` step 1 still lists these as globals populated by
  `options.sh`, but these flags were removed in the restructure (now error with a redirect
  message). Pre-existing, unrelated to the tasks' scoped surface, **not fixed** — worth a
  separate follow-up task.
- **Missing `up` word in per-instance enumerations** (`cfdc`, docs-and-help) —
  `src/help.sh`'s per-instance commands list and `docs/architecture.md`'s step-11
  dispatch-word enumeration both omit the `up` word (present in `PER_INSTANCE_COMMANDS`).
  Pre-existing gap predating the CLI restructure entirely, **not fixed** — out of the
  documenting tasks' named scope.
- **`new_profile()` test failures** (`3P8o`, test-coverage) — confirmed non-issue: the 2
  remaining `new_profile()` test failures noted after phase-04 task 001 were already known
  to be covered by task 002's scope (renamed to `profiles_create()` in phase-02), and were
  in fact resolved by that task.
