# Phase 03, Task 01 — Unit Tests and QA Gate (`--clean` + plugin-marketplace backfill)

## Context

This task writes unit tests for all new behavior introduced in Phases 01 and 02, plus backfills the plugin-marketplace Phase 04 tests that were not written in the prior session. All tests live in `test/unit/ai_sandbox_spec.sh` following the existing ShellSpec conventions.

**Dependencies:** Phase 01 and Phase 02 must be complete and `make build` must have been run so `bin/ai-sandbox.sh` includes all new code.

**Branch convention:** `phase-03-task-01-tests-and-qa`

## Existing Test Patterns to Follow

- The spec file uses `Include "$PWD/bin/ai-sandbox.sh"` — tests operate on the rolled-up binary.
- `When call <fn>` for non-fatal function calls; `When run <fn>` for calls expected to `exit`.
- `The variable "ARRAY[*]"` notation for array assertions.
- Setup/teardown via `Before 'setup'` / `After 'cleanup'` functions within `Describe` blocks.
- ShellSpec tag syntax: description string first, then tag token (e.g., `Describe 'parse_options()' unit`).
- When mocking `docker`, define a local `docker()` function inside the `It` block.

## Test Groups to Add

Add these `Describe` blocks in the order listed. Insert them **after** the existing `parse_options()` describe block (after the `--enable-all` test) and before the `is_build_stale()` describe block.

---

### Group 1: `--clean` flag parsing (new, in `parse_options()` Describe block)

Add these `It` cases inside the existing `Describe 'parse_options()'` block, after the `--enable-all` tests:

```bash
    It '--clean sets CLEAN_SLATE to true'
      When call parse_options create mybox --clean
      The variable CLEAN_SLATE should eq true
    End

    It '--clean sets CONFIG_FLAGS_PROVIDED to true'
      When call parse_options create mybox --clean
      The variable CONFIG_FLAGS_PROVIDED should eq true
    End

    It 'CLEAN_SLATE defaults to false when --clean is absent'
      When call parse_options create mybox
      The variable CLEAN_SLATE should eq false
    End

    It '--clean can be combined with --add-marketplace and --enable-all'
      When call parse_options create mybox --clean \
        --add-marketplace file:///path/to/mp --enable-all
      The variable CLEAN_SLATE should eq true
      The variable "CLI_MARKETPLACES[*]" should eq 'file:///path/to/mp'
      The variable CLI_ENABLE_ALL should eq true
    End
```

---

### Group 2: `generate_volume_override` with clean mode (new `Describe` block)

Add a new top-level `Describe` block after `parse_options()`:

```bash
  Describe 'generate_volume_override() clean-slate mode'
    setup() {
      export TMPDIR_VO="$(mktemp -d)"
      export HOME="${TMPDIR_VO}"
      export OUT="${TMPDIR_VO}/compose-override.yaml"
      unset AI_SANDBOX_MARKETPLACES
      unset AI_SANDBOX_CLEAN_SLATE
    }
    cleanup() {
      rm -rf "${TMPDIR_VO}"
    }
    Before 'setup'
    After 'cleanup'

    It 'skips plugin dir mounts when AI_SANDBOX_CLEAN_SLATE=true'
      # Plant a fake plugin dir and a fake manifest
      mkdir -p "${HOME}/.myplugin"
      mkdir -p "${HOME}/.claude/plugins"
      printf '{"plugins":{"myplugin@test":{}}}' \
        > "${HOME}/.claude/plugins/installed_plugins.json"
      export AI_SANDBOX_CLEAN_SLATE=true
      When call generate_volume_override "${OUT}"
      The contents of file "${OUT}" should not include '.myplugin'
      The status should be success
    End

    It 'still mounts file:// marketplace paths when AI_SANDBOX_CLEAN_SLATE=true'
      export AI_SANDBOX_CLEAN_SLATE=true
      export AI_SANDBOX_MARKETPLACES="file:///srv/marketplace"
      When call generate_volume_override "${OUT}"
      The contents of file "${OUT}" should include '/srv/marketplace:/srv/marketplace:ro'
      The status should be success
    End

    It 'mounts plugin dirs when AI_SANDBOX_CLEAN_SLATE is false (default behavior)'
      mkdir -p "${HOME}/.myplugin"
      mkdir -p "${HOME}/.claude/plugins"
      printf '{"plugins":{"myplugin@test":{}}}' \
        > "${HOME}/.claude/plugins/installed_plugins.json"
      export AI_SANDBOX_CLEAN_SLATE=false
      When call generate_volume_override "${OUT}"
      The contents of file "${OUT}" should include '.myplugin'
      The status should be success
    End

    It 'produces empty volumes list when clean and no marketplaces'
      export AI_SANDBOX_CLEAN_SLATE=true
      When call generate_volume_override "${OUT}"
      The contents of file "${OUT}" should include 'volumes: []'
      The status should be success
    End
  End
```

---

### Group 3: Plugin-marketplace backfill

These tests cover behavior already implemented in Phases 01-03 of the plugin-marketplace plan but were never written as unit tests.

