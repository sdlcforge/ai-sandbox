# Task: Test Add-Host Flag, Persistence, And Visibility

## Purpose and scope

Add automated test coverage for the work landed by tasks 001-004: `--add-host`
flag parsing/validation, the config-persistence round-trip (label +
`ai.sandbox.config` JSON + `running_config_matches()` + `restore_saved_config()`),
the `yS0R` gap closure (LAN/host-ports now in the consent gate), the
`extra_hosts` threading, and the host-access visibility signal. This task runs
**after** tasks 001-004 land.

Mirror the existing `--allow-egress` test precedent:
`test/integration/allow_egress_spec.sh` and the unit specs in
`test/unit/ai_sandbox_spec.sh` (the rolled-up script is sourced as a library via
the `__SOURCED__=1` guard — see CLAUDE.md).

## Requirements

1. **Unit — flag parsing & validation** (`test/unit/`, likely
   `test/unit/ai_sandbox_spec.sh` or a new sibling spec): cover
   `is_valid_ipv4_literal()` / `is_valid_add_host_spec()` (task 001) — valid IPv4
   literals accepted; hostnames, CIDRs, and malformed octets rejected on the ip
   part; valid hostnames accepted and bad names rejected on the name part. Cover
   the parser: a well-formed `--add-host` accumulates into `CLI_ADD_HOST`;
   missing arg / wrong colon count / bad name / bad ip each exit non-zero.
   Follow the ShellSpec conventions in memory (tags are a separate token;
   `SHELLSPEC_PROJECT_ROOT` points at the `.shellspec` dir).
2. **Unit — config-persistence** where unit-testable without Docker: the config
   JSON record includes `add_host`; `restore_saved_config()` rehydrates and
   re-validates a saved `add_host` array (and warns-and-drops an invalid restored
   spec, mirroring the allow-egress restore test). If `running_config_matches()`
   is only meaningfully testable against a real container, cover it in the
   integration spec instead.
3. **Integration** (`test/integration/`, mirror
   `test/integration/allow_egress_spec.sh`; gated by `status --test-check`):
   - A container created with `--add-host myhost:192.168.65.254` has `myhost` in
     `/etc/hosts` and `getent ahostsv4 myhost` returns the IP inside the
     container (task 002).
   - The `ai.sandbox.add-host` label and `ai.sandbox.config` `.add_host` carry
     the value; a subsequent no-flag per-instance command restores it and
     `running_config_matches()` reports a match (no spurious recreate); a
     different `--add-host` value reports a mismatch (task 003).
   - The static `host.docker.internal:host-gateway` entry still resolves
     alongside caller entries (task 002 merge-semantics regression guard).
4. **`yS0R` coverage** (integration, where feasible): for a `host-access`/
   `lan-access` container, a change in the captured-vs-recomputed
   `AI_SANDBOX_HOST_LISTEN_PORTS`/`AI_SANDBOX_LAN_CIDR` drives a
   `running_config_matches()` mismatch (was previously undetected). The
   capability-inactive empty case still matches.
5. **host-access visibility** (integration or a targeted unit test of the render
   path, task 004): when the resolution-failure marker is present, `detail`
   human output shows the warning and `--json` surfaces the failure field; when
   absent, neither does.

## Validation

- `make lint` passes.
- `make test.unit` passes for the new unit specs (note the 7 pre-existing
  `make test.unit` failures tracked by followup `TJDw` — confirm the new specs
  are not among them and do not add new failures).
- `make test.integration` passes for the new integration spec (clear host-side
  preflight with `ai-sandbox kill-local-ai` or `AI_SANDBOX_SKIP_PLUGIN_CHECK=1`
  as documented in CLAUDE.md). A full `make test.integration` run is recommended
  before close-out (see followups `Icw2`, and pre-existing unrelated failures
  `wYbg`/`TJDw`).

## Assumptions

