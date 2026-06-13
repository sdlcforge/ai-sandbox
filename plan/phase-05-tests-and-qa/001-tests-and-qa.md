# Task 001: Update Unit Tests and QA Gate

**Phase:** 5 — Tests and QA Gate
**Tier:** sonnet-high

## Purpose and scope

Update `test/unit/ai_sandbox_spec.sh` to reflect all the changes from Phases 1–4, and run the full QA gate (`make build && make lint && make test.unit`). This task runs last, after all prior phases have merged.

The unit test file currently has 61 examples. The goal is:
- All existing tests still pass (updated to match new behavior where the API changed)
- New tests for `parse_options()` covering the two-tier CLI shape
- New tests for `sandbox_container_name()`
- New tests for `list_instances()` (mocked docker)
- Updated tests for `create_profile()` → `new_profile()`
- Updated tests for container-name-sensitive functions (`is_container_running`, `_ssh_mount_is_fresh`, `cleanup_stale_container`)

## Requirements

### `test/unit/ai_sandbox_spec.sh`

All changes are to this single file. `make build` must run first to regenerate `bin/ai-sandbox.sh` from the updated sources.

#### Update `parse_options()` tests

The existing tests in `Describe 'parse_options()'` test the old single-tier parsing. Replace/update them for the new two-tier shape:

**Tests to remove or rewrite:**
- `'leaves PROFILES empty by default'` — rewrite: bare invocation sets `CMD=list` and empty `SANDBOX_NAME`
- `'accumulates repeated --profile flags in order'` — these now apply to `create` context; rewrite to test `parse_options create foo --profile base --profile docker`
- `'sets MODE_OVERRIDE from --mode'` — rewrite to test in create context: `parse_options create foo --mode static`
- `'rejects an invalid --mode value'` — keep but update invocation
- Deprecated flag tests (`--docker`, `--no-docker`, `--no-chromium`) — keep these; the deprecation errors should still fire

**Tests to add:**
```bash
It 'routes first arg to SANDBOX_NAME when not a global command'
  When call parse_options mybox stop
  The variable SANDBOX_NAME should eq mybox
  The variable CMD should eq stop
End

It 'sets CMD to enter when sandbox name given with no command'
  When call parse_options mybox
  The variable SANDBOX_NAME should eq mybox
  The variable CMD should eq enter
End

It 'routes create to CMD with sandbox name in SANDBOX_NAME'
  When call parse_options create mybox --profile base
  The variable CMD should eq create
  The variable SANDBOX_NAME should eq mybox
  The variable "PROFILES[*]" should eq base
End

It 'sets ENTER_AFTER_CREATE from --enter on create'
  When call parse_options create mybox --enter
  The variable ENTER_AFTER_CREATE should eq true
End

It 'routes list to CMD with empty SANDBOX_NAME'
  When call parse_options list
  The variable CMD should eq list
  The variable SANDBOX_NAME should eq ''
End

It 'defaults CMD to list on bare invocation'
  When call parse_options
  The variable CMD should eq list
  The variable SANDBOX_NAME should eq ''
End

It 'rejects reserved names as sandbox names'
  When run parse_options create
  The status should be failure
  The stderr should include 'reserved'
End
```

#### Add `sandbox_container_name()` tests

```bash
Describe 'sandbox_container_name()'
  It 'returns ai-sandbox-<name> for the current SANDBOX_NAME'
    SANDBOX_NAME=mybox
    When call sandbox_container_name
    The output should eq 'ai-sandbox-mybox'
  End

  It 'returns ai-sandbox- when SANDBOX_NAME is empty'
    SANDBOX_NAME=
    When call sandbox_container_name
    The output should eq 'ai-sandbox-'
  End
End
```

#### Update container-name-sensitive tests

The existing tests for `is_container_running`, `_ssh_mount_is_fresh`, `cleanup_stale_container`, and `warn_if_ssh_mount_stale` mock `docker inspect ai-sandbox ...`. After Phase 2, these functions use `sandbox_container_name`, so tests must set `SANDBOX_NAME` and mock the namespaced container name.

