# Task: Surface host-access Resolution Failure In Status Output

## Purpose and scope

Make a `host-access` capability resolution failure **visible** in
`ai-sandbox detail`/status output. Today, when the `host-access` capability is
active but `getent ahostsv4 host.docker.internal` returns no IPv4 address,
`docker/init-firewall.sh` logs a single stderr line during container init and
then silently allow-lists nothing — the operator gets no durable, discoverable
signal that host-access is effectively a no-op. This is the exact failure mode
the downstream regression report describes.

Per the [host-access scope decision](../notes/host-access-scope.md), this task
**preserves the existing fail-soft behavior** (log-and-skip; the container still
starts). It does **not** reroute host-access to consume the new `--add-host`
pin, and does **not** change the resolution logic. It only adds a durable,
operator-visible signal.

## Requirements

1. **Record a durable marker on the resolution-failure path.** In
   `docker/init-firewall.sh`'s `host-access` `else` branch (lines ~274-282,
   where `_host_access_ip` is empty), in addition to the existing `echo`, write
   a small marker file onto the shared firewall-handshake volume — the marker
   directory is `${AI_SANDBOX_FIREWALL_MARKER_DIR:-/var/lib/ai-sandbox-firewall}`
   (see `docker/init-firewall-sidecar.sh` lines ~19-20 for the convention). Use a
   distinct filename, e.g. `host-access-unresolved`, with brief human-readable
   content (e.g. a timestamp + the reason). Correspondingly, on the **success**
   path (lines ~249-273) ensure any stale marker from a previous lifecycle is
   removed (`rm -f`), so the marker's presence is an accurate current-state
   signal, not a leftover. Match the script's `set -euo pipefail` posture — the
   marker write must not be able to abort the script (best-effort, `|| true` if
   needed), consistent with the fail-soft contract.
   - Confirm which script actually executes this branch: `docker/init-firewall.sh`
     runs in the netns-sharing context; verify whether the marker directory is
     mounted and writable at the point this branch runs (the handshake volume is
     mounted on both the sidecar and ai-sandbox — see
     `docker/docker-compose.yaml` lines ~112, ~219). If `init-firewall.sh` runs
     where the volume is not yet mounted/writable, coordinate the marker write
     with `init-firewall-sidecar.sh` instead. Resolve this concretely before
     implementing.
2. **Surface the marker in `src/status.sh` (`do_status`).** Add a gather step
   (a `_status_gather_host_access` helper alongside `_status_gather_config`,
   `src/status.sh` ~215) that, when the container is running, reads the marker —
   e.g. `docker exec <container> cat <marker-dir>/host-access-unresolved`
   (a host-side `docker exec` is unaffected by the container's egress firewall).
   Pass the result to both renderers:
   - **Human** (`_render_status_human`): emit a clearly-labeled warning line/
     section, e.g. under a `Warnings:` or `Network:` heading — something like
     `host-access: host.docker.internal did not resolve to an IPv4 address; no
     host ports allow-listed`. Only shown when the marker is present.
   - **JSON** (`_render_status_json`): add a field (e.g.
     `host_access.resolved: false` with a `reason`, or a `warnings` array entry)
     so automated consumers can detect it. Absent/`true` when there is no marker.
3. **Do not regress the fail-soft init path** — the container must still start
   normally when resolution fails; this task adds a signal, not a hard failure.
4. **Rebuild the rollup** (`make build`) after `src/` edits. (`docker/*.sh` files
   are not part of the bash-rollup; they ship as-is.)

## Validation

- `make lint` passes (shellcheck across `src/` and `docker/`).
- With a container where `host.docker.internal` resolves to an IPv4 (the normal
  case on the planning host), `host-access` active: no marker, and
  `ai-sandbox detail` shows no host-access warning; `--json` shows the
  resolved/true state.
- With resolution forced to fail (e.g. a test harness that makes
  `getent ahostsv4 host.docker.internal` return empty, or an environment
  reproducing the IPv6-only condition): the marker is written, the container
  still starts, `ai-sandbox detail` shows the warning, and `--json` surfaces the
  failure field. (Task 005 owns any automated form of this; a manual/scripted
  demonstration is acceptable here.)
- Re-running with resolution succeeding clears the marker (no stale warning).

## Metadata

architectural_impact: true

(Adds a new firewall-init → host status-output diagnostic data flow across the
container/host boundary, over the documented firewall-handshake volume in
`docs/architecture.md`.)

## References

- `docker/init-firewall.sh` lines ~211-283 (`host-access` capability; the
  success and `else`/fail branches).
- `docker/init-firewall-sidecar.sh` lines ~19-46, ~153-170 (marker-dir
  convention and marker-write pattern on the handshake volume).
- `docker/docker-compose.yaml` lines ~112, ~219 (firewall-handshake volume
  mounts), ~163, ~217 (`AI_SANDBOX_FIREWALL_MARKER_DIR`).
- `src/status.sh` lines ~209-237 (`do_status`), ~92-207 (render helpers and the
  gather-helper pattern).
- [host-access scope decision](../notes/host-access-scope.md).
</content>
