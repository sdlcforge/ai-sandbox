# Update Architecture Docs

## Purpose and scope

Update the project's architecture and spec documentation to reflect the new container-side **config-persistence and restore contract** introduced by Phase 01: a new canonical `ai.sandbox.config` Docker label carrying the full config-input record, the reconciled `restore_saved_config`/`running_config_matches` dimension set, and the input-vs-derived persistence model. This runs after the Phase 01 implementation tasks land. Invoke the `update-architecture-docs` task-procedure at `plugins/flow/task-procedures/update-architecture-docs/SKILL.md`.

## Requirements

The following Phase 01 implementation task documents surfaced the architectural implications (both carry `architectural_impact: true`); review the changes they made:

- `phase-01-full-config-restore/001-persist-and-restore-full-config-inputs.md` — adds the `ai.sandbox.config` base64 JSON label (new persisted config-input contract) and the full-input restore path with legacy-label fallback.
- `phase-01-full-config-restore/002-reconcile-running-config-match.md` — adds the `ai.sandbox.marketplaces`/`ai.sandbox.plugins`/`ai.sandbox.enable-all-plugins` derived labels and extends the effective-config match.

Architecture and spec files to review and update where needed:

- `docs/architecture.md` — the primary target. It documents the container-label conventions in several places (SSH-agent forwarding label, profile-hash/image-tagging, `running_config_matches` in the command-flow narrative) but has **no** section describing the config-persistence/restore contract. Add a subsection (e.g. under "Key design decisions") that documents: the new `ai.sandbox.config` label as the canonical config-input record; the input-vs-derived model (persist inputs, re-derive the rest via `profile-installer.js`); why `restore_saved_config` reads the input record while `running_config_matches` compares derived labels (different pipeline stages, both covering the full dimension set); base64 encoding rationale; and backward-compat via legacy-label fallback. Reference [config persistence design recommendation](../notes/config-persistence-design.md) for the full rationale. Also verify the command-flow phase list and any label inventory in the doc reflect the added labels.
- `docs/ai-sandbox-profiles-spec.md` — review for any needed cross-reference. The spec defines the `marketplaces`/`plugins`/`enable_all_plugins` fields and CLI additions; check whether a note about their persistence/restore across bare `enter`/`start` belongs here or is better confined to `docs/architecture.md`. Update only if a genuine gap exists; the label scheme itself is an architecture concern, not a spec concern.

role_doc: `references/roles/architect-backend.md`

Do not modify `plan/` documents other than this task doc, and do not touch source code — this is a documentation task.

## Validation

- `docs/architecture.md` contains a subsection describing the `ai.sandbox.config` label and the config-persistence/restore contract, consistent with the shipped Phase 01 implementation (labels, function names, and behavior match the merged code — verify against `src/utils.sh` and `docker/docker-compose.yaml`, not just the design note).
- The label inventory / relevant narrative in `docs/architecture.md` names the new labels (`ai.sandbox.config`, and the three derived marketplace/plugin labels) and no longer implies the config restore is limited to profiles/mode/clean-slate.
- `docs/ai-sandbox-profiles-spec.md` is either updated with an appropriate cross-reference or confirmed (in the task report) to need no change, with a stated reason.
- Any cross-references/links added resolve correctly.
