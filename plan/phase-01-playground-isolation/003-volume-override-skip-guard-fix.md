# Volume Override Skip Guard Fix

## Purpose and scope

Fix a real gap in `src/volume-override.sh`: the existing skip-guard that avoids
double-mounting under `${HOME}/playground` only covers the `file://` marketplace
mount block, not the earlier user-declared volume-maps loop. This is correct to
fix independently of `--static-playground` (it is a latent redundancy today), but
becomes load-bearing once the playground overlay exists — an unguarded
volume-map entry under `~/playground` would be silently shadowed by the overlay
mount stacked over `${HOME}/playground` at container start, with no error.

Independent of Tasks 001 and 002; parallel-eligible. Single file:
`src/volume-override.sh`. No standard skill. Run `make build` after editing.

## Requirements

Implement part 7 of the [design note](../notes/static-playground-design.md).

- In `generate_volume_override()`'s `user_maps` loop (~lines 31-46), after the
  `src`/`dst` split, skip the mount entirely when the resolved target (`dst`)
  falls inside `${HOME}/playground` — reusing the same `case` skip-guard idiom the
  marketplace block already uses (~lines 86-92): match
  `"${HOME}/playground"/*` and the bare `"${HOME}/playground"`, and only
  `mounts+=(...)` in the default arm.
- Apply the guard **unconditionally** (independent of `STATIC_PLAYGROUND`): a
  redundant identity mount under `~/playground` is never useful — with the
  overlay it is actively harmful (silent shadowing), and without it, it is at best
  a no-op that the base bind already covers.
- Match the existing marketplace guard's rationale comment; keep the guard's
  target the resolved `dst` (the container-side path), consistent with how the
  overlay mounts at the container target.
- Do not alter the marketplace block's existing guard or any other behavior.

## Validation

- `make build` succeeds; `make lint` (shellcheck) passes for
  `src/volume-override.sh`.
- Reading the generated override for a `volume-maps` file containing an entry
  under `$HOME/playground` (e.g. `$HOME/playground/foo`) shows no corresponding
  `- ...playground/foo...` volume line; an entry outside `~/playground` still
  produces its mount.
- Dedicated unit coverage for this skip-guard (both the volume-maps and the
  pre-existing marketplace path) is authored in Task 004; this task's own
  validation is the lint pass plus a manual read-through of the generated output
  for an in-playground vs. out-of-playground entry.

## References

- [static-playground design note](../notes/static-playground-design.md) — part 7.
- `src/volume-override.sh` — the existing marketplace skip-guard (~lines 80-92)
  to mirror, and the `user_maps` loop (~lines 31-46) to fix.
</content>