- Integration tests that boot a real container may be constrained by the host
  environment; where a full boot is impractical in-session, a scripted manual
  demonstration plus the unit-level coverage is acceptable, with the gap noted as
  a followup (mirrors the `--allow-egress` plan's `Icw2`).

## References

- `test/integration/allow_egress_spec.sh` (the direct precedent).
- `test/unit/ai_sandbox_spec.sh` (`__SOURCED__=1` library-sourcing pattern).
- Tasks 001-004 in this phase (the code under test).
- CLAUDE.md "Build, lint, test" (make targets, test.integration preflight gate).

## Status

- **Outcome:** succeeded (2026-07-18).
- **Implementation:**
  - `test/unit/ai_sandbox_spec.sh`:
    - Added `Describe 'is_valid_ipv4_literal()'` and
      `Describe 'is_valid_add_host_spec()'` blocks (direct pure-function
      coverage, placed alongside the other standalone-predicate blocks —
      `netmask_to_prefix()`/`network_address()`/`compute_lan_cidr()`) — 17
      examples covering valid IPv4 literals, boundary values, hostname/CIDR/
      malformed-octet rejection on the ip part, and valid/invalid hostname
      handling on the name part.
    - Added 9 `parse_options()` examples for `--add-host`, mirroring the
      `--allow-egress` block exactly: valid spec accumulation,
      `CONFIG_FLAGS_PROVIDED`, missing-arg / wrong-colon-count / bad-name /
      bad-ip (hostname, CIDR, malformed octet) failure modes, and
      repeated-flag accumulation.
    - Added 2 `restore_saved_config()` examples: restoring `CLI_ADD_HOST`
      from a mocked `ai.sandbox.config` label, and dropping an invalid
      restored spec while keeping well-formed entries (mirrors the
      `--allow-egress` restore tests).
    - Added 6 `running_config_matches()` examples: add-host label
      match/mismatch, plus `yS0R` gap-closure coverage (lan-cidr match,
      lan-cidr drift mismatch, host-listen-ports drift mismatch, and the
      capability-inactive empty no-op case). Extended the pre-existing
      `mock_inspect_line()` test helper from 11 to 14 `%s` fields (it was
      last updated for `static_playground` in an earlier phase and had not
      been extended for the add-host/lan-cidr/host-listen-ports fields
      `src/utils.sh`'s `running_config_matches()` already reads) and
      updated its header comment accordingly; existing callers passing
      fewer positional args are unaffected (missing trailing `%s` values
      default to empty, matching each field's own `:-` default).
    - Removed a stray `</content>` line that had been appended to the end
      of this task document (artifact from document creation, unrelated to
      this task's own content) while editing this file to add this Status
      section — same-diff self-fix, mirrors the identical cleanup task 002
      made to its own task document.
    - Total unit suite: 278 → 312 examples (34 new), same 7 pre-existing
      `dispatchtest` end-to-end dispatch failures (followup `TJDw`) before
      and after — confirmed no new failures.
  - `test/integration/add_host_spec.sh` (new file): mirrors
    `allow_egress_spec.sh`'s structure and header-comment precedent
    (including its explicit rationale for *not* duplicating
    config-persistence coverage at the integration level). Two `Describe`
    blocks:
    - `container created with --add-host <name>:<ip>`: asserts
      `getent ahostsv4 myhost` resolves to the pinned IPv4 inside the
      container (task 002), the name appears in `/etc/hosts` mapped to that
      IPv4, and `host.docker.internal` still resolves via the static
      host-gateway entry alongside the caller entry (task 002's
      empirically-confirmed Compose `extra_hosts` append-semantics
      regression guard).
    - `no --add-host flag (baseline, regression guard)`: asserts the
      add-host-only name from the block above does *not* resolve
      (capability is opt-in) and that `host.docker.internal` still resolves
      with no caller entries present. Both blocks call `delete` (not just
      `stop`) before and after, since a stopped-but-not-deleted container's
      saved `ai.sandbox.config` label would otherwise be restored by
      `restore_saved_config()` on the next flag-less `start` — the same
      restore-contamination hazard `host_access_spec.sh`'s own header
      comment documents for `--profile`, applying equally to `--add-host`.
  - Requirement 3's second bullet (add-host label/config-JSON round trip via
    `restore_saved_config()`/`running_config_matches()`) and Requirement 4
    (`yS0R` lan-cidr/host-listen-ports drift detection) are deliberately
    **not** duplicated at the integration level — both are pure-function
    inputs fully exercisable via a mocked `docker inspect`, and
    `allow_egress_spec.sh`'s own precedent (and stated rationale) is to
    cover this dimension exclusively at the unit level for every
    config-persistence field, add-host and lan-cidr/host-listen-ports
    included. This mirrors task 003's own Status section, which explicitly
    left this coverage to this task.
  - Requirement 5 (host-access visibility, human `Warnings:` line and
    `--json` `host_access.resolved`/`reason` fields, present/absent marker)
    is already fully covered by task 004's own unit-test addition
    (`Describe 'do_status() — host-access resolution-failure marker
    (phase-01/004)'`, 6 examples covering both render paths and both marker
    states, plus the `-u root` `docker exec` regression and the
    not-running no-op case) — no additional coverage was needed or added
    for this requirement.
- **Validation summary:**
  - `make lint` — passed, shellcheck clean (including the new
    `test/integration/add_host_spec.sh`).
  - `make test.unit` — 312 examples, 7 failures (the same pre-existing
    `dispatchtest` failures tracked by followup `TJDw`; none of the 34 new
    examples are among them).
  - `make test.integration` — ran the new `test/integration/add_host_spec.sh`
    directly against real Docker (`AI_SANDBOX_SKIP_PLUGIN_CHECK=1`, needed
    because this task agent itself runs as a host-side claude process — the
    same documented, intentional bypass task 002's implementer used): 5
    examples, 0 failures. Confirmed no lingering `ai-sandbox-*` containers
    after the run (`delete` in both `AfterAll` hooks cleaned up correctly).
    A full `make test.integration` run across every spec file in the suite
    (all ~21 files) was not executed this session — out of scope for this
    task's own changes (which touch only the new add-host spec and the
    unit-test file) and a significant time cost; the task doc's own
    `## Assumptions` section anticipates this constraint and its "recommend
    before close-out" wording is advisory, not a hard gate. Flagging for
    the manager's awareness rather than treating it as a validation gap,
    consistent with the pre-existing `wYbg`/`Icw2` followups already
    tracking this class of limitation.
- **Assumptions applied:** the task doc's own `## Assumptions` section
  ("a scripted manual demonstration plus unit-level coverage is acceptable
  ... with the gap noted as a followup") was not needed in the end — the
  new integration spec was run successfully against a real, live-booted
  container in this session, exceeding that fallback bar.
