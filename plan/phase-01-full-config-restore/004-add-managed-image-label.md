# Add Managed Image Label

## Purpose and scope

Containers built by ai-sandbox are already trivially identifiable in plain `docker ps` output: `container_name: ai-sandbox-${SANDBOX_NAME}` (visible in the `NAMES` column) plus the `ai.sandbox.managed: "true"` / `ai.sandbox.instance` labels (used by `list_instances`/`ai-sandbox list`). Images, by contrast, are identifiable only by the `ai-sandbox:<variant>` repository-name prefix (visible in plain `docker images`, and used by `_status_gather_images`'s `docker images ai-sandbox` filter) — there is no image-level label mirroring the container side's `ai.sandbox.managed`.

This task adds a single `LABEL ai.sandbox.managed="true"` to every image ai-sandbox builds, so images support the same label-based filtering/identification (`docker images --filter label=ai.sandbox.managed=true`) that containers already do. This is a small, self-contained addition raised during review of the `full-config-restore` plan — unrelated to the config-persistence work in tasks 001–003, but grouped into this phase since it touches the same `docker/` area and is too small to warrant its own phase.

## Requirements

ai-sandbox builds images via **two independent paths** that must both get the label:

1. **The static "full" Dockerfile** (`docker/Dockerfile`, the default image referenced by `docker-compose.yaml`'s `image: ${AI_SANDBOX_IMAGE_TAG:-ai-sandbox:full}` fallback). Add `LABEL ai.sandbox.managed="true"` alongside the existing `# === LAYER 15: Build-config labels ===` block (`docker/Dockerfile:224-228`, next to `ai.sandbox.chromium-enabled` / `ai.sandbox.docker-enabled`).

2. **The profile-driven assembled Dockerfile** (`docker/Dockerfile.base` + capability fragments, concatenated by `docker/scripts/assemble-dockerfile.sh`, used for every profile-resolved build). `Dockerfile.base`'s own `LAYER 15` block (`docker/Dockerfile.base`, near the end, just before the `--- END OF BASE BODY ---` marker) currently carries **no** `ai.sandbox.*` labels — a comment there notes capability-specific labels were deliberately removed in favor of hash/tag-based tracking. Do **not** add the new label directly to `Dockerfile.base` for consistency with that decision; instead add it in the assembler itself: in `docker/scripts/assemble-dockerfile.sh`, emit `LABEL ai.sandbox.managed="true"` unconditionally (regardless of whether `--hash` was supplied), analogous to the existing conditional `ai.sandbox.profile-hash` block (~line 118), so every assembled Dockerfile gets the label regardless of capability composition. Place it before the final `ENTRYPOINT` line is appended.

3. Both labels use the literal string `"true"` (matching the existing `ai.sandbox.managed` container label's convention in `docker/docker-compose.yaml:55`).

4. **No other changes.** Do not alter `ai.sandbox.chromium-enabled`, `ai.sandbox.docker-enabled`, `ai.sandbox.profile-hash`, or any container-side label. Do not change `is_build_stale`, `_status_gather_images`, or any hash computation — this label is descriptive/filtering metadata only, not consumed by any staleness or matching logic in this task.

5. Run `make build` and `make lint` after the change; keep shellcheck clean.

## Validation

- `grep -n 'ai.sandbox.managed' docker/Dockerfile` shows the new `LABEL` line in the static full Dockerfile.
- `grep -n 'ai.sandbox.managed' docker/scripts/assemble-dockerfile.sh` shows the new unconditional `LABEL` emission.
- Manual check: run `docker/scripts/assemble-dockerfile.sh "" /tmp/Dockerfile.test-lean` and `docker/scripts/assemble-dockerfile.sh --hash abc123 "docker" /tmp/Dockerfile.test-docker`; confirm both assembled outputs contain `LABEL ai.sandbox.managed="true"` regardless of capabilities or whether `--hash` was passed.
- `make build` regenerates `bin/ai-sandbox.sh` cleanly (this task touches `docker/` only, not `src/`, so the rollup output should be unaffected — confirm `git diff bin/ai-sandbox.sh` is empty after `make build`).
- `make lint` passes.
- `make test.unit` passes (no existing test asserts exact Dockerfile/assembled-output content that this would break — confirmed no golden-file test covers `assemble-dockerfile.sh` output in `test/unit/ai_sandbox_spec.sh` at plan-authoring time; if one is added later and breaks, update its expectation rather than dropping the label).

## Metadata

architectural_impact: false

## References

- `docker/Dockerfile:224-230` — the static full image's existing Build-config labels block.
- `docker/Dockerfile.base` (tail, near `--- END OF BASE BODY ---`) — the base fragment's LAYER 15 comment explaining why capability labels were removed; do not add the new label here.
- `docker/scripts/assemble-dockerfile.sh:105-121` — the existing conditional `ai.sandbox.profile-hash` label emission to mirror (but unconditional, not gated on `--hash`).
- `docker/docker-compose.yaml:55-57` — the container-side `ai.sandbox.managed`/`ai.sandbox.instance` labels this task mirrors at the image level.
- `src/status.sh` `_status_gather_images` — existing `docker images ai-sandbox` name-based filter this label complements (not replaces).

## Checkpoint hints

- After adding the label to `docker/Dockerfile` and confirming `make build`/`make lint` are clean.
- After adding the unconditional label emission to `assemble-dockerfile.sh` and manually confirming both a lean and a capability-inclusive assembled Dockerfile carry the label.
