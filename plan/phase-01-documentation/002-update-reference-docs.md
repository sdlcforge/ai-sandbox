# Update Reference Docs

## Purpose and scope

Update `README.md` and `docs/architecture.md` to reflect the profiles feature and Flow documentation standards. Both files already exist; this task edits them in place. Depends on Task 001 (`docs/ai-sandbox-profiles-spec.md`) being written first — read the spec before editing either file.

## Requirements

### README.md

Restructure and update the existing README to Flow doc standards. Content changes:

**Structure (in order):**
1. One-paragraph project description (tighten current opener; keep it factual and specific).
2. Prerequisites — content unchanged.
3. Install — content unchanged.
4. Quick start — current usage section, possibly tightened.
5. CLI reference — updated table: remove `--docker`/`--no-docker` flags (moved to profile), remove `--no-chromium` flag (moved to profile), add `--profile <name>` flag (repeatable), add `--mode <mirror|static>` override flag, add `create-profile` command row.
6. Profiles — new section, brief (3-5 sentences + example invocation), points to `docs/ai-sandbox-profiles-spec.md` for full detail.
7. What's inside — existing content, lightly updated (note that the package list is now the `base` standard profile).
8. Plugin support — content unchanged.
9. SSH agent forwarding — content unchanged.
10. Docker access — update: docker-socket-proxy is now enabled via the `docker` profile (`--profile docker`) rather than `--docker` flag. Keep security caveat.
11. Current limitations and goals — content unchanged; may add "profiles are specified but not yet implemented" note if appropriate.
12. Further reading — add `docs/ai-sandbox-profiles-spec.md` link.

**Flow doc standards to apply:**
- Lead with the sharpest possible description of what the tool does, not marketing.
- Sections at `##` level, subsections at `###`.
- Code blocks for all shell examples.
- Tables for reference material (CLI flags, commands).
- No trailing filler sentences.

### docs/architecture.md

Read the existing file, then add a **Profiles** section. Do not remove or modify existing sections. Insert the new section after the existing `## Key design decisions` section (before `## Test strategy`).

**Profiles section content:**

`### Profile system`

Cover these topics:
- **What a profile is** — YAML file defining environment; replaces ad-hoc flags; two modes (mirror/static).
- **Composition model** — how multiple profiles are merged (list union, scalar conflict = error, metadata ignored). Why error-on-conflict rather than last-wins: makes surprises explicit.
- **Storage and discovery** — the priority-ordered search: project `./profiles/`, `$XDG_CONFIG_HOME/ai-sandbox/profiles/`, bundled. How `default_profiles` in `~/.config/ai-sandbox/config.yaml` eliminates the need to pass `--profile` on every invocation.
- **The Node boundary** — `bin/profile-installer.js` handles YAML parsing, path resolution, validation, and merge. Outputs shell-sourceable scalars, newline-delimited paths, and JSON for structured data. Why Node: YAML parsing and structured merge logic are painful in bash; the boundary is clean and testable.
- **Image tagging** — profile composition hash → `ai-sandbox:profile-<hash>`. Stale-check now includes profile file mtimes in addition to `docker/` mtime. Trade-off: same as per-variant image tagging (disk vs. fast switching), but hash-based so it scales to arbitrary profile compositions without a combinatorial tag explosion.
- **Standard profiles and the Dockerfile** — the base Dockerfile becomes thinner: OS, core utils, ai-sandbox toolchain. The `base` standard profile carries the language runtimes (Go, Node via nvm, Bun) and tools previously baked into the Dockerfile. This separates "what the image needs to run" from "what an agent needs to work."
- **Local vs. shareable** — profiles with local path references are auto-flagged `local: true` by profile-installer. Not a hard restriction, but an explicit signal. Enterprise setups with reliable paths across machines are a valid use case.

## Assumptions

- Task 001 has completed and `docs/ai-sandbox-profiles-spec.md` exists before this task starts.
- The architecture doc section should be consistent with the spec but need not duplicate it; cross-reference with a link.
- README restructuring should not lose any substantively correct existing content — verify each section of the original is accounted for.

## References

- `docs/ai-sandbox-profiles-spec.md` (read after Task 001 completes)
- Existing `README.md` (319 lines, read by manager)
- Existing `docs/architecture.md` (read by manager)

## Validation

- `README.md` contains a Profiles section with a link to `docs/ai-sandbox-profiles-spec.md`.
- CLI reference table in README no longer mentions `--docker`, `--no-docker`, or `--no-chromium` as standalone flags.
- CLI reference table shows `--profile` and `--mode` flags.
- Docker access section explains the docker-socket-proxy is now enabled via profile.
- `docs/architecture.md` has a `### Profile system` subsection under a `## Key design decisions` or similar parent section.
- Architecture profiles section covers: composition model (with error-on-conflict rationale), Node boundary rationale, image tagging by hash, standard profiles vs. Dockerfile split.
- No existing content in either file has been accidentally removed.
- Both files render correctly as Markdown.
