# Update Architecture Docs

## Purpose and scope

Update the architecture documentation to reflect the `--static-playground`
playground-isolation feature implemented in the `playground-isolation` phase.
This task runs after those implementation task documents have been completed, so
the code and compose topology it describes already exist. Invoke the
`update-architecture-docs` task-procedure.

## Requirements

The architectural implications originate from these completed implementation task
documents (relative to the plan worktree):

- `plan/phase-01-playground-isolation/001-cli-flag-and-config-persistence.md` —
  adds `static_playground` as the 9th persisted config-input dimension and the
  `ai.sandbox.static-playground` label (significant tracked state).
- `plan/phase-01-playground-isolation/002-docker-overlay-mechanism.md` — introduces
  the playground-isolation subsystem: the shared
  `docker-compose.overlay-privileges.yaml` fragment, the
  `docker-compose.static-playground.yaml` overlay, the `playground-overlay` named
  volume, the `06-overlay-playground` cont-init stage, and the mode-independent
  `COMPOSE_FILES` wiring plus delete/clean volume cleanup.

Architecture and spec files to review and update:

- `docs/architecture.md`:
  - Add a new subsection mirroring `### ~/.config is copy-on-write by default`,
    covering: the playground overlay mechanism (opt-in via `--static-playground`);
    the base-mount override subtlety (Compose replaces same-target volume entries,
    last `-f` wins — the `:ro` re-declaration and its safe read-only failure
    mode); the shared `docker-compose.overlay-privileges.yaml` extraction and why
    (duplicate `security_opt` across merged compose files is a hard validation
    error); the registry idempotency fix in `02-overlay-config` /
    `06-overlay-playground`; and the named-volume-vs-tmpfs choice (large tree) with
    the targeted delete/clean cleanup (not `down -v`, to spare
    `firewall-handshake`).
  - Update `### Config persistence and restore`: change the "eight-dimension" /
    "eight input globals" / "eighth field" language to nine throughout, and add
    `static_playground` / `ai.sandbox.static-playground` to the config-JSON field
    list and the `running_config_matches` derived-label list.
- `docs/*-spec.md` glob: check for a project spec file. The known spec,
  `docs/ai-sandbox-profiles-spec.md`, governs profiles, not this flag; confirm
  no spec update is needed (note the `--static-playground` vs `--mode static`
  naming distinction is a docs/README concern, not a profiles-spec change) and
  record that determination.

Do not restate the full design here — draw on the authoritative
[static-playground design note](../notes/static-playground-design.md) for
mechanism detail and the three empirical findings.

role_doc: plugins/flow/references/roles/architect-cloud.md

Task-procedure: plugins/flow/task-procedures/update-architecture-docs/SKILL.md

## Validation

- `docs/architecture.md` contains a new playground-isolation subsection covering
  the mechanism, the base-mount-override finding, the privileges-fragment
  extraction rationale, and the registry idempotency fix.
- `docs/architecture.md` § "Config persistence and restore" no longer says
  "eight-dimension"/"eighth field" (now nine) and lists `static_playground` /
  `ai.sandbox.static-playground` among the config fields and derived labels.
- The `docs/*-spec.md` review determination is recorded (updated if needed, or
  explicitly noted as no-change-required with the reason).
- Prose matches the mechanism as actually implemented in the
  `playground-isolation` phase (named volume, `:ro` base override, four volume
  entries, `06-overlay-playground`, shared privileges fragment).
- Internal cross-references/anchors in `docs/architecture.md` remain valid.

## References

- [static-playground design note](../notes/static-playground-design.md) — full
  design and the three empirical findings the new subsection should convey.
- `docs/architecture.md` § "~/.config is copy-on-write by default", §
  "sandbox-volumes: inspecting and syncing overlay state", and § "Config
  persistence and restore" — the sections to mirror and update.
- The two implementation task docs listed under Requirements — the source of the
  architectural changes to document.
</content>
