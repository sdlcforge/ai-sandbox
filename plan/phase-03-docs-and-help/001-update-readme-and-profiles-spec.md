# Update Readme And Profiles Spec

## Purpose and scope

Update `README.md` and `docs/ai-sandbox-profiles-spec.md` to document the final CLI grammar
landed by `dispatch-foundation` and `profiles-resource`. Depends on both of those phases
having landed (needs the final, resolved profile-deletion syntax and the actual
`profiles ls`/`profiles create` behavior to write accurate examples). No standard skill
applies — this is a documentation-only task; follow the [Markdown Design
Standards](flow-mcp:d) and [README Document Standards](flow-mcp:d) already governing these
files' existing structure (do not restructure sections beyond what the content changes
require). This task is parallel-eligible with
`002-update-architecture-and-help-text.md` (disjoint file sets) — both may be dispatched
concurrently once this phase's prerequisites land.

`docs/ai-sandbox-profiles-spec.md` was not in the original phase draft's scope (see
`plan/phases/docs-and-help.md`) — its inclusion here closes a gap identified during task
breakdown: `profiles-resource` renames the `new-profile` command to `profiles create
<name>`, which makes that spec's "The `new-profile` command" section (and its `--name`
flag documentation) stale. This is folded into this task rather than deferred to a separate
doc-updates phase — see the structured report from this planning session for the
rationale.

## Requirements

1. **`README.md` CLI reference table.** Rewrite the `## CLI reference` table for the new
   noun-based grammar:
   - Add rows for `instances ls`, `instances create <name> [options]`, `profiles ls`,
     `profiles create <name> [options]`.
   - Update the `<name> delete` row (or add one if none exists today) to note it applies to
     both instances and profiles (per the resolved profile-deletion syntax — no separate
     `profiles delete <name>` form).
   - Remove the `status`/`detail` row's `status` spelling — `detail` is now the only word;
     update the row's description accordingly (drop "pure alias for status" language).
   - Remove `connect` from the `attach` / `connect` row — `attach` only.
   - Remove the `new-profile` row (replaced by `profiles create`).
   - Update the `*(no args)*` row's description to reflect that bare invocation still means
     "enter the default instance" (unchanged from today's documented — if not
     code-accurate-until-now — behavior; see `plan/notes/current-dispatch-audit.md`'s "Bare
     no-args behavior" section) and cross-reference the new bare `ls` word as the explicit
     listing command.
2. **`README.md` Quick Start section.** Remove the unscoped `ai-sandbox down` /
   `ai-sandbox logs -f` passthrough examples (they don't work as written today — traced in
   `plan/notes/current-dispatch-audit.md`'s "README down/logs passthrough claim" section —
   and this plan doesn't add unscoped passthrough capability). Replace with a correctly
   scoped example showing passthrough against a named instance, e.g. `ai-sandbox mybox
   down` / `ai-sandbox mybox logs -f`.
3. **`README.md` other mentions.** Grep `README.md` for any other prose reference to
   `create <name>` (verb-first), bare `list`, `new-profile`, `status`, or `connect` as a
   recognized spelling, and update each (e.g. the `yq` mention under Optional prerequisites
   references "the `status`/`detail` command" — update to "the `detail` command").
4. **`docs/ai-sandbox-profiles-spec.md` — "The `new-profile` command" section.** Rename the
   section heading and content to reflect `profiles create <name>`: the `--name <name>`
   flag row is replaced by a positional `<name>` argument description (update the "Flags"
   table accordingly — `--mode`, `--output`, `--plugins` are unchanged); update the
   "Output" example command implicitly referenced (the printed `Created profile: ...` line
   is unchanged in substance). Add a short note that profile listing (`profiles ls`) and
   deletion (`<name> delete`) are documented in `README.md`'s CLI reference rather than
   duplicated in this schema-focused spec (avoid duplicating the full CLI grammar here —
   this doc's job is the YAML schema and the `profile-installer.js`/`new-profile` (now
   `profiles create`) interfaces, not the general CLI reference).
5. Do not modify `docs/ai-sandbox-profiles-spec.md`'s YAML schema, composition rules, or
   storage/discovery sections — those are unchanged by this plan; only the command-surface
   section (item 4) is in scope.

## Validation

- `grep -n 'new-profile\|--name <name>' docs/ai-sandbox-profiles-spec.md` shows no
  remaining reference to the old command word/flag as a currently-valid spelling (historical
  mentions explicitly marked as superseded, if any, are acceptable).
- `grep -n '\bstatus\b\|\bconnect\b\|ai-sandbox down\|ai-sandbox logs' README.md` — confirm
  every remaining hit is either unrelated (e.g. Docker daemon "status", unrelated prose) or
  intentionally retained per item 2's scoped-passthrough replacement; no unscoped
  `ai-sandbox down`/`ai-sandbox logs` examples remain.
- `grep -n 'new-profile' README.md` returns no matches.
- Manual read-through: the CLI reference table's rows match exactly what
  `dispatch-foundation` and `profiles-resource` implemented (cross-check against
  `src/help.sh` once `002` lands, or against the source files directly).

## References

- `plan/notes/current-dispatch-audit.md` — "Other project docs referencing dropped
  spellings" and "README down/logs passthrough claim" sections.
- `docs/ai-sandbox-profiles-spec.md` — "The `new-profile` command" section (current state).
- `plan/phase-02-profiles-resource/001-build-profiles-module.md` — the implementation task
  whose landed behavior this task documents.
