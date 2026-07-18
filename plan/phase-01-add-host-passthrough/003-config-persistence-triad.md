# Task: Wire Add-Host Into Config-Persistence Triad And Close LAN/Host-Ports Gap

## Purpose and scope

Two related, same-surface changes to ai-sandbox's config-persistence machinery:

**(A) Full triad participation for `--add-host`.** Wire the `CLI_ADD_HOST` array
(task 001) through the complete config-persistence triad exactly as
`--allow-egress` is wired, so an `--add-host` value survives `start`/restore and
routes through the `running_config_matches()` consent gate (no silent recreate
of a running container without a prompt). See the
[config-persistence decision](../notes/config-persistence-decision.md).

**(B) Close the pre-existing `yS0R` gap.** `AI_SANDBOX_LAN_CIDR` and
`AI_SANDBOX_HOST_LISTEN_PORTS` are recomputed from live host state every
invocation and passed to the container via `environment:` only — they get no
`ai.sandbox.*` label and are absent from `running_config_matches()`'s comparison
set. That means host-state drift (a WiFi switch, a background process opening a
port) can silently recreate a running `lan-access`/`host-access` container with
no consent prompt, violating the project's "no silent recreate without consent"
principle. Route both values through the consent gate (label + comparison). This
is followup `yS0R`; the user directed it be folded into this plan.

Both changes touch the same files (`docker/docker-compose.yaml` labels/env,
`src/utils.sh` `running_config_matches()`), so they are one task to avoid two
agents editing `running_config_matches()`'s format string concurrently.

## Requirements

### Part A — `--add-host` triad wiring

Mirror the `--allow-egress` precedent at every site. The persisted value is the
CLI array itself (`--add-host` has no profile-level equivalent to merge, exactly
like `--allow-egress`).

1. **`src/index.sh` — derive the JSON and env forms.** Add an
   `_cli_add_host_json` computed once alongside `_cli_allow_egress_json`
   (lines ~199-203): `[]` when `CLI_ADD_HOST` is empty, else the array as a JSON
   array. Add an `AI_SANDBOX_ADD_HOST` env var derived from it by `'|'`-join
   (mirror `AI_SANDBOX_ALLOW_EGRESS` at lines ~381-382) and add it to the
   `export` list at lines ~383-384.
2. **`src/index.sh` — config-input record.** Add an `add_host` field to the
   `AI_SANDBOX_CONFIG_JSON` `jq -n` record (lines ~256-271), passing
   `--argjson add_host "${_cli_add_host_json}"`. This makes it the tenth
   config-input dimension. Keep `version: 1` — it is an additive optional field,
   same reasoning already applied for `allow_egress` (8th) and
   `static_playground` (9th); update the surrounding comments (lines ~215-238,
   ~251-255) to say "ten config-input dimensions" and name `add_host` as the
   tenth.
3. **`docker/docker-compose.yaml` — env + label.** Add
   `AI_SANDBOX_ADD_HOST=${AI_SANDBOX_ADD_HOST:-}` to **both** the `ai-sandbox`
   service `environment:` block (near line ~132) and the firewall-init sidecar
   `environment:` block (near line ~207) — keep the two blocks in sync as the
   existing comments instruct. Add an `ai.sandbox.add-host:
   "${AI_SANDBOX_ADD_HOST:-}"` label to the `labels:` block (near line ~76,
   beside `ai.sandbox.allow-egress`), with a comment mirroring the
   allow-egress label comment.
   - **Note:** whether the sidecar actually needs `AI_SANDBOX_ADD_HOST` depends
     on task 004 (host-access-visibility) — the sidecar runs
     `docker/init-firewall.sh`. Adding it to both blocks is the safe, precedent-
     matching default (allow-egress is in both); keep them in sync.
4. **`src/utils.sh` — `restore_saved_config()`.** Add `saved_add_host` decoding
   (mirror `saved_allow_egress`, line ~530), then a validation-and-rehydrate
   block (mirror lines ~613-632) that re-validates each restored spec with
   `is_valid_add_host_spec()` (task 001), warns-and-drops invalid entries, and
   sets `CLI_ADD_HOST` from the validated set. Add `CLI_ADD_HOST` to the
   function's `# shellcheck disable=SC2034` globals comment and the
   local-declarations line (~490), mirroring `CLI_ALLOW_EGRESS`.
5. **`src/utils.sh` — `running_config_matches()`.** Add
   `ai.sandbox.add-host` to the multi-field `docker inspect` format string
   (`fmt`, line ~681), add a `cur_add_host` field to the `IFS` read
   (lines ~683-685) and its local declaration (line ~666), and add the
   comparison `[ "${cur_add_host:-}" = "${AI_SANDBOX_ADD_HOST:-}" ] || return 1`
   in the comparison block (lines ~687-697). Update the header comment
   (lines ~645-662) to include `AI_SANDBOX_ADD_HOST`.

### Part B — close the `yS0R` gap (LAN_CIDR + HOST_LISTEN_PORTS)

