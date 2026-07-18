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

## Status

**Outcome:** succeeded (2026-07-18).

**Requirement 1 scoping resolved:** `docker/init-firewall.sh` only ever runs
inside the `firewall-init` sidecar container (`docker/docker-compose.yaml`'s
`firewall-init` service invokes `/usr/local/bin/init-firewall-sidecar.sh`,
which itself execs `/usr/local/bin/init-firewall.sh`). That same service
already mounts the `firewall-handshake` volume at
`AI_SANDBOX_FIREWALL_MARKER_DIR` (`/var/lib/ai-sandbox-firewall`) and the
sidecar's own `mkdir -p`/`chmod 700` on that directory run *before* it invokes
`init-firewall.sh` — so the marker directory is already mounted, created, and
writable by the time the `host-access` branch runs. No coordination with
`init-firewall-sidecar.sh` was needed; `init-firewall.sh` writes the marker
directly.

**Requirement 1 implementation:** in the `host-access` case's `else` branch
(resolution failure), added a best-effort (`mkdir -p ... || true`, `|| true`
on the write) marker write to `${AI_SANDBOX_FIREWALL_MARKER_DIR:-/var/lib/ai-sandbox-firewall}/host-access-unresolved`,
containing a UTC timestamp + a one-line human-readable reason. On the
resolution-success path, added `rm -f "${_host_access_marker}" 2>/dev/null || true`
so a stale marker from a previous container lifecycle never survives a
successful re-resolution. Verified with a scripted harness (function stubs
for `iptables`/`getent`/`ip6tables` detection, real script execution against
a `mktemp -d` marker dir) exercising both the failure path (marker written,
script completes, no abort under `set -euo pipefail`) and the recovery path
(stale marker cleared on success) — not committed (scratchpad-only, per this
task's "manual/scripted demonstration is acceptable" validation note).

**Requirement 2 implementation:** added `_status_gather_host_access()` to
`src/status.sh`, called from `do_status()` alongside `_status_gather_config()`.
It reads the marker via `docker exec -u root <container> cat <marker-dir>/host-access-unresolved`
when the container is running; empty/absent otherwise. **`-u root` is
load-bearing, not decorative**: the marker directory is `chmod 700`
root-owned (`init-firewall-sidecar.sh`'s `security-005` invariant), but this
container's own default exec user is the non-root `${HOST_USER}`
(`docker/Dockerfile.base`'s final `USER`) — a plain `docker exec` without the
override would hit `EACCES` on the directory traversal and silently look
identical to "no marker present", masking a real resolution failure. This
was caught and fixed during this task's own implementation (not part of the
task doc's stated requirements, but required for Requirement 2 to actually
work) — flagging in case a related area independently assumed
default-user `docker exec` reads root-owned paths on this volume.
`_render_status_human()` emits a `Warnings:` section (only when the marker is
non-empty) with the exact wording the task doc suggested. `_render_status_json()`
adds a `host_access` object: `{"resolved": true}` when there is no marker
(covers "not running", "host-access inactive", and "resolved fine" alike —
deliberately not distinguished, since none need a warning), or
`{"resolved": false, "reason": "<marker content>"}` when present. Chose the
explicit `resolved: true` shape (rather than a `null`/absent field, the
`config` field's convention) so an automated JSON consumer never has to
special-case null/missing to detect "no problem" — this reads the
`## Validation` section's "resolved/true state" wording as calling for an
explicit `true`, not an absent key.

**Requirement 3:** unchanged — the resolution logic, the `else` branch's
existing `echo`, and the overall fail-soft (log-and-skip, container still
starts) contract are all untouched; the marker write is strictly additive and
`|| true`-guarded end to end.

**Requirement 4:** `make build` run after every `src/status.sh` edit;
`bin/ai-sandbox.sh` (gitignored build artifact) picks up the new
`_status_gather_host_access()` function. `docker/init-firewall.sh` was left
unrolled, as it's not part of the bash-rollup.

**New test coverage:** added a `do_status() — host-access resolution-failure
marker (phase-01/004)` `Describe` block to `test/unit/ai_sandbox_spec.sh`
(5 examples): no-marker human output, marker-present human output (`Warnings:`
line), no-`docker exec` call when the container isn't running, `--json`
`host_access.resolved: true` with no marker, `--json`
`host_access.resolved: false` + `reason` with a marker present, and a
dedicated regression example asserting the `-u root` flag on the `docker
exec` invocation (using a temp-file capture, since `_status_gather_host_access()`
runs inside a `$(...)` command substitution subshell — a plain shell-variable
assertion across that subshell boundary silently observed nothing, an
authoring mistake caught and fixed during this task, not an implementation
bug).

**Validation:**
- `make lint` — passes (shellcheck across `src/` and `docker/`, no new
  findings).
- `shellspec test/unit/ai_sandbox_spec.sh` — 278 examples, 7 failures; the 7
  are the same pre-existing `dispatchtest` end-to-end dispatch failures
  present on this branch before this task's changes (confirmed via `git
  stash` — 272 examples/7 failures baseline, same 7 identified cases). None
  of the 5 new host-access examples are among the failures.
- Resolution-succeeds / resolution-fails / re-resolution-clears-marker
  scenarios: demonstrated via the scripted harness described under
  Requirement 1 above (`docker/init-firewall.sh` run directly with stubbed
  `getent`/`iptables`, real marker-dir I/O) plus the `src/status.sh` unit
  tests covering the read/render side; no live Docker container was
  provisioned for this task (task 005 owns automated integration coverage
  per this task doc's own validation note).
</content>
