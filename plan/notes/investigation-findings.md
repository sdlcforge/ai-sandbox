# Investigation Findings — Lockdown Egress

## Purpose and scope

Detailed findings from investigating `ai-sandbox`'s egress-firewall defect,
referenced from `plan/overview.md`. All file paths are relative to
`/Users/zane/playground/ai-sandbox/worktrees/2026-07-10-lockdown-egress`
(the implementation branch), which was read directly for this investigation.

## Root cause 1: `init-firewall.sh` is never invoked

`docker/Dockerfile.base` (lines ~131-134) copies `init-firewall.sh` into the
image, `chmod +x`s it, and writes a passwordless-sudo entry for it
(`/etc/sudoers.d/node-firewall`) — but nothing in
`docker/rootfs/etc/cont-init.d/` (the s6-overlay init stage directory) calls
it. The existing stages are `01-setup-ssh`, `02-overlay-config`,
`04-write-credentials`, `05-install-claude`, `10-plugin-setup` — no `03-*`
exists. Grepping the whole repo for `init-firewall`, `NET_ADMIN`, `cap_add`
confirms: `cap_add` is used exactly once, in
`docker/docker-compose.isolate-config.yaml`, for `SYS_ADMIN` (the config
copy-on-write overlay's `mount()` need) — never for `NET_ADMIN`. Without
`CAP_NET_ADMIN`, every `iptables` call inside the container fails outright
regardless of whether the script runs.

**Confirmed cont-init.d execution context is root**, not the mirrored host
user: `01-setup-ssh` and `02-overlay-config` both call `chown`/`mount`
without any `sudo` prefix, which only succeeds as root under s6-overlay's
standard `cont-init.d` execution model. This means the new firewall
cont-init stage should invoke `init-firewall.sh` directly, not through the
existing sudoers entry (which was seemingly intended for a different,
never-implemented invocation path — likely a manual re-run from an
interactive user shell). The task doc for the fix instructs verifying this
at implementation time rather than assuming it, since it's a small,
cheaply-checked assumption.

## Root cause 2: even if invoked, the script restricts nothing

Reading `docker/init-firewall.sh` in full: it flushes all tables (`iptables
-F`, `-t nat -F`, `-t mangle -F`), destroys a stale `ipset` reference, then
appends `ACCEPT` rules for GitHub/Anthropic hosts and one localhost rule.
**It never sets `iptables -P OUTPUT DROP` (or any other default-deny
policy), and never appends a catch-all `DROP`/`REJECT` rule.** iptables'
built-in default chain policy is `ACCEPT`. A script that only ever adds
`ACCEPT` rules, on a chain whose policy is (and remains) `ACCEPT`, permits
*all* traffic — the explicit rules are functionally inert no-ops from a
restriction standpoint. This is a second, independent defect: fixing only
root cause 1 (wiring + capability) would still leave egress completely
open. This is why the plan requires the new e2e test to assert unreachability
of a disallowed host, not merely that `init-firewall.sh` ran or that
`CAP_NET_ADMIN` is present — either of those alone is necessary but not
sufficient evidence the fix works.

## The dangling `ipset` reference

`init-firewall.sh` line 15: `ipset destroy allowed-domains 2>/dev/null ||
true`. No `ipset create`/`ipset add` call exists anywhere in the current
script or repo. This is a harmless (via `|| true`) but dead remnant, almost
certainly inherited from a more elaborate ipset-based implementation (common
in similar "Claude Code devcontainer" firewall scripts that resolve GitHub's
published IP ranges into an ipset) that was stripped down to the current
simpler hostname-`ACCEPT`-rule form, leaving this one cleanup line behind.
Not load-bearing for this plan's requirements; flagged as a recommended
follow-up cleanup, not included as a task.

## Why the existing "Firewall rules" integration test never caught this

`test/integration/container_spec.sh`'s `Describe 'Firewall rules'` /
`It 'has iptables rules applied'` test (lines 161-167) does this:

```sh
./bin/ai-sandbox.sh --quiet root-exec zsh -c \
  "echo 'true' > /root/access-test.tmp && cat /root/access-test.tmp && rm /root/access-test.tmp"
```

This writes, reads, and deletes a local temp file as root and asserts the
output is `true`. It exercises **no networking at all** — not even an
`iptables -L` check. The name is misleading; it appears to have been
intended as a firewall smoke test at some point but never actually became
one. This is directly why the regression shipped undetected. Phase 1 Task 1
replaces this test with one that actually probes network reachability
and the firewall's applied state.

## The `network.allow` profile field is separately dead code

`docs/ai-sandbox-profiles-spec.md` documents a `network.allow` field
("Hostnames or CIDRs to add to the iptables allow-list. Extends the default
… V1 is additive only") and `bin/profile-installer.js` fully implements
parsing, validation, and composition-merge for it (`network_allow` appears
in the merged profile object and the JSON output block, lines ~270, ~295,
~331-332, ~511). **Nothing downstream ever reads it.** `src/index.sh` reads
`PROFILE_JSON` for `marketplaces`, `plugins`, and `enable_all_plugins` only
(lines 286-291) — `network_allow` is composed and emitted but silently
dropped. This is architecturally the same defect class as root causes 1/2
(a documented allow-list mechanism that does nothing), discovered via this
investigation rather than named in the original bug report.

### Why this becomes load-bearing for this plan, not just a follow-up

Today, with the firewall inert, `ai-sandbox start --add-marketplace
https://registry.example.com/plugins` (or any profile with `plugins:` from
a non-GitHub/Anthropic marketplace) works — nothing blocks the HTTPS call to
register it. **Once Phase 1 Task 2's default-deny lands, that call would
start failing** for any marketplace host other than github.com/anthropic.com,
silently regressing existing, working functionality, unless the fix also
allow-lists marketplace-derived hosts. Phase 1 Task 3 closes this gap by
deriving allow-list entries from `AI_SANDBOX_MARKETPLACES` (already computed
on the host in `src/index.sh`) and from the previously-dead
`network_allow`/`network.allow` field, at a default of port 443 (the spec
gives no port for either field; 443 matches the spec's own `api.example.com`
example and the fact that marketplace refs and any registration point are
necessarily HTTPS). This default is documented in `plan/overview.md`'s
"Assumptions and flagged items" for a decision-maker to confirm or override.

## The `docker` capability's socket-proxy sidecar needs an explicit rule too

`docker/docker-compose.proxy.yaml` attaches `docker-socket-proxy` on a
private Compose network (`docker-proxy`, `internal: true`) and points the
sandbox at `DOCKER_HOST=tcp://docker-socket-proxy:2375` when `--profile
docker` is active. This is itself outbound traffic from the `ai-sandbox`
container's network namespace and would traverse the `OUTPUT` chain like
any other egress. Once default-deny lands, `--profile docker` would silently
break unless an explicit `ACCEPT` rule for the sidecar (by container-DNS
name or by the compose-assigned bridge subnet) is added conditionally when
the `docker` capability is active. Phase 1 Task 2 must include this rule and
its validation must re-run `test/integration/docker_proxy_spec.sh` (existing,
currently-passing suite) to confirm no regression.

## `PROFILE_CAPABILITIES` is a host-side-only variable today

`src/index.sh` computes and exports `PROFILE_CAPABILITIES` (from
`bin/profile-installer.js`'s output) but only uses it on the host, via
`profile_has_capability()` (`src/utils.sh:113`), to decide which Dockerfile
fragments to assemble and which compose overlay files to include. It is
**not** passed into the running container's `environment:` block in
`docker/docker-compose.yaml` today — there has been no prior need, since
existing capabilities (`docker`, `chromium`) only affect what's installed at
build time, not runtime behavior. The three new network capabilities need
the *running* container (specifically, the new firewall cont-init stage) to
know which capabilities are active, so Phase 2 Task 1 adds a new
`AI_SANDBOX_CAPABILITIES` environment entry (the verbatim
`PROFILE_CAPABILITIES` value) to `docker-compose.yaml`, and the firewall
script filters it for the capability names it recognizes.

## `host.docker.internal` is already wired, and not macOS-exclusive

`docker/docker-compose.yaml` already has:

```yaml
extra_hosts:
  - "host.docker.internal:host-gateway"
```

The `host-gateway` special value has been supported since Docker Engine
20.10 on Linux as well as Docker Desktop (macOS/Windows) — so the *address
resolution* half of `host-access` is not a macOS-only gap. What *is*
macOS-specific in this plan's design is the **host-side command** used to
enumerate which TCP ports are currently listening on the host
(`lsof -iTCP -sTCP:LISTEN -n -P`) and to detect the host's LAN CIDR
(`route get default` + `ipconfig`/`ifconfig` parsing) for `lan-access` —
both are macOS command-line tools with different Linux equivalents (`ss
-ltnp`, `ip route`/`ip addr`) that this plan does not implement, consistent
with the project's macOS-first stance but explicitly flagged per the change
request's ask rather than silently assumed away.

## Existing precedent for CLI-flag-driven env passthrough

`--add-marketplace`/`CLI_MARKETPLACES` (`src/options.sh`) is the closest
existing precedent for `--allow-egress`: repeatable flag, array accumulator,
syntactic validation at parse time (scheme prefix check), `|`-joined string
passed into the container as an `AI_SANDBOX_*` env var, and participation in
the `ai.sandbox.config` label / `restore_saved_config()` /
`running_config_matches()` config-persistence contract described in
`docs/architecture.md`'s "Config persistence and restore" section. This
plan's `--allow-egress` design (Phase 3) follows the same shape end to end.

## Existing precedent for capability → Dockerfile-fragment assembly

`docker/scripts/assemble-dockerfile.sh` validates that every capability
named in a profile's resolved `capabilities` list has a matching
`docker/capabilities/<name>.dockerfile` fragment, and errors otherwise
(`error: unknown capability "%s" — fragment not found`). The three new
network capabilities need no image changes (no packages, no build steps),
but to avoid changing this validation invariant (and thus touching a
shared, load-bearing assembly script for an orthogonal reason), Phase 2's
tasks add trivial no-op (comment-only) Dockerfile fragments for
`web-search`, `host-access`, and `lan-access` rather than teaching the
assembler about a "network-only" capability kind. This is called out
explicitly in each Phase 2 implementation task as the recommended approach,
with the alternative (extending the assembler/installer to distinguish
capability kinds) named for the implementer to reconsider if a no-op
fragment turns out to be awkward in practice.
