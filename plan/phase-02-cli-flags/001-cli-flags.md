# Phase 02 Task 001 — CLI Flags

**Tier:** `sonnet-med`
**Depends on:** Phase 01 Task 001 (profile schema and installer)
**Parallel-eligible with:** Phase 03 Task 001 (container plugin setup)

---

## Purpose and scope

Wire three new CLI flags into the `ai-sandbox` command and connect them to the profile-installer flow. This task covers the flag parser (`src/options.sh`), help text (`src/help.sh`), and the merge logic in `src/index.sh` that combines CLI-supplied marketplace/plugin values with those from the profile YAML.

No container or Docker changes happen in this task. The output of this task is that CLI values flow through to the same environment variables that Phase 03 will consume.

---

## Requirements

### 1. `src/options.sh` — flag definitions

Add the following three flags in Phase 3 of the option parser (the `case` statement around line 147, after the existing repeatable-flag block for `--profile`).

**`--add-marketplace <ref>`** (repeatable)

```bash
--add-marketplace)
    i=$(( i + 1 ))
    if [ "${i}" -ge "${#all_remaining[@]}" ]; then
        echo "Error: --add-marketplace requires a ref (https:// or file://)" 1>&2
        exit 1
    fi
    _ref="${all_remaining[${i}]}"
    case "${_ref}" in
        https://*|file://*) ;;
        *)
            echo "Error: --add-marketplace ref must start with https:// or file:// (got '${_ref}')" 1>&2
            exit 1
            ;;
    esac
    CLI_MARKETPLACES+=("${_ref}")
    CONFIG_FLAGS_PROVIDED=true
    ;;
```

**`--enable-plugin <name>`** (repeatable)

```bash
--enable-plugin)
    i=$(( i + 1 ))
    if [ "${i}" -ge "${#all_remaining[@]}" ]; then
        echo "Error: --enable-plugin requires a plugin name" 1>&2
        exit 1
    fi
    CLI_PLUGINS+=("${all_remaining[${i}]}")
    CONFIG_FLAGS_PROVIDED=true
    ;;
```

**`--enable-all`** (boolean)

```bash
--enable-all)
    CLI_ENABLE_ALL=true
    CONFIG_FLAGS_PROVIDED=true
    ;;
```

**Initialize arrays near the top of `parse_options()`**, alongside the existing `PROFILES=()` initialization:

```bash
CLI_MARKETPLACES=()
CLI_PLUGINS=()
CLI_ENABLE_ALL=false
```

**Export at the end of `parse_options()`**, alongside the existing `export` statement:

```bash
export CLI_MARKETPLACES CLI_PLUGINS CLI_ENABLE_ALL
```

Note: `CLI_MARKETPLACES` and `CLI_PLUGINS` are bash arrays. They cannot be exported as arrays across process boundaries in bash. They will be consumed within the same shell session by `src/index.sh` before any subprocess boundary is crossed — this is the same pattern used for `PROFILES`.

### 2. `src/help.sh` — documentation

Add entries for all three flags to the help text. They belong in the section that documents configuration flags (near `--profile` and `--mode`). Example wording:

```
  --add-marketplace <ref>
      Register a plugin marketplace in the container. <ref> must start with
      https:// or file://. Repeatable; each ref is registered in order.
      file:// paths are automatically bind-mounted into the container.

  --enable-plugin <name>
      Enable a named plugin from a registered marketplace. Repeatable.
      Merges with any plugins listed in the active profile(s).

  --enable-all
      Enable all plugins from the last marketplace registered via
      --add-marketplace (or the last entry in the profile's marketplaces list).
```

### 3. `src/index.sh` — CLI merge into profile data

After the profile-installer runs and `PROFILE_ENV_BLOCK` is eval'd (around line 112), the `### PROFILE_JSON ###` block is available in `PROFILE_INSTALLER_OUTPUT`. Extend the existing JSON extraction to merge CLI values.

The cleanest approach is a `jq` post-processing step that merges CLI arrays into the JSON blob:

```bash
# Extract the raw PROFILE_JSON blob
PROFILE_JSON="$(printf '%s\n' "${PROFILE_INSTALLER_OUTPUT}" \
  | awk '/^### PROFILE_JSON ###$/{f=1;next} /^###/{f=0} f{print}')"

# Merge CLI marketplace/plugin overrides into the JSON blob
if [ "${#CLI_MARKETPLACES[@]}" -gt 0 ] || [ "${#CLI_PLUGINS[@]}" -gt 0 ] || [ "${CLI_ENABLE_ALL}" = "true" ]; then
    # Build JSON arrays from bash arrays
    _cli_marketplaces_json="$(printf '%s\n' "${CLI_MARKETPLACES[@]+"${CLI_MARKETPLACES[@]}"}" \
        | jq -R . | jq -s .)"
    _cli_plugins_json="$(printf '%s\n' "${CLI_PLUGINS[@]+"${CLI_PLUGINS[@]}"}" \
        | jq -R . | jq -s .)"
    PROFILE_JSON="$(printf '%s\n' "${PROFILE_JSON}" | jq \
        --argjson cm "${_cli_marketplaces_json}" \
        --argjson cp "${_cli_plugins_json}" \
        --argjson ea "$([ "${CLI_ENABLE_ALL}" = "true" ] && echo 'true' || echo 'false')" \
        '.marketplaces = ((.marketplaces // []) + $cm | unique) |
         .plugins      = ((.plugins      // []) + $cp | unique) |
         .enable_all_plugins = ((.enable_all_plugins // false) or $ea)')"
fi

export PROFILE_JSON
```

The task agent should choose the cleanest implementation consistent with how `PROFILE_JSON` is currently handled in `src/index.sh`. If `PROFILE_JSON` is not already extracted and exported as a variable by the time Phase 03 needs it, this task should also add that extraction.

### 4. Unit tests

Add to `test/unit/ai_sandbox_spec.sh` (or the appropriate spec file for flag parsing):

- `--add-marketplace https://example.com` sets `CLI_MARKETPLACES` to contain that value.
- `--add-marketplace file:///path/to/plugin` sets `CLI_MARKETPLACES` to contain that value.
- `--add-marketplace ftp://bad` exits non-zero with an error message containing "must start with https:// or file://".
- `--add-marketplace` without a value exits non-zero.
- `--enable-plugin foo` sets `CLI_PLUGINS` to contain `foo`.
- `--enable-plugin` without a value exits non-zero.
- `--enable-all` sets `CLI_ENABLE_ALL=true`.
- Multiple `--add-marketplace` flags accumulate: `--add-marketplace A --add-marketplace B` produces `CLI_MARKETPLACES=(A B)`.

---

## Validation

The task is complete when:

- [ ] `--add-marketplace`, `--enable-plugin`, and `--enable-all` are recognized by `parse_options()`.
- [ ] `--add-marketplace` rejects refs that do not start with `https://` or `file://` with a clear error message.
- [ ] CLI values are merged into `PROFILE_JSON` (unions for lists, OR for booleans) after profile-installer runs.
- [ ] `src/help.sh` documents all three new flags.
- [ ] All new unit tests pass.
- [ ] `make build` succeeds.
- [ ] `make lint` passes (shellcheck clean, including new code in `src/options.sh` and `src/index.sh`).
