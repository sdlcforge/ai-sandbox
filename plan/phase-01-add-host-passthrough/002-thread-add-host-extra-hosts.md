# Task: Thread Add-Host Entries Into Container extra_hosts

## Purpose and scope

Thread the caller-supplied `CLI_ADD_HOST` specs (parsed in task 001) into the
container's `extra_hosts`, so each `<name>:<ip>` entry lands in the container's
`/etc/hosts` and is resolvable via `getent ahostsv4 <name>`. This is the
mechanism that actually delivers the host-IPv4 pin to the running container.

Scope is **the compose-override threading only** — validation (task 001) and
config persistence / labels / `running_config_matches()` (task 003) are separate.

## Requirements

1. **Emit `extra_hosts` entries into the generated compose override.** The
   variable-length caller entries must go into `GENERATED_COMPOSE` (the
   per-instance override written by `generate_volume_override()` in
   `src/volume-override.sh`, invoked from `src/index.sh` line ~444), not
   interpolated into the static `docker/docker-compose.yaml` list. The base
   compose file already declares a static
   `extra_hosts: ["host.docker.internal:host-gateway"]`
   (`docker/docker-compose.yaml` lines ~167-168).
2. **Resolve Compose's `extra_hosts` merge semantics before implementing — this
   is load-bearing.** Docker Compose merges some sequence-valued keys by
   appending and others by replacing. Determine empirically (e.g.
   `docker compose -f base -f override config`) whether a second compose file's
   `extra_hosts` **appends to** or **replaces** the base list:
   - If Compose **appends**, emit only the caller entries in the override; the
     static `host.docker.internal:host-gateway` entry survives from the base
     file.
   - If Compose **replaces**, the override must re-emit the static
     `host.docker.internal:host-gateway` entry **plus** the caller entries, or
     the base host-gateway mapping (relied on by the `host-access` capability)
     would be lost. Guard against a caller who also passes
     `--add-host host.docker.internal:<ip>` — a duplicate `host.docker.internal`
     line: decide and document precedence (caller pin should win; a duplicate
     `/etc/hosts` entry for the same name is generally harmless but confirm the
     resulting resolution order is the caller's IP).
   Record the observed merge behavior in a code comment so future readers do not
   have to re-derive it.
3. **Extend `generate_volume_override()` (or add a sibling emission).** The
   function currently emits only a `volumes:` block under
   `services: ai-sandbox:`. Extend it to also emit an `extra_hosts:` block under
   the same service when `CLI_ADD_HOST` is non-empty, producing valid YAML in all
   cases (including the empty case — do not emit an empty `extra_hosts:` key that
   `docker compose config` would reject; omit the key entirely when there are no
   caller entries). `CLI_ADD_HOST` must be visible to this function — confirm it
   is exported/in-scope at the call site (task 001 exports it; the function runs
   in the same process as `src/index.sh`).
4. **Only the `ai-sandbox` service needs the entries** — the firewall-init
   sidecar shares `ai-sandbox`'s network namespace
   (`network_mode: "service:ai-sandbox"`, `docker/docker-compose.yaml` ~186), so
   it inherits `/etc/hosts` resolution and does not need its own `extra_hosts`.
   Confirm this holds for the sidecar's `getent` calls in
   `docker/init-firewall.sh` (they run in the shared netns).
5. **Rebuild the rollup** (`make build`) after `src/` edits.

## Validation

- `make lint` passes.
- `docker compose ... config` (with the generated override in the file list)
  renders a valid merged config; the `ai-sandbox` service's `extra_hosts`
  contains both `host.docker.internal:host-gateway` and each caller-supplied
  `<name>:<ip>`.
- Integration check (task 005 may own the automated form): a container started
  with `--add-host myhost:192.168.65.254` has `myhost` in `/etc/hosts` and
  `getent ahostsv4 myhost` returns `192.168.65.254` inside the container.
- With no `--add-host` flags, the generated override is still valid YAML and the
  container's `extra_hosts` is unchanged from baseline (only the static
  host-gateway entry).

## Metadata

architectural_impact: true

(Changes the container's host-resolution surface — a documented
container↔host network-topology data flow in `docs/architecture.md`.)

## Assumptions

- The firewall-interaction coupling (pinning a name does not by itself grant
  egress under the default-deny firewall) is a **documentation** concern owned by
  the doc-updates phase, not this task. This task only makes the name resolvable;
  reaching the pinned IP under the firewall still requires `host-access` (when
  the name is `host.docker.internal` and the port is host-listening) or
  `--allow-egress`. See [investigation findings](../notes/investigation-findings.md)
  §"Firewall-interaction subtlety".

## References

- `src/volume-override.sh` (whole file; the emission function to extend).
- `src/index.sh` lines ~440-444 (`GENERATED_COMPOSE` path,
  `generate_volume_override` call), ~506 (override added to `COMPOSE_FILES`).
- `docker/docker-compose.yaml` lines ~167-168 (static `extra_hosts`), ~186
  (sidecar `network_mode`).
- `docker/init-firewall.sh` lines ~211-283 (`host-access`, runs in shared netns).

## Status

**Outcome:** succeeded (2026-07-18).

`generate_volume_override()` (`src/volume-override.sh`) now also emits an
`extra_hosts:` block for the ai-sandbox service listing each `CLI_ADD_HOST`
spec, and omits the key entirely when `CLI_ADD_HOST` has no entries.

