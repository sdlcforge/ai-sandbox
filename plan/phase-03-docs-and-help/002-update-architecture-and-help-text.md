# Update Architecture And Help Text

## Purpose and scope

Update `docs/architecture.md` and `src/help.sh` to document the final CLI grammar landed by
`dispatch-foundation` and `profiles-resource`. Depends on both of those phases having
landed. No standard skill applies — this is a documentation/help-text task; follow the
[Markdown Design Standards](flow-mcp:d) already governing `docs/architecture.md`'s existing
structure. This task is parallel-eligible with
`001-update-readme-and-profiles-spec.md` (disjoint file sets) — both may be dispatched
concurrently once this phase's prerequisites land.

## Requirements

1. **`docs/architecture.md` "Command flow" section.** Update step 11 (today: "**Dispatch**
   — `start`/`enter`/`attach`/`build`/`user-exec`/`root-exec`/`status`/`stop`/`clean`; any
   other word is forwarded to `docker compose`") to reflect: `detail` replacing `status`;
   `attach` only (no `connect`); the new noun-word parsing phase for `instances`/`profiles`
   (`ls`/`create`) that now precedes the per-name dispatch; the per-name
   resolve-then-verb-gate mechanism (instance vs. profile resolution, per-kind allowed
   verbs); and the new profile-kind short-circuit that bypasses the Docker pre-flight
   (update step references near line ~50-51, which currently describe `status` as exempt
   from the Docker pre-flight retry — `detail` is exempt now, and profile-kind dispatch is
   exempt entirely, not just tolerant of a down daemon).
2. **`docs/architecture.md` "Status as both human and machine interface" section.** Update
   the opening sentence (today: `` `ai-sandbox status` (and its pure alias `detail`,
   normalized to the same `CMD`... ``) — `detail` is now the only spelling; remove the
   "pure alias" framing entirely since there is nothing left to be an alias of.
3. **`docs/architecture.md` other mentions.** Grep for any other prose referencing
   `create <name>` (verb-first), bare `list`, `new-profile`, `connect`, or `status` as a
   currently-recognized CLI word (distinct from internal identifiers like `STATUS_JSON`,
   `status.sh`, and `do_status`, which are unchanged and out of scope — see
   `plan/notes/current-dispatch-audit.md`'s confirmed assumption that these internals are
   unchanged) and update each. Note: `make/60-test.integration-bash.mk`'s live CLI
   invocation of `status --test-check` was not an internal identifier and was a real
   regression — it has already been fixed (to `detail --test-check`) by a prior task, so
   this phase does not need to touch that file.
4. **`src/help.sh` full rewrite.** Rewrite both the `Global commands:` and `Per-instance
   commands:` sections of `print_help()`'s heredoc:
   - Replace `create <name> [options]` and `list` global-command rows with `instances ls`,
     `instances create <name> [options]`, `profiles ls`, `profiles create <name>
     [options]` rows (options lists follow the existing per-flag documentation style
     already present for `create`).
   - Remove the `new-profile` row.
   - Update the per-instance commands list: remove `connect` from the `attach, connect` row
     (→ `attach` only); remove `status` from the `status` row description, keeping only
     `detail`; add a `delete` row description noting it applies to profile names too
     (per the resolved profile-deletion syntax — `ai-sandbox <profile-name> delete`) if not
     already generically worded to cover both.
   - Update the top `Usage:` block's third line (today: `ai-sandbox   List all sandboxes`)
     to reflect the corrected bare-invocation behavior (enter default instance) and add a
     line documenting the bare `ls` word.
5. Keep `print_help()`'s heredoc formatting/alignment conventions consistent with the
   existing style (column alignment, flag indentation) — this is a content update, not a
   restructuring.

## Validation

- `shellcheck src/help.sh` passes (heredoc content isn't shellchecked in depth, but the
  function structure must still pass).
- `make build` succeeds.
- `grep -n 'new-profile\|connect\b' src/help.sh docs/architecture.md` returns no matches
  (aside from any explicitly-historical mention, if present).
- `ai-sandbox help` output (manual run) matches the actual final dispatch grammar landed by
  `dispatch-foundation`/`profiles-resource` — cross-check every documented command word
  against `src/options.sh`'s reserved-word derivation and noun/verb tables.
- `grep -n '"pure alias"' docs/architecture.md` returns no matches.

## References

- `plan/notes/current-dispatch-audit.md` — "Other project docs referencing dropped
  spellings" section (exact line references into `docs/architecture.md` as of the audit).
- `src/help.sh` (current implementation, to be rewritten in place, same file).
