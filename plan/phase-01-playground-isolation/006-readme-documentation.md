# Readme Documentation

## Purpose and scope

Document the `--static-playground` flag for users in `README.md`: a flags-table
entry, a new `### Playground isolation` section mirroring the existing
`### Config isolation` section, explicit disambiguation from the unrelated
pre-existing `--mode static`, and the documented open risks. Architecture-level
documentation (`docs/architecture.md`) is handled separately by the `doc-updates`
phase and is out of scope here.

Can be written from the design note without depending on the implementation
tasks; parallel-eligible. Single file: `README.md`. No standard skill; follow the
existing README structure and the Config isolation section as the template.

## Requirements

Implement the `README.md` portion of part 9 of the
[design note](../notes/static-playground-design.md).

1. **Flags table** (~lines 57-62): add a `--static-playground` row. The
   description must state it gives `~/playground` a copy-on-write overlay (writes
   stay container-local; host is never modified), that it is **opt-in** (default
   off), and that it is **unrelated to `--mode static`** despite the shared word.
   Link to the new Playground isolation section.

2. **New `### Playground isolation` section** — mirror `### Config isolation`
   (~lines 127-203) in structure and depth:
   - Mechanics: base `~/playground` RW bind replaced by a read-only lower at
     `/mnt/ai-sandbox/host-playground`; a `playground-overlay` **named volume**
     (not tmpfs, because `~/playground` is large) holds the overlay upper+work;
     `06-overlay-playground` mounts the overlayfs at `~/playground`; reads fall
     through to the host for untouched files.
   - Opt-in example (`ai-sandbox --static-playground`) and the opt-in-vs-opt-out
     asymmetry vs. config isolation (why it defaults off — it changes a path
     users rely on being host-writable).
   - Pointer to `sandbox-volumes` for inspecting/syncing drift, and a
     **performance caveat**: always scope `sandbox-volumes diff`/`sync`/`status`
     to a subpath, never the whole tree (the recursive diff can take many minutes
     across a large multi-repo tree).
   - The `CAP_SYS_ADMIN` / `apparmor=unconfined` cost note (shared with config
     isolation via the privileges fragment).
   - That `delete`/`clean` discards container-local overlay writes with no
     separate confirmation (matching `docker compose down` expectations).

3. **Disambiguation** — make it unmistakable that `--static-playground` (playground
   write-isolation) and `--mode static` (container identity mode; see the Profiles
   / `--mode` docs) are different, unrelated features.

Keep the README's existing voice and formatting; do not restructure unrelated
sections.

## Validation

- `README.md` contains a `--static-playground` flags-table row and a
  `### Playground isolation` section; both cross-reference correctly (the table
  row links to the section anchor).
- The section covers: mechanism, named-volume-vs-tmpfs rationale, opt-in
  asymmetry, `sandbox-volumes` performance caveat, `CAP_SYS_ADMIN` cost, and the
  delete/clean discard behavior.
- The `--mode static` disambiguation is present and explicit.
- `make lint` (if it covers Markdown/README) passes, or at minimum the file has
  no broken internal anchor links (grep the anchor referenced by the new table
  row against the new heading).
- Prose is consistent with the actual mechanism as implemented in Task 002
  (named volume, `:ro` base override, registry row).

## References

- [static-playground design note](../notes/static-playground-design.md) — part 9
  (README) and the open risks (performance, naming collision).
- `README.md` § "Config isolation" (~lines 127-203) — the template section to
  mirror, including the `sandbox-volumes` subsection and `CAP_SYS_ADMIN` note.
- `README.md` § "Flags" table (~lines 57-62) and the `--mode` row to disambiguate
  against.
</content>