These two are **host-detected**, recomputed every run (not CLI inputs), so they
do **not** go into the `ai.sandbox.config` JSON record and are **not** rehydrated
by `restore_saved_config()` — they are freshly recomputed each invocation
(`src/index.sh` lines ~396-400 for `AI_SANDBOX_LAN_CIDR`, ~551-573 for
`AI_SANDBOX_HOST_LISTEN_PORTS`). Their triad participation is label + comparison
only:

6. **`docker/docker-compose.yaml` — labels.** Add
   `ai.sandbox.lan-cidr: "${AI_SANDBOX_LAN_CIDR:-}"` and
   `ai.sandbox.host-listen-ports: "${AI_SANDBOX_HOST_LISTEN_PORTS:-}"` to the
   `labels:` block, each with a short comment noting they capture host-detected
   state at create/start time (the `environment:` entries already exist at
   lines ~141, ~159, ~215-216).
7. **`src/utils.sh` — `running_config_matches()`.** Add both labels to `fmt`,
   read into `cur_lan_cidr` / `cur_host_ports` locals, and add
   `[ "${cur_lan_cidr:-}" = "${AI_SANDBOX_LAN_CIDR:-}" ] || return 1` and
   `[ "${cur_host_ports:-}" = "${AI_SANDBOX_HOST_LISTEN_PORTS:-}" ] || return 1`.
   **Consequence (intended):** when host state drifts between two `start`
   invocations (new listening port, changed LAN), `running_config_matches()` now
   returns 1, so the caller's existing consent prompt fires before recreating —
   exactly reading (a) of followup `yS0R`, upholding "no silent recreate without
   consent." Document this intended behavior in a code comment so it is not later
   mistaken for a bug. (These values are empty when the corresponding capability
   is inactive, so the comparison is a no-op `"" = ""` for containers without
   `lan-access`/`host-access`.)

### Part C — followup `WjsY` comment fix (trivial, same surface)

8. **`src/status.sh` line ~48.** Update the stale comment that says "seven-field
   config record" to reflect the current field count (now ten with `add_host`).
   Word it as "config record" without a brittle hardcoded count if that reads
   more cleanly, or use the correct current count. This closes followup `WjsY`.

### Housekeeping

9. **Rebuild the rollup** (`make build`) after all `src/` edits.
10. Do **not** edit `plan/followups.yaml` — removing `yS0R`/`WjsY` is the
    manager's job via `apply-task-report` once this task lands.

## Validation

- `make lint` passes.
- `make build` regenerates `bin/ai-sandbox.sh`.
- **`--add-host` round-trip (manual or task-005 automated):** create a container
  with `--add-host myhost:10.0.0.5`; confirm the `ai.sandbox.add-host` label and
  `ai.sandbox.config` JSON (`.add_host`) carry the value; a subsequent
  per-instance command with no flags rehydrates `CLI_ADD_HOST` from the label
  (via `restore_saved_config()`) and `running_config_matches()` returns 0
  (match) — no spurious recreate prompt.
- **Drift detection:** with the same container running, invoking `start` while
  passing a *different* `--add-host` value makes `running_config_matches()`
  return 1 (mismatch → consent prompt), like `--allow-egress`.
- **`yS0R`:** for a `host-access`/`lan-access` container, changing the host's
  listening ports (or simulating a different `AI_SANDBOX_HOST_LISTEN_PORTS`/
  `AI_SANDBOX_LAN_CIDR`) between the captured label and the recomputed value
  makes `running_config_matches()` return 1 (was previously an undetected silent
  recreate). Confirm the empty-value / capability-inactive case still returns 0.
- `docker compose ... config` renders valid YAML with the three new labels.

## Metadata

architectural_impact: true

(Adds significant tracked state — a new persisted config-input field plus three
new `ai.sandbox.*` labels — and changes the documented config-persistence
consent-gate behavior in `docs/architecture.md`.)

## References

- `src/index.sh` lines ~199-203 (`_cli_allow_egress_json`), ~215-274 (config
  JSON record), ~370-400 (`AI_SANDBOX_ALLOW_EGRESS`/`AI_SANDBOX_LAN_CIDR`
  derivation + export), ~551-573 (`AI_SANDBOX_HOST_LISTEN_PORTS`).
- `src/utils.sh` lines ~486-641 (`restore_saved_config()`), ~645-699
  (`running_config_matches()`), ~389-401 (`is_valid_allow_egress_spec()` pattern
  for the `is_valid_add_host_spec()` reuse).
- `docker/docker-compose.yaml` lines ~52-91 (labels), ~118-163 (ai-sandbox
  env), ~196-217 (sidecar env).
- `src/status.sh` line ~48 (`WjsY` stale comment).
- Followup `yS0R` (LAN/host values missing from config-persist) and `WjsY`
  (stale field-count comment) in `plan/followups.yaml`.
- `docs/architecture.md` §"Config persistence and restore" (~524-634) and the
  host-env-passthrough section (~315-330) — background, updated by doc-updates.
</content>
