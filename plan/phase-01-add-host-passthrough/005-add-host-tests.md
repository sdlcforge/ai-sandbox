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
</content>
