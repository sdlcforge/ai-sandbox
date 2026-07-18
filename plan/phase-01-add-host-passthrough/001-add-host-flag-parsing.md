# Task: Add-Host Flag Parsing And Validation

## Purpose and scope

Add a repeatable `--add-host <name>:<ip>` CLI flag to `ai-sandbox`, parsed and
validated in `src/options.sh`, that lets a caller pin a fixed host→IPv4 mapping
into the container. This task owns **only** flag parsing, validation, and
exposing the parsed values as a `CLI_ADD_HOST` bash array to downstream phases;
threading the values into `extra_hosts` (task 002) and config persistence
(task 003) are separate tasks that consume this array.

The flag is the V1 mechanism for stable host-IPv4 reachability, robust to Docker
Desktop's variable `host.docker.internal` resolution — the caller supplies the
IP, so ai-sandbox never has to detect or resolve it. See
[investigation findings](../notes/investigation-findings.md) and the
[direction decision](../notes/direction-decision.md).

Model the flag's shape **exactly** on the existing `--allow-egress` flag
(`src/options.sh` lines ~506-538), which is the established repeatable-flag /
`CLI_*` array / `src/utils.sh` validation-helper precedent.

## Requirements

1. **Parse `--add-host <name>:<ip>`** in `src/options.sh`'s option loop, as a new
   `case` arm alongside `--allow-egress`. The flag:
   - Takes one argument, a spec of the form `<name>:<ip>` (exactly one `:`).
   - Is repeatable — each occurrence appends one spec to a `CLI_ADD_HOST` bash
     array (mirror `CLI_ALLOW_EGRESS+=(...)`).
   - Sets `CONFIG_FLAGS_PROVIDED=true`.
   - Emits a clear, per-failure-mode error to stderr and `exit 1` when the
     argument is missing, has the wrong colon count, or fails validation — match
     the message style of the `--allow-egress` arm.
2. **Validate the spec.** Split on the single `:` into `<name>` and `<ip>`:
   - `<name>` must be a valid hostname. Reuse `is_valid_egress_hostname()`
     (`src/utils.sh`) — it already enforces the `^[A-Za-z0-9.-]+$` shape the
     project uses for host-part names. (Note: followup `sakY` observes this
     regex permits a leading `-`; that is a pre-existing, separately-tracked
     concern — do **not** expand scope to fix it here, but do not regress it
     either.)
   - `<ip>` must be an **IPv4 literal** (e.g. `192.168.65.254`). Add a
     `is_valid_ipv4_literal()` helper to `src/utils.sh` if one does not already
     exist as a standalone (note: `is_valid_egress_host()` accepts IPv4 *or*
     CIDR *or* hostname, which is too permissive here — `--add-host` requires a
     bare IPv4 literal specifically, no CIDR, no hostname). Check whether the
     `--allow-egress` machinery already exposes a reusable pure-IPv4-literal
     predicate (`is_valid_ipv4_cidr()` / the internals of `is_valid_egress_host()`
     in `src/utils.sh` lines ~356-401); factor out or reuse rather than
     duplicating the octet-range logic.
3. **Add an `is_valid_add_host_spec()` convenience wrapper** to `src/utils.sh`
   (mirroring `is_valid_allow_egress_spec()`, lines ~389-401): validates a full
   `<name>:<ip>` spec by splitting into host/ip parts and applying the two checks
   above. This wrapper is the single source of truth reused by
   `restore_saved_config()`'s defense-in-depth re-validation in task 003, so it
   must apply byte-for-byte the same rules as the parser — exactly the
   `is_valid_egress_*` sharing pattern (see the comment at `src/options.sh`
   ~524-528).
4. **Export `CLI_ADD_HOST`** in both `src/options.sh` export lists (the two
   `export ...` statements at lines ~237-239 and ~645-647 that already carry
   `CLI_ALLOW_EGRESS`). Add the note that `CLI_ADD_HOST`, like the other `CLI_*`
   arrays, is a bash array serialized across the sourced-options boundary the
   same way `CLI_ALLOW_EGRESS` is (see the comment at `src/options.sh` ~640).
   Also initialize `CLI_ADD_HOST=()` alongside the other `CLI_*=()`
   initializations (line ~165) and add it to the documented globals comment
   block (lines ~39-51).
5. **Rebuild the rollup.** Run `make build` after editing `src/` — never edit
   `bin/ai-sandbox.sh` directly (see CLAUDE.md).

## Validation

- `make lint` passes (shellcheck clean; any `disable` carries an inline reason).
- `make build` regenerates `bin/ai-sandbox.sh` with no manual edits to the
  rollup.
- Manual smoke checks:
  - `./bin/ai-sandbox.sh <cmd> --add-host host.docker.internal:192.168.65.254`
    parses without error (with a downstream command that reaches the parse
    phase); a second `--add-host other:10.0.0.5` accumulates both specs.
  - `--add-host` with no argument, with a missing/extra colon, with a
    non-hostname name, with a non-IPv4 ip (hostname, CIDR, or malformed octet)
    each fail with a distinct stderr message and exit 1.
- Unit-test authoring is task 005's responsibility; this task need only leave the
  parser and helpers testable (pure functions in `src/utils.sh`).

## Metadata

architectural_impact: true

(Introduces a new public CLI flag — a component-boundary/API surface.)

## References

- `src/options.sh` lines ~506-538 (`--allow-egress` case), ~155-165
  (initialization), ~237-239 and ~640-647 (export lists), ~39-51 (globals doc
  comment).
- `src/utils.sh` lines ~297-401 (`is_valid_egress_hostname()`,
  `is_valid_egress_host()`, `is_valid_egress_port()`, `is_valid_ipv4_cidr()`,
  `is_valid_allow_egress_spec()`).
- [investigation findings](../notes/investigation-findings.md) — why a
  caller-pinned literal (not a detected/resolved value) is the robust contract.

## Status

- Outcome: **succeeded**
- Date: 2026-07-18
- Implementation:
  - `src/utils.sh`: added `is_valid_add_host_spec()` (mirrors
    `is_valid_allow_egress_spec()`), reusing the pre-existing standalone
    `is_valid_ipv4_literal()` predicate (already present at ~line 312, so no
    new IPv4-literal helper needed) and `is_valid_egress_hostname()`.
  - `src/options.sh`: added a `--add-host` case arm (modeled on
    `--allow-egress`) that requires exactly one `:`, validates the name part
    with `is_valid_egress_hostname()` and the ip part with
    `is_valid_ipv4_literal()`, appends to `CLI_ADD_HOST`, and sets
    `CONFIG_FLAGS_PROVIDED=true`. Initialized `CLI_ADD_HOST=()` alongside the
    other `CLI_*` arrays, added it to both export lists (`--help` early
    return and the final export), and documented it in the globals comment
    block.
  - Ran `make build` to regenerate `bin/ai-sandbox.sh` (gitignored build
    artifact; no manual edits).
- Validation summary:
  - `make lint`: passed, shellcheck clean, no new disables needed.
  - `make build`: passed, rollup regenerated cleanly.
  - Manual smoke checks (`parse_options` sourced directly): happy path with
    two `--add-host` specs accumulates both into `CLI_ADD_HOST`; missing
    argument, missing colon, extra colon, non-hostname name, and
    non-IPv4 ip (hostname/CIDR/malformed octet) each produced a distinct
    stderr message and exited 1 — all passed.
- Notes: the pre-existing `is_valid_egress_hostname()` regex permits a
  leading `-` in the name part (followup `sakY`); per the task doc, this was
  left unchanged (verified via manual check — leading-hyphen names are still
  accepted, not regressed, not fixed).
</content>
