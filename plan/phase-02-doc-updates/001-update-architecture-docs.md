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

## Status

**Outcome: succeeded.** 2026-07-14.

Updated `docs/architecture.md` only; no other file needed changes.

- Added a new subsection, "`~/playground` is copy-on-write when
  `--static-playground` is set", placed as a sibling of the existing
  "`~/.config` is copy-on-write by default" section (after its nested
  "sandbox-volumes" subsection, before "SSH agent forwarding is decoupled
  from the host path"). Covers, per the Requirements: the mechanism
  (`docker-compose.static-playground.yaml` +
  `06-overlay-playground`, mirroring the config overlay's shape); the
  base-mount-override subtlety (Compose same-target replacement / last `-f`
  wins, the `:ro` re-declaration, and its safe read-only failure mode); the
  shared `docker-compose.overlay-privileges.yaml` extraction and the
  duplicate-`security_opt`-is-a-hard-validation-error rationale forcing it;
  the registry idempotency fix (strip-own-row-then-append, keyed
  `^config\t`/`^playground\t`) in both `02-overlay-config` and
  `06-overlay-playground`; and the named-volume-vs-tmpfs choice (19GB+ tree)
  with the targeted `delete`/`clean` volume cleanup that deliberately avoids
  `down -v` to spare the unrelated `firewall-handshake` volume.
- Updated `### Config persistence and restore`: the field list, the
  "eighth field" language, and the "rehydrates all eight input globals"
  sentence now read nine/ninth, with `static_playground` /
  `ai.sandbox.static-playground` added to the config-JSON field list and the
  `running_config_matches` derived-label list (now five additional labels,
  with a note that `static_playground` compares directly against the raw
  `STATIC_PLAYGROUND` global rather than a derived `AI_SANDBOX_*` passthrough
  var, since it has no profile-level/CLI-merge step of its own — verified
  against `src/utils.sh`'s actual `running_config_matches()`/
  `restore_saved_config()` implementations, not assumed from the design
  note).
- Checked the `docs/*-spec.md` glob: only `docs/ai-sandbox-profiles-spec.md`
  matches, and it contains no mention of `playground`/`static-playground`
  (confirmed via grep). Determination: **no spec update needed** — that spec
  governs the profiles system, not this flag, and the `--static-playground`
  vs `--mode static` naming disambiguation is README/architecture-doc
  content, not a profiles-spec concern. Recorded here per the task's
  Requirements.
- Same-diff self-fixes (both inside `docs/architecture.md`, the only file
  this task touches): (1) the pre-existing "adding a second overlay later"
  sentence in the `sandbox-volumes` subsection was updated to reflect that a
  second overlay (`~/playground`) is now real, not hypothetical, while
  preserving the extensibility point for a third; (2) a stray, meaningless
  "Task 002" reference in the `--allow-egress` restore-validation paragraph
  (an orphaned cross-reference to another plan's internal task numbering,
  unrelated to this doc's readers) was generalized to "the container-init-time
  firewall-rule application".

All prose was checked against the actual landed implementation (`src/index.sh`,
`src/utils.sh`, `docker/docker-compose*.yaml`,
`docker/rootfs/etc/cont-init.d/02-overlay-config` and `06-overlay-playground`)
rather than restated from the design note or the two implementation task docs'
Status sections alone.

### Validation results

- New playground-isolation subsection present, covering mechanism,
  base-mount-override finding, privileges-fragment rationale, and registry
  idempotency fix — **passed** (manual re-read + grep spot-checks for
  `playground-overlay`, `06-overlay-playground`, `overlay-privileges`).
- "Config persistence and restore" no longer says "eight-dimension"/"eighth
  field" as a dimension-total (the one remaining "eighth field" reference
  correctly describes `allow_egress` specifically, mirroring the same
  intentional pattern the `cli-flag-and-config-persistence` task's own Status
  section documented for `src/utils.sh`/`src/index.sh`) and lists
  `static_playground`/`ai.sandbox.static-playground` in both the field list
  and the derived-label list — **passed** (`grep -n -i
  'eight-dimension\|eighth field\|eight input' docs/architecture.md` returns
  only the one historically-accurate `allow_egress` reference).
- `docs/*-spec.md` review determination recorded above — **passed**
  (no-change-required, with reason).
- Prose matches the mechanism as actually implemented (named volume, `:ro`
  base override, four volume entries, `06-overlay-playground`, shared
  privileges fragment) — **passed**, verified line-by-line against the
  landed compose files, cont-init scripts, and `src/index.sh`'s
  `COMPOSE_FILES` assembly (not merely the design note).
- Internal cross-references/anchors in `docs/architecture.md` remain valid —
  **passed**. All pre-existing anchor links (`grep -n '](#'
  docs/architecture.md`) still resolve to unchanged headings. Deliberately
  did **not** add a computed-anchor link to the new heading itself (a heading
  containing a literal `--flag` produces an ambiguous multi-hyphen slug
  across renderers); the two forward/backward references to the new
  subsection use plain prose ("the next subsection below" / "described
  earlier in this document") instead of a `#anchor` link, to avoid
  introducing a dangling reference risk.

### Assumptions applied

None beyond the task doc's own framing — Phase 01 (`playground-isolation`)
was confirmed already landed on this branch by reading the actual source
files (`src/options.sh`, `src/index.sh`, `src/utils.sh`, the compose files,
and both cont-init scripts) rather than assumed from the two implementation
task docs' own Status sections.

### Notes for the manager

- The known phase-01-review gap — `docker/docker-compose.yaml`'s
  `~/playground` bind-mount comment block (~line 96-99) not yet pointing at
  `docker-compose.static-playground.yaml`'s override — was left untouched, as
  instructed (a separate simple-task fix is in flight for it, and it's a
  source-file comment, not part of this task's `docs/architecture.md` scope).
- No changes were made to `README.md`, `plan/overview.md`, `plan/TODO.yaml`,
  or `plan/followups.yaml`; this task touched only `docs/architecture.md` and
  this task document's own Status section.
</content>
