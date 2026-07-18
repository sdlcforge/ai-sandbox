# Task: Update Architecture Docs

## Purpose and scope

Update the architecture and spec docs to reflect the changes planned in this
session (the `--add-host` flag, its config-persistence wiring, the closed `yS0R`
config-persistence gap, and the `host-access` visibility hardening). This task
runs **after** the Phase 1 implementation tasks land, and documents their
as-built behavior — including the downstream-automation-consumer contract Flow
needs.

Run the [`update-architecture-docs`](../../../../sdlcforge/flow/plugins/flow/task-procedures/update-architecture-docs/SKILL.md)
task-procedure at
`plugins/flow/task-procedures/update-architecture-docs/SKILL.md`.

## Requirements

### Implementation task documents that surfaced the architectural implications

These Phase 1 task docs (all marked `architectural_impact: true`) will be
complete by the time this task runs; they are the source of the changes to
document:

- `plan/phase-01-add-host-passthrough/001-add-host-flag-parsing.md` — new
  `--add-host <name>:<ip>` public CLI flag.
- `plan/phase-01-add-host-passthrough/002-thread-add-host-extra-hosts.md` —
  container `extra_hosts` threading (container↔host resolution topology).
- `plan/phase-01-add-host-passthrough/003-config-persistence-triad.md` — new
  persisted `add_host` config-input field + three new `ai.sandbox.*` labels
  (`add-host`, `lan-cidr`, `host-listen-ports`) and their `running_config_matches`
  consent-gate participation (closes followup `yS0R`).
- `plan/phase-01-add-host-passthrough/004-host-access-visibility.md` — new
  firewall-init → status-output diagnostic signal for host-access resolution
  failure.

### Architecture and spec files to review and update

- **`docs/architecture.md`:**
  - §"Config persistence and restore" (~lines 524-634): add `add_host` as a
    persisted CLI-input config field (now the tenth dimension); document that
    `ai.sandbox.add-host`, `ai.sandbox.lan-cidr`, and `ai.sandbox.host-listen-ports`
    are now in `running_config_matches`'s comparison set — and that the latter
    two are host-detected values, so host-state drift now routes through the
    consent gate instead of silently recreating (the `yS0R` resolution).
  - The host-env-passthrough section (~lines 315-330): note `AI_SANDBOX_ADD_HOST`
    alongside `AI_SANDBOX_ALLOW_EGRESS`/`AI_SANDBOX_LAN_CIDR`/
    `AI_SANDBOX_HOST_LISTEN_PORTS`.
  - The capabilities / firewall discussion (~lines 294+): document the
    host-access resolution-failure visibility signal and the marker's data flow
    over the firewall-handshake volume.
- **`docs/ai-sandbox-profiles-spec.md`** (discovered via `docs/*-spec.md`):
  - Document the `--add-host <name>:<ip>` flag, its validation contract
    (hostname name, IPv4-literal ip, repeatable), and its persistence behavior.
  - Document the **downstream-automation-consumer contract** explicitly: how a
    caller (e.g. Flow's flow-run-optimizer) pins a stable host IPv4, and the
    **name-resolution-vs-egress-allowance coupling** — under the default-deny
    firewall, pinning a name with `--add-host` makes it *resolve* but does not by
    itself grant *egress*; the caller must compose it with the `host-access`
    capability (when the name is `host.docker.internal` and the target is a
    host-listening TCP port) or `--allow-egress <ip>:<port>` to actually reach it
    (see [investigation findings](../notes/investigation-findings.md)
    §"Firewall-interaction subtlety").
  - Update the `host-access` section (~lines 249-257) to mention the new
    resolution-failure visibility signal in `detail`/status output.
- **Consider `profiles/README.md`** — its "Available profiles" table is tracked
  by followup `MUou` as separately out-of-sync; not required by this task's core
  scope, but note it if the host-access text is touched.

Confirm the exact section anchors against the live files at execution time
(line numbers above are indicative from planning).

role_doc: plugins/flow/references/roles/architect-cloud.md

(The dominant architectural nature is container↔host network reachability,
`extra_hosts` resolution topology, and egress-firewall interaction —
infrastructure/topology. If the manager judges the config-persistence /
CLI-component aspects dominant instead, `architect-backend.md` is the
alternative.)

## Validation

- `docs/architecture.md` and `docs/ai-sandbox-profiles-spec.md` were reviewed and
  updated to describe: the `--add-host` flag and its validation contract; the new
  persisted `add_host` field and three new labels; the `yS0R` consent-gate
  closure for host-detected values; the host-access visibility signal; and the
  downstream-consumer contract including the resolution-vs-egress coupling.
- Any doc section that enumerates config-input fields, `ai.sandbox.*` labels, or
  `running_config_matches` comparison members reflects the new additions (no
  stale field counts left behind — cross-check with the `src/status.sh` comment
  fix from task 003).
- Cross-references between the two docs remain consistent.
</content>
