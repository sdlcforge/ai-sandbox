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
</content>
