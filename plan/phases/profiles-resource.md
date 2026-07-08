## Goals

Give profiles a real CRUD surface and complete the name-kind resolution / verb-gating
mechanism the `dispatch-foundation` phase stubbed out. This phase is blocked on the
[profiles-delete-ambiguity](../notes/profiles-delete-ambiguity.md) open question — the
exact command-parsing surface for profile deletion (and, symmetrically, whether any other
noun-level verbs beyond `ls`/`create` exist) cannot be finalized until it resolves.

- Split/rename `src/new-profile.sh` into a `src/profiles.sh` module (or similar) covering:
  - `profiles create <name> [options]` — adapts the existing `new_profile()` auto-discovery
    logic to take `<name>` positionally (matching `instances create <name>` symmetry)
    instead of via `--name`; keeps `--mode`/`--output`/`--plugins`.
  - `profiles ls` — list profile names discovered across the three storage locations from
    `docs/ai-sandbox-profiles-spec.md`'s "Profile storage and discovery" section
    (project-local `./profiles/`, `$XDG_CONFIG_HOME/ai-sandbox/profiles/`, bundled),
    de-duplicated by discovery priority, with enough detail (source location? mode?) to be
    useful — task breakdown should look at `do_list()`'s instance-listing table format in
    `src/list.sh` for a consistent rendering convention.
  - Profile deletion, in whatever surface form the resolved question dictates — removing
    the profile YAML file. Needs a decision (left to task breakdown) on what happens for a
    bundled/read-only profile (almost certainly: refuse with a clear error, since bundled
    profiles ship with the install tree and aren't a per-user file to remove).
- Implement `instance_exists <name>` (factored out of `src/create.sh`'s inlined `docker ps
  -a` collision check into a reusable `src/utils.sh` helper) and `profile_exists <name>`
  (new, in the profiles module), and wire both into:
  - The `instances create <name>` / `profiles create <name>` collision check (requirement
    5: reject a name colliding with any existing instance, any existing profile, or a
    reserved word).
  - The per-name dispatch resolver stubbed in `dispatch-foundation`, completing the
    "resolve `<name>` to instance, profile, or neither" step and the verb-gating table
    (profile-appropriate verbs vs. instance-only verbs), including the clear "X is a
    profile, not an instance" (and vice versa) error message the user request specified.
- Ensure profile-kind dispatch for `detail`/delete short-circuits before the Docker
  pre-flight and profile-installer.js resolution phases in `src/index.sh` (see the
  architectural note in the audit doc) — a bare YAML file lookup should not require Docker
  to be running.

## Inputs

- Resolution of the profiles-delete-ambiguity open question (from the manager/user).
- `dispatch-foundation`'s reserved-word derivation function and name-resolution extension
  point.
- `docs/ai-sandbox-profiles-spec.md`'s storage/discovery order and schema (already read in
  full this session).
- `src/new-profile.sh` (current implementation fully read this session — auto-discovery
  logic, node/js-yaml boundary, flag parsing — all reusable, only the entry-point
  invocation shape changes from flag-based `--name` to positional `<name>`).

## Outputs

- `src/profiles.sh` (or equivalent rename) implementing `profiles ls`/`profiles
  create`/profile-deletion per the resolved surface.
- `instance_exists`/`profile_exists` helpers in `src/utils.sh` (or a new shared location),
  consumed by both the collision check and the per-name dispatch resolver.
- Completed per-name "resolve then verb-gate" dispatch layer in `src/options.sh`/
  `src/index.sh`, replacing the `dispatch-foundation` stub.
- Updated `src/list.sh` (or a new combined-listing function) for bare `ai-sandbox ls`'s
  grouped "Instances:" / "Profiles:" output.
