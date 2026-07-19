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

## Status

- Outcome: **succeeded**
- Date: 2026-07-18
- Implementation: read `plan/overview.md` and the four completed Phase 1 task
  docs (`001`-`004`) from the plan worktree
  (`/Users/zane/playground/ai-sandbox/worktrees/plan/host-ipv4-access`), then
  grounded every doc edit directly in the merged `src/`, `docker/`, and
  `test/` code in this task's own worktree (including the
  `2026-07-18-phase-1-review-fixes` merge — the reserved-`host.docker.internal`
  rejection, the stale host-access-marker clear-on-capability-absent fix, and
  the dropped dead `AI_SANDBOX_ADD_HOST` sidecar env var) rather than relying
  solely on the task docs' original descriptions.
  - `docs/architecture.md`: added a new `### Caller-pinned host reachability:
    \`--add-host\`` subsection (parsing/validation, the reserved-name guard,
    `extra_hosts` threading and Compose's append-not-replace merge semantics,
    the resolution-vs-egress coupling, and persistence) directly after
    "Capability-driven dynamic firewall rules"; extended that section's
    env-var-passthrough paragraph to note `AI_SANDBOX_ADD_HOST`'s asymmetry
    (declared only on the `ai-sandbox` service, not `firewall-init`, since
    `docker/init-firewall.sh` never reads it — confirmed against the
    review-fix commit) and added a "host-access resolution-failure
    visibility" paragraph documenting the `host-access-unresolved` marker,
    its clear-on-success/clear-on-capability-absent behavior, and
    `_status_gather_host_access()`'s `-u root` `docker exec` read. Updated
    "Config persistence and restore": `add_host` as the tenth config-input
    field (eight → ten field counts corrected throughout), restore
    re-validation via `is_valid_add_host_spec()`, `running_config_matches()`'s
    three new labels (`ai.sandbox.add-host`/`ai.sandbox.lan-cidr`/
    `ai.sandbox.host-listen-ports`), and a new "Host-detected labels close a
    config-persistence gap (followup `yS0R`)" paragraph explaining why the
    latter two participate in `matches` but never in the persisted JSON
    record or `restore`.
  - `docs/ai-sandbox-profiles-spec.md`: added a new `### \`--add-host\`:
    pinning a stable host IPv4` subsection under "Invocation changes"
    (validation-contract table, the reserved-name rule, persistence summary)
    plus a `#### Downstream-automation-consumer contract` subsection
    documenting the resolution-vs-egress-allowance coupling precisely as
    built — since `--add-host host.docker.internal:<ip>` is rejected
    outright, the contract is phrased as two composition paths
    (`host.docker.internal` stays exclusively `host-access`'s domain; any
    other name is the `--add-host` + `--allow-egress` path), a correction
    against `plan/notes/investigation-findings.md`'s earlier exploratory note
    (written before the reserved-name rejection landed) that suggested a
    pinned `host.docker.internal` would compose with `host-access`. Extended
    the `### \`host-access\`` capability entry with a "Resolution-failure
    visibility" paragraph.
  - No new top-level (`##`) sections were added to either file; all new
    content is `###`/`####` subsections nested under existing sections, per
    the `update-architecture-docs` procedure's restructuring constraint.
  - Fixed a stray trailing `</content>` artifact at the end of this task
    document (same-diff self-fix, in the file already being edited to add
    this Status section).
- Validation summary:
  - Both `docs/architecture.md` and `docs/ai-sandbox-profiles-spec.md` were
    reviewed end-to-end and updated to describe the `--add-host` flag and its
    validation contract, the new persisted `add_host` field and three new
    `ai.sandbox.*` labels, the `yS0R` consent-gate closure for the two
    host-detected values, the host-access resolution-failure visibility
    signal, and the downstream-consumer contract including the
    resolution-vs-egress coupling — passed.
  - Grepped both docs (and `README.md`, for drift-scope awareness) for stale
    field counts (`seven-field`/`eight field`/`nine field`/`nine input`/
    `five additional`, etc.); none remain — `docs/architecture.md` now reads
    "ten input globals" and "eight additional derived labels" consistently
    throughout — passed.
  - Verified every new/changed internal (`#anchor`) and cross-file
    (`architecture.md#anchor` / `ai-sandbox-profiles-spec.md#anchor`) link
    resolves to an existing heading, computing the actual GitHub-slugger
    anchor for each new heading programmatically (the `--add-host` headings'
    literal `--` collapses into a slug with an extra hyphen, e.g.
    `#caller-pinned-host-reachability---add-host` — verified against
    `github-slugger`, not hand-guessed) rather than assuming the naive
    lowercase-and-hyphenate transform — passed.
  - No dangling cross-references, no contradicted claims within either file,
    and no claims across the two files that disagree — passed (manual
    re-read).
- Assumptions applied: none beyond what the task doc's own scope note already
  states (`profiles/README.md`'s "Available profiles" table, tracked by
  followup `MUou`, was left untouched — its host-access text was not touched
  by this task's edits, so the task doc's own carve-out applies).
- Notes:
  - `README.md`'s "Network access" section documents `--allow-egress` in
    prose but has no equivalent coverage for the new `--add-host` flag (and
    its compact "Flags" table already omits `--allow-egress` too, so this is
    consistent with a pre-existing README convention of covering
    network-related flags only in prose, not a regression introduced here) —
    flagged for the manager as a candidate follow-up doc task, out of this
    task's named scope (`docs/architecture.md` and
    `docs/ai-sandbox-profiles-spec.md` only).
  - `plan/notes/investigation-findings.md`'s "Firewall-interaction subtlety"
    section (written during planning, before the
    `2026-07-18-phase-1-review-fixes` merge) describes a pinned
    `host.docker.internal` composing with `host-access` — that scenario can no
    longer happen, since `--add-host host.docker.internal:<ip>` is now
    rejected outright at parse/restore time. The shipped docs describe the
    as-built behavior correctly; the plan note itself was left unedited (plan
    notes are historical planning artifacts, not part of this task's assigned
    `docs/*` scope), flagged here only so the manager is aware of the
    divergence.