For each such test, add a `Before` setup that sets `SANDBOX_NAME=test` (or use an inline `SANDBOX_NAME=test`). The mock `docker()` function already handles `inspect` by return value, so no change to the mock is needed — just ensure `SANDBOX_NAME` is set so the function doesn't call `docker inspect ai-sandbox-` (empty name).

Example update for `_ssh_mount_is_fresh()`:
```bash
Describe '_ssh_mount_is_fresh()'
  setup() { SANDBOX_NAME=test; export SSH_AUTH_SOCK="/tmp/agent.sock"; }
  Before 'setup'
  # ... rest of tests unchanged (docker() mock doesn't care about container name)
End
```

#### Update `create_profile()` → `new_profile()` tests

The `Describe 'create_profile()'` block must be renamed to `Describe 'new_profile()'` and all `When call create_profile` → `When call new_profile`. Error messages from the function have changed (`create-profile` → `new-profile` in the text), so update the `should include` assertions accordingly.

#### Add `list_instances()` tests (optional, if time permits)

```bash
Describe 'list_instances()'
  It 'emits rows for managed containers'
    docker() {
      if [ "$1" = "ps" ]; then
        printf 'foo\trunning\tbase,docker\n'
        printf 'bar\texited\tbase\n'
        return 0
      fi
    }
    When call list_instances
    The output should include 'foo'
    The output should include 'bar'
    The status should be success
  End

  It 'emits nothing when no managed containers exist'
    docker() { return 0; }
    When call list_instances
    The output should eq ''
    The status should be success
  End
End
```

### QA gate

After all test edits, the agent must run the full QA gate and report the result:

```bash
make build
make lint
make test.unit
```

All three must pass with exit code 0. Report the total number of passing examples.

If `make test.unit` fails, diagnose and fix before reporting the task complete. Do not report the task complete with failing tests.

## Assumptions

- All prior phases (1–4) have been merged to the branch before this task runs.
- `make build` regenerates `bin/ai-sandbox.sh` from the updated `src/` modules.
- `make test.unit` runs `shellspec test/unit/ai_sandbox_spec.sh` (or equivalent).
- The integration tests (`make test.integration`) are out of scope for this task.

## References

- `test/unit/ai_sandbox_spec.sh` — the only file to modify
- `bin/ai-sandbox.sh` — regenerated by `make build`; tests include this
- CLAUDE.md ShellSpec notes: tags are separate tokens after the description string

## Checkpoint hints

1. Run `make build` first, before editing any tests. Some test failures may be pre-existing if prior phases have already changed function signatures.

2. Work through the test file top-to-bottom. The `parse_options()` describe block will need the most rewriting. Container-name-sensitive blocks mostly just need a `SANDBOX_NAME=test` in their setup.

3. After each logical group of changes, run `shellspec test/unit/ai_sandbox_spec.sh` to check incrementally.

4. The deprecated flag tests (`--docker`, `--no-docker`, `--no-chromium`) should still pass unchanged if those error paths are preserved in `parse_options()`.

## Validation

```bash
make build    # must exit 0
make lint     # must exit 0, no shellcheck errors
make test.unit  # must exit 0, all examples pass
```

Report the final example count and confirm all pass.

## Status

**outcome:** succeeded
**date:** 2026-06-12
**validation summary:** All three QA gates passed. `make build` exit 0; `make lint` exit 0 (no shellcheck errors); `make test.unit` exit 0 — 73 examples, 0 failures.

**affected source files:**
- `test/unit/ai_sandbox_spec.sh`

**decisions made:**
- `'rejects reserved names as sandbox names'` test uses `parse_options status` (not `parse_options create` as the task doc draft suggested); `create` is a global command so it never routes through the per-instance reserved-name check — `status` is in RESERVED_NAMES but not GLOBAL_COMMANDS and correctly triggers the error.
- The `warn_if_ssh_mount_stale` stale-warning test asserts `should include 'fix-ssh'` rather than `'ai-sandbox fix-ssh'` because the actual message embeds the sandbox name: `'ai-sandbox test fix-ssh'`, which does not contain the literal substring `'ai-sandbox fix-ssh'`.
- Example count increased from 63 to 73 (added `sandbox_container_name` block, `list_instances` block, and new `parse_options` two-tier tests; removed two old single-tier tests).