**Merge-semantics finding (Requirement 2):** empirically confirmed Docker
Compose (v5.3.0 here) **appends** a second `-f` file's `extra_hosts` list to
the base file's list — it does not replace it — for both sequence-form and
mapping-form `extra_hosts`. Verified via `docker compose ... config` and,
more importantly, by starting a real container from the merged files and
inspecting `/etc/hosts` directly (the two checks did not always agree on
*displayed list order*, only on final content — see the code comment in
`src/volume-override.sh` for detail). Per the task's append-branch
instruction, the override therefore emits only the caller-supplied entries;
the base file's static `host.docker.internal:host-gateway` entry survives
unmodified and is not re-emitted.

**Duplicate-`host.docker.internal` precedence — flagged, not solved here:**
the task's guard/precedence-decision language ("caller pin should win") is
written under the *replace*-semantics branch, which does not apply (append is
what Compose actually does). Under append semantics, if a caller also passes
`--add-host host.docker.internal:<ip>`, both the base's host-gateway mapping
and the caller's mapping land in `/etc/hosts`; which one a given resolver
prefers was not reliably controllable via plain compose-file concatenation
order in testing (observed `/etc/hosts` line order did not match simple
base-then-override concatenation). A compose-spec `!override` YAML merge tag
was found, empirically confirmed to force true replacement (tested against
both `config` output and a running container's `/etc/hosts`), and would let
the override achieve deterministic caller-wins precedence by fully
re-emitting `host.docker.internal:host-gateway` unless the caller supplied
their own — but using it is a mechanism the task document does not
contemplate, so it was left out of this implementation per "smallest correct
change." See `flagged_for_manager` in this task's structured report for the
disposition options.

**Requirement 4 (sidecar netns) confirmed empirically:** a `network_mode:
"service:X"` sidecar shares the exact same `/etc/hosts` content as the
service it targets, including custom `extra_hosts` entries, even though the
sidecar declares no `extra_hosts` of its own. Verified both with a minimal
compose reproduction and by running the real `firewall-init` sidecar
alongside `ai-sandbox` with a caller-supplied `--add-host` entry present
(sidecar exited 0, firewall applied and verified). No code change was needed
for `docker/init-firewall.sh` or the `firewall-init` service definition.

**Incidental fix (same-diff self-fix):** `generate_volume_override()`
referenced the global `CLI_ADD_HOST` array directly, which is only
initialized by `parse_options()` (`src/options.sh`). Several existing unit
tests in `test/unit/plugin_preflight_spec.sh` call
`generate_volume_override()` directly without going through
`parse_options()`, so under this repo's `set -euo pipefail`, referencing
`CLI_ADD_HOST` there raised `CLI_ADD_HOST: unbound variable` and broke 16
previously-passing unit-test examples. Fixed by taking a local,
nounset-safe copy of `CLI_ADD_HOST` (`add_host_entries`) at the top of
`generate_volume_override()` using the
`${CLI_ADD_HOST[@]+"${CLI_ADD_HOST[@]}"}` idiom, rather than referencing the
global directly. Also removed a stray `</content>` line that had been
appended to the end of this task document (artifact from document creation,
unrelated to this task's own content) while editing this file to add this
Status section.

**Validation:**
- `make lint` — passed (shellcheck clean across `src/`, `docker/`, `test/`).
- `docker compose -f docker/docker-compose.yaml -f <generated-override>
  config` — rendered a valid merged config in both the populated-`CLI_ADD_HOST`
  and empty-`CLI_ADD_HOST` cases; the `ai-sandbox` service's `extra_hosts`
  contained both `host.docker.internal:host-gateway` and each caller-supplied
  `<name>:<ip>` entry in the populated case, and only the static entry in the
  empty case.
- Integration check — executed manually (not automated as part of this
  task; task 005 owns the automated form per the task doc's own allowance):
  ran the real `./bin/ai-sandbox.sh start <name> --add-host
  myhost:192.168.65.254` end-to-end (`AI_SANDBOX_SKIP_PLUGIN_CHECK=1`, needed
  because this task agent itself runs as a host-side claude process — a
  documented, intentional bypass for exactly this situation, not a
  correctness compromise). Confirmed `myhost` present in the running
  container's `/etc/hosts` resolving to `192.168.65.254`, and `getent
  ahostsv4 myhost` returning `192.168.65.254`. Torn down afterward
  (`docker rm -f`, `docker network rm`); no lingering resources.
- No-`--add-host` baseline — confirmed via both the compose-config check
  above and the new unit tests in `test/unit/plugin_preflight_spec.sh`
  (`generate_volume_override()` describe block) that the generated override
  is still valid YAML and omits `extra_hosts:` entirely when there are no
  caller entries (covering both "CLI_ADD_HOST unset" and "CLI_ADD_HOST
  declared empty" call shapes).
- `make test.unit` — 311 examples, 7 failures, all 7 pre-confirmed present
  on the unmodified baseline (verified via `git stash` + rebuild + targeted
  rerun before implementing) and unrelated to this task's scope
  (pre-existing command-dispatch regressions in teardown/dropped-profile/
  fix-ssh test scenarios, `ai_sandbox_spec.sh` lines 3181-3395). Flagged for
  the manager; not fixed here.

**Assumptions applied:** none beyond the task doc's own `## Assumptions`
section (firewall-interaction documentation is out of scope, owned by the
doc-updates phase).