**3a. `--add-marketplace` and `--enable-plugin` parsing** — Add these inside the existing `Describe 'parse_options()'` block (alongside the existing marketplace/plugin tests that were already written in the prior session; verify they exist before adding, to avoid duplication):

Check the spec file first. The following tests already exist per the spec file at time of planning:
- `--add-marketplace with https:// ref` (line 271)
- `--add-marketplace with file:// ref` (line 276)
- `--add-marketplace with invalid scheme` (line 281)
- `--add-marketplace given no ref` (line 287)
- `accumulates repeated --add-marketplace refs` (line 293)
- `--enable-plugin sets CLI_PLUGINS` (line 300)
- `accumulates repeated --enable-plugin names` (line 305)
- `--enable-all sets CLI_ENABLE_ALL` (line 311)

These are already present. The backfill adds any gaps — specifically tests for `--enable-plugin` with no argument, and `CLI_ENABLE_ALL` defaulting to false:

```bash
    It 'errors when --enable-plugin is given no name'
      When run parse_options create mybox --enable-plugin
      The status should be failure
      The stderr should include '--enable-plugin requires'
    End

    It 'CLI_ENABLE_ALL defaults to false when --enable-all is absent'
      When call parse_options create mybox
      The variable CLI_ENABLE_ALL should eq false
    End
```

**3b. `generate_volume_override` with `file://` marketplace** — Add inside the `generate_volume_override() clean-slate mode` Describe block above (already covered by the "still mounts file:// marketplace paths" test), or add a separate non-clean-slate group:

```bash
  Describe 'generate_volume_override() file:// marketplace mounts'
    setup() {
      export TMPDIR_MP="$(mktemp -d)"
      export HOME="${TMPDIR_MP}"
      export OUT="${TMPDIR_MP}/compose-override.yaml"
      unset AI_SANDBOX_CLEAN_SLATE
    }
    cleanup() {
      rm -rf "${TMPDIR_MP}"
    }
    Before 'setup'
    After 'cleanup'

    It 'adds a read-only bind mount for a file:// marketplace entry'
      export AI_SANDBOX_MARKETPLACES="file:///srv/my-marketplace"
      When call generate_volume_override "${OUT}"
      The contents of file "${OUT}" should include '/srv/my-marketplace:/srv/my-marketplace:ro'
      The status should be success
    End

    It 'does not add a mount for https:// marketplace entries'
      export AI_SANDBOX_MARKETPLACES="https://registry.example.com"
      When call generate_volume_override "${OUT}"
      The contents of file "${OUT}" should not include 'registry.example.com'
      The status should be success
    End

    It 'handles multiple entries when pipe-separated'
      export AI_SANDBOX_MARKETPLACES="file:///srv/mp1|https://remote.example.com|file:///srv/mp2"
      When call generate_volume_override "${OUT}"
      The contents of file "${OUT}" should include '/srv/mp1:/srv/mp1:ro'
      The contents of file "${OUT}" should include '/srv/mp2:/srv/mp2:ro'
      The contents of file "${OUT}" should not include 'remote.example.com'
      The status should be success
    End
  End
```

---

## Ordering of New Describe Blocks

The recommended final order in `test/unit/ai_sandbox_spec.sh`:

1. `check_docker()` (existing)
2. `download_tool()` (existing)
3. `profile_image_suffix()` (existing)
4. `variant_image_tag()` (existing)
5. `profile_has_capability()` (existing)
6. `ensure_image()` (existing)
7. `sandbox_container_name()` (existing)
8. `parse_options()` (existing, with new `--clean` cases and `--enable-plugin`/`CLI_ENABLE_ALL` backfill added inside)
9. `generate_volume_override() clean-slate mode` (new)
10. `generate_volume_override() file:// marketplace mounts` (new)
11. `is_build_stale()` (existing)
12. `_ssh_mount_is_fresh()` (existing)
13. `warn_if_ssh_mount_stale()` (existing)
14. `new_profile()` (existing)
15. `cleanup_stale_container()` (existing)
16. `list_instances()` (existing)

---

## QA Gate

After writing all tests, run the full QA sequence and confirm all three commands exit 0:

```bash
make build
make lint
make test.unit
```

If any `shellcheck` warning fires in `test/unit/ai_sandbox_spec.sh` due to the new tests (e.g., SC2034 for a variable used only inside ShellSpec), add the appropriate inline disable comment with explanation, following the convention in the existing spec file header.

## Notes

- `generate_volume_override` tests must set `HOME` to a tmpdir to avoid reading the actual host `~/.claude/plugins/installed_plugins.json` manifest, which would make tests non-reproducible.
- The `AI_SANDBOX_MARKETPLACES` env var uses pipe (`|`) as separator, not colon — match this exactly in test setup.
- `list_installed_plugins` reads `${HOME}/.claude/plugins/installed_plugins.json` with `jq`. Tests that plant fake manifests must use valid JSON (`{"plugins":{"name@marketplace":{}}}`).
- Do not add integration-tagged tests here. All new tests are pure unit tests exercising bash functions in process.
- The `--enable-plugin` no-arg error test is a gap in the existing plugin-marketplace work — the implementation exits 1 with an error message but no unit test covers this path. Add it.
