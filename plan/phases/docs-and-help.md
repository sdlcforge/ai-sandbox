## Goals

Bring every reference doc and in-tool help text in line with the final command grammar
landed by `dispatch-foundation` and `profiles-resource`. This phase depends on both landing
first — its task breakdown needs the final, resolved profile-deletion syntax to write
accurate examples.

- **Scope note (added at task-breakdown time):** `docs/ai-sandbox-profiles-spec.md`'s "The
  `new-profile` command" section is also in scope — `profiles-resource` renames that
  command to `profiles create <name>`, which the original phase draft below omitted. This
  closes the gap folding the architectural-implications doc-updates check into this phase
  (see `plan/overview.md`'s "Current status" for the rationale); it is now
  `phase-03-docs-and-help/001-update-readme-and-profiles-spec.md`'s task.
- `README.md`: rewrite the CLI reference table for the new noun-based grammar
  (`instances ls`/`instances create`/`profiles ls`/`profiles create`/profile-delete-syntax/
  flat name-then-verb dispatch); rewrite the Quick Start section (bare invocation now
  documented consistently as "enter the default instance," matching the corrected
  behavior); fix the `down`/`logs` passthrough example to show it scoped to a named
  instance (see the audit note — the existing passthrough mechanism already supports this
  once scoped; no new capability needed); remove `status`/`connect` as documented
  spellings; update the `new-profile` row to the new `profiles create` form.
- `docs/architecture.md`: update the "Command flow" section's dispatch-phase description
  (step 11 and any other step referencing the old command words or table names); update
  "Status as both human and machine interface" section's opening reference to `status`/
  `detail` as a "pure alias" pairing (no longer applicable once `status` is dropped);
  update any other prose mentioning `create <name>`, `list`, `new-profile`, `connect` by
  their old spellings.
- `src/help.sh`: rewrite both the global-commands and per-instance-commands tables to the
  new grammar, including the `instances`/`profiles` noun words and their `ls`/`create`
  (and, per the resolved question, `delete`) sub-forms.

This phase satisfies requirement 7's documentation scope directly (folded into this
restructure rather than deferred); it stands in for — and should NOT be duplicated by —
`analyze-change-request`'s own automatic "doc-updates" phase, since this plan's `needs
input` status means that automatic check is skipped for this invocation (it only runs on
the final `complete` re-invocation, once the profiles-delete question is answered and full
task breakdown completes) but the doc scope described here should be treated as already
decided and folded in rather than re-discovered at that point.

## Inputs

- Final command grammar from `dispatch-foundation` and `profiles-resource` (including the
  resolved profiles-delete syntax).
- `README.md`, `docs/architecture.md`, `src/help.sh` (all fully read this session; specific
  passages needing change are catalogued in
  [current-dispatch-audit.md](../notes/current-dispatch-audit.md)'s "Other project docs"
  section).

## Outputs

- Updated `README.md`, `docs/architecture.md`, `src/help.sh` with no remaining references
  to `create <name>` (verb-first), bare `list`, `new-profile`, `status`, or `connect` as
  recognized spellings.
