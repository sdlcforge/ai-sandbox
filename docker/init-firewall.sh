#!/bin/bash
set -euo pipefail  # Exit on error, undefined vars, and pipeline failures
IFS=$'\n\t'        # Stricter word splitting (excludes space to handle filenames safely)

# 1. Flush existing filter/mangle rules and delete existing ipsets. The NAT
# table is deliberately left untouched (see note below) -- this script only
# needs to restrict the filter table's OUTPUT chain (see the "only OUTPUT
# needs restricting" note at the end of this file).
iptables -F                            # Flush all rules in the filter table
iptables -X                            # Delete all user-defined chains in filter table
iptables -t mangle -F                  # Flush all rules in the mangle table
iptables -t mangle -X                  # Delete all user-defined chains in mangle table
ipset destroy allowed-domains 2>/dev/null || true  # Destroy existing allowed-domains ipset if it exists

# NAT table: earlier revisions of this script also flushed `-t nat` (to
# reset Docker's embedded-DNS DNAT/SNAT rules on 127.0.0.11, then tried to
# restore just the captured rule lines matching "127.0.0.11"). That restore
# was broken: it captured the `-A ... -j DOCKER_OUTPUT`/`DOCKER_POSTROUTING`
# rule lines but not the `:DOCKER_OUTPUT`/`:DOCKER_POSTROUTING` chain
# declarations those rules jump to (those lines don't contain "127.0.0.11"),
# so once `-t nat -X` deleted the custom chains, restoring the rules alone
# failed silently (swallowed by `|| true`) -- permanently breaking DNS
# resolution for the rest of the container's life, since nothing else
# re-creates Docker's embedded-DNS redirect. This went unnoticed because the
# missing CAP_NET_ADMIN capability (root cause 1) always made every iptables
# call in this script fail before ever reaching this far. Since this
# script's job is the filter table's OUTPUT chain (egress allow-list), not
# NAT, the fix is simply to never touch `-t nat` here and leave Docker's own
# DNS plumbing alone.

# 2. Allow connections to github.com and all subdomains
#
# github.com itself is allow-listed by CIDR (140.82.112.0/20, GitHub's
# long-published, stable range for git/web -- every IP observed for
# github.com during implementation-time testing fell inside it), not by
# resolving the hostname to a single IP. github.com sits behind DNS
# round-robin across a pool of backend IPs with markedly uneven weighting
# (one backend answered only 1 of 60 test queries) -- a single
# `iptables -d github.com` snapshot only allow-lists whichever IP happened
# to answer at container-init time, so most later connections land on a
# different IP and get dropped under default-deny (empirically observed
# failure rates from ~15% up to ~83% across repeated single- and
# many-query-snapshot trials during implementation). The CIDR is
# deterministic and needs no DNS lookup at rule-insertion time at all.
iptables -A OUTPUT -p tcp -d 140.82.112.0/20 --dport 22 -j ACCEPT     # Allow SSH to github.com (git push/pull)
iptables -A OUTPUT -p tcp -d 140.82.112.0/20 --dport 443 -j ACCEPT    # Allow HTTPS to github.com
iptables -A OUTPUT -p tcp -d 140.82.112.0/20 --dport 80 -j ACCEPT     # Allow HTTP to github.com
#
# The remaining entries below resolve a literal hostname once, same as
# before, and are best-effort (`|| true`, matching this script's existing
# `ipset destroy ... || true` style): `iptables -d <hostname>` fails outright
# ("host/network `<name>' not found") if the hostname doesn't currently
# resolve. Two independent, pre-existing gaps here would otherwise abort the
# whole script under `set -e` before it ever reaches the default-deny rules
# at the end -- masked until now by root cause 1 (missing CAP_NET_ADMIN
# always failed every iptables call before reaching this far):
#   - The leading-dot entries (`.github.com` etc.) intend "and all
#     subdomains", but plain `iptables -d` has no such wildcard -- it tries
#     to resolve the literal string ".github.com", which is not a valid
#     hostname and never resolves.
#   - `githubusercontent.com` and `githubassets.com` (bare, no subdomain
#     prefix) have no DNS record of their own; only their subdomains
#     (e.g. raw.githubusercontent.com, github.githubassets.com) do.
# Fixing the underlying host list (real wildcard/subdomain coverage) is a
# separate, judgment-heavy decision outside this task's scope -- flagged
# for the manager rather than guessed at here. `|| true` keeps today's
# already-broken entries from blocking every other rule in this script,
# without changing which hosts are actually reachable relative to before.
# (anthropic.com, unlike github.com, resolved to the same single stable IP
# across every implementation-time test -- no CIDR/round-robin handling
# needed for it.)
iptables -A OUTPUT -p tcp -d .github.com --dport 22 -j ACCEPT || true           # Allow SSH to *.github.com subdomains
iptables -A OUTPUT -p tcp -d .github.com --dport 443 -j ACCEPT || true          # Allow HTTPS to *.github.com subdomains
iptables -A OUTPUT -p tcp -d .github.com --dport 80 -j ACCEPT || true           # Allow HTTP to *.github.com subdomains
iptables -A OUTPUT -p tcp -d githubusercontent.com --dport 443 -j ACCEPT || true      # Allow HTTPS to githubusercontent.com (raw content)
iptables -A OUTPUT -p tcp -d .githubusercontent.com --dport 443 -j ACCEPT || true     # Allow HTTPS to *.githubusercontent.com subdomains
iptables -A OUTPUT -p tcp -d githubassets.com --dport 443 -j ACCEPT || true           # Allow HTTPS to githubassets.com (static assets)
iptables -A OUTPUT -p tcp -d .githubassets.com --dport 443 -j ACCEPT || true          # Allow HTTPS to *.githubassets.com subdomains
iptables -A OUTPUT -p tcp -d anthropic.com --dport 443 -j ACCEPT || true           # Allow HTTPS to anthropic.com
iptables -A OUTPUT -p tcp -d .anthropic.com --dport 443 -j ACCEPT || true          # Allow HTTPS to *.anthropic.com subdomains

# 3. Loopback -- required for any process talking to itself/other local
# services over lo. This blanket loopback ACCEPT already covers the claude-mem
# MCP server on 127.0.0.1:37777 (an earlier revision had a separate rule for
# that single destination; it was a strict subset of this one, so it has been
# folded in here) as well as any other localhost-bound tooling. Docker's
# embedded-DNS redirect (127.0.0.11) also rides loopback and is permitted here.
iptables -A OUTPUT -o lo -j ACCEPT             # Allow all outbound loopback traffic

# 4. DNS resolution -- allow UDP/TCP 53 to the resolvers docker-compose.yaml's
# `dns:` block configures. Coupled to that config: if those resolvers ever
# change, these rules need updating too.
for resolver in 8.8.8.8 8.8.4.4; do
    iptables -A OUTPUT -p udp -d "${resolver}" --dport 53 -j ACCEPT   # Allow DNS (UDP) to ${resolver}
    iptables -A OUTPUT -p tcp -d "${resolver}" --dport 53 -j ACCEPT   # Allow DNS (TCP, for large responses) to ${resolver}
done

# 5. docker capability (docker-compose.proxy.yaml, enabled via --profile
# docker): the docker-socket-proxy sidecar is itself outbound traffic from
# this container's netns and needs an explicit rule under default-deny.
# Presence is inferred from DOCKER_HOST, which docker-compose.proxy.yaml sets
# only when the proxy overlay is in play -- the same "DOCKER_HOST doubles as
# a runtime detector" idiom already used in src/utils.sh's start_shell(). No
# other capability-state signal reaches the container at init time yet (see
# plan/phase-02-network-capabilities/001-*.md for AI_SANDBOX_CAPABILITIES,
# which generalizes this for the other network capabilities). This sidecar
# is a single Compose-managed container (not a round-robin/anycast service
# like github.com above), so a single resolution is sufficient and reliable.
if [ -n "${DOCKER_HOST:-}" ]; then
    docker_proxy_host="${DOCKER_HOST#tcp://}"
    docker_proxy_host="${docker_proxy_host%%:*}"
    iptables -A OUTPUT -p tcp -d "${docker_proxy_host}" --dport 2375 -j ACCEPT   # Allow HTTP to the docker-socket-proxy sidecar
fi

# 6. Marketplace hosts and profile `network.allow` entries -- both are
# computed on the host by src/index.sh (AI_SANDBOX_MARKETPLACES from
# --add-marketplace / profile `marketplaces:`, AI_SANDBOX_NETWORK_ALLOW from
# profile `network.allow:`) and passed through as container env vars by
# docker/docker-compose.yaml's environment: block. Both use the same '|'-join
# convention as the rest of the codebase (see AI_SANDBOX_MARKETPLACES in
# src/index.sh); split with the same `IFS='|' read -ra` idiom src/utils.sh's
# restore_saved_config() already uses for the same kind of value. Both
# default to port 443 -- see docs/ai-sandbox-profiles-spec.md's `network`
# field reference for the rationale (network.allow's example host is an
# HTTPS API; marketplace refs are validated elsewhere to be https:// or
# file://). Same one-time-resolution / best-effort caveat as the
# GitHub/Anthropic rules above applies to every entry here too (`|| true`):
# a hostname that doesn't currently resolve fails outright rather than
# aborting the whole script.
if [ -n "${AI_SANDBOX_MARKETPLACES:-}" ]; then
    IFS='|' read -ra _marketplace_entries <<< "${AI_SANDBOX_MARKETPLACES}"
    for _mp_entry in "${_marketplace_entries[@]}"; do
        case "${_mp_entry}" in
            file://*)
                continue    # No network component -- local path, nothing to allow-list.
                ;;
            https://*)
                _mp_host="${_mp_entry#https://}"
                _mp_host="${_mp_host%%/*}"
                if [ -n "${_mp_host}" ]; then
                    iptables -A OUTPUT -p tcp -d "${_mp_host}" --dport 443 -j ACCEPT || true   # Allow HTTPS to marketplace host
                fi
                ;;
            *)
                # profile-installer.js already rejects any scheme other than
                # https:// or file:// at composition time; this is defensive.
                continue
                ;;
        esac
    done
fi

if [ -n "${AI_SANDBOX_NETWORK_ALLOW:-}" ]; then
    IFS='|' read -ra _network_allow_entries <<< "${AI_SANDBOX_NETWORK_ALLOW}"
    for _na_entry in "${_network_allow_entries[@]}"; do
        # `iptables -d` accepts a bare hostname or a CIDR natively -- no extra
        # parsing/branching needed to distinguish the profiles-spec's
        # `10.0.0.0/8`-style CIDR example from a plain hostname like
        # `api.example.com`; both get the same port-443-only rule.
        iptables -A OUTPUT -p tcp -d "${_na_entry}" --dport 443 -j ACCEPT || true   # Allow HTTPS to network.allow entry
    done
fi

# -----------------------------------------------------------------------------
# Further capability/profile/CLI-driven dynamic rules are appended here by
# later init-firewall.sh revisions -- see
# plan/phase-02-network-capabilities/001-*.md
# -----------------------------------------------------------------------------

# 6.5. Capability-driven dynamic rules. AI_SANDBOX_CAPABILITIES (set by
# docker/docker-compose.yaml from the host's PROFILE_CAPABILITIES -- see
# src/index.sh and plan/notes/investigation-findings.md) is a space-separated
# list of the resolved profile's capability names. Each recognized
# network-capability token gets its rule block appended here, before the
# default-deny block below. A plain `case` inside a `for`-loop over the
# space-separated list is whole-token iteration, not substring matching, so
# it already satisfies the whole-token matching discipline
# src/plugin-conflicts.sh establishes elsewhere in this codebase (path-
# component/argv-token match, not substring) -- no regex-based matcher is
# needed here.
# This file's global `IFS=$'\n\t'` (top of file) excludes space, so plain
# `for _cap in ${AI_SANDBOX_CAPABILITIES:-}` would treat a multi-capability
# value (e.g. "web-search host-access") as a single token and silently match
# no `case` pattern. Split explicitly with the same command-scoped
# `IFS=' ' read -ra` idiom the marketplace/network.allow blocks above use for
# their '|'-delimited values, so this loop doesn't depend on the file-wide IFS.
IFS=' ' read -ra _capability_entries <<< "${AI_SANDBOX_CAPABILITIES:-}"

# Stale-marker guard (phase-01-review-fixes/002): the host-access-unresolved
# marker (written by the host-access case arm below, on the shared
# firewall-handshake volume that persists across container delete/recreate --
# see AI_SANDBOX_FIREWALL_MARKER_DIR's comment further down) is otherwise
# only ever cleared from inside that same case arm's own resolution-success
# branch. If a container is later recreated WITHOUT host-access in its
# capability set (e.g. switching profiles), that case arm never runs at all,
# so a marker left over from an earlier boot would survive indefinitely and
# src/status.sh's _status_gather_host_access() would keep reporting a false
# "host-access did not resolve" warning even though host-access is no longer
# active. Clear it here, unconditionally and independent of the
# per-capability dispatch loop below, whenever host-access is absent from
# this boot's capability list -- making the marker track "host-access is
# currently active AND currently unresolved" rather than "host-access was
# ever unresolved at some point in this volume's history". Best-effort
# (`|| true`), matching this whole script's fail-soft posture for marker I/O
# elsewhere (e.g. the host-access case arm's own `rm -f ... || true` below).
_host_access_requested=false
for _cap in "${_capability_entries[@]}"; do
    if [ "${_cap}" = "host-access" ]; then
        _host_access_requested=true
        break
    fi
done
if [ "${_host_access_requested}" = false ]; then
    rm -f "${AI_SANDBOX_FIREWALL_MARKER_DIR:-/var/lib/ai-sandbox-firewall}/host-access-unresolved" 2>/dev/null || true
fi

for _cap in "${_capability_entries[@]}"; do
    case "${_cap}" in
        web-search)
            # "Any non-private (public) IPv4 destination on port 443."
            # Dedicated chain: RETURN (skip this chain's own ACCEPT, fall
            # back to OUTPUT's later rules -- ultimately the default-deny
            # LOG/DROP below) for each RFC-reserved/private range, then
            # ACCEPT tcp/443 for everything else. The jump rule below is
            # the actual gate -- it only exists when web-search is active --
            # so the chain's own internal logic stays unconditional.
            iptables -N AI_SANDBOX_WEB_SEARCH
            iptables -A AI_SANDBOX_WEB_SEARCH -d 10.0.0.0/8 -j RETURN        # RFC 1918
            iptables -A AI_SANDBOX_WEB_SEARCH -d 172.16.0.0/12 -j RETURN     # RFC 1918
            iptables -A AI_SANDBOX_WEB_SEARCH -d 192.168.0.0/16 -j RETURN    # RFC 1918
            iptables -A AI_SANDBOX_WEB_SEARCH -d 127.0.0.0/8 -j RETURN       # loopback (already allowed via -o lo above; excluded here too for this chain's own correctness)
            iptables -A AI_SANDBOX_WEB_SEARCH -d 169.254.0.0/16 -j RETURN    # link-local
            iptables -A AI_SANDBOX_WEB_SEARCH -d 100.64.0.0/10 -j RETURN     # CGNAT
            iptables -A AI_SANDBOX_WEB_SEARCH -d 224.0.0.0/4 -j RETURN       # multicast
            iptables -A AI_SANDBOX_WEB_SEARCH -d 240.0.0.0/4 -j RETURN       # reserved
            iptables -A AI_SANDBOX_WEB_SEARCH -d 0.0.0.0/8 -j RETURN         # "this network"
            iptables -A AI_SANDBOX_WEB_SEARCH -p tcp --dport 443 -j ACCEPT   # Everything else: public IPv4 HTTPS
            iptables -A OUTPUT -p tcp --dport 443 -j AI_SANDBOX_WEB_SEARCH   # Gate: only wired in when web-search is active
            ;;
        host-access)
            # Allow egress to any TCP endpoint currently bound/listening on
            # the host system, reached via host.docker.internal (already
            # resolvable to the host gateway per docker-compose.yaml's
            # extra_hosts: host.docker.internal:host-gateway entry).
            # AI_SANDBOX_HOST_LISTEN_PORTS (space-separated, set by
            # src/index.sh's host-side `lsof -iTCP -sTCP:LISTEN` enumeration,
            # macOS-only -- see plan/phase-02-network-capabilities/003-*.md
            # for the documented Linux gap) is a snapshot taken once at
            # container-start time: a host service started after the
            # container is already running is not covered until the
            # container is recreated. TCP only, matching this whole script's
            # scope.
            #
            # `getent hosts host.docker.internal` (the naive/obvious choice)
            # was tried and confirmed *wrong* here: on both Alpine (musl) and
            # Ubuntu (glibc) test images, Docker Desktop's extra_hosts entry
            # resolves via `getent hosts` to host.docker.internal's IPv6
            # address only (an fdxx:... ULA), never the IPv4 one -- even
            # though /etc/hosts carries both records. Since this whole
            # firewall script is IPv4-only (`iptables`, not `ip6tables`, per
            # the codebase-wide convention -- see the IPv6 default-deny block
            # at the end of this file), an `iptables -d <that-IPv6-address>`
            # rule would either error or silently never match any IPv4
            # traffic, leaving host-access non-functional. `getent ahostsv4`
            # was confirmed (same two test images) to return the IPv4 address
            # host.docker.internal actually needs.
            # `|| true` on the tail of this pipeline is required, not
            # decorative: under `set -euo pipefail` (top of this file), a
            # `getent` resolution failure (e.g. host.docker.internal
            # transiently unresolvable) is the pipeline's only non-zero
            # stage -- awk/head both succeed trivially on empty input -- so
            # without `|| true` here the assignment's own exit status would
            # abort this whole script before the `else` branch below ever
            # got a chance to run. Same best-effort posture as every other
            # hostname-resolution call in this script (GitHub/marketplace/
            # network.allow blocks above).
            _host_access_ip="$(getent ahostsv4 host.docker.internal 2>/dev/null | awk '{print $1}' | head -n1 || true)"
            # Durable operator-visible signal (phase-01/004-host-access-visibility)
            # for this capability's own resolution-failure fail-soft path below,
            # distinct from AI_SANDBOX_FIREWALL_MARKER_DIR's existing
            # applied/applied-ipv6 handshake markers (init-firewall-sidecar.sh):
            # this marker records *this specific* capability's resolve-vs-skip
            # outcome, not the firewall-init handshake's overall completion.
            # This script (docker/init-firewall.sh) only ever runs inside the
            # firewall-init sidecar -- see docker/docker-compose.yaml's
            # firewall-init service (network_mode: service:ai-sandbox, the
            # firewall-handshake volume, AI_SANDBOX_FIREWALL_MARKER_DIR) and
            # init-firewall-sidecar.sh's invocation of
            # /usr/local/bin/init-firewall.sh below its token wait -- so the
            # marker directory is already mounted and writable by the time
            # this branch runs (the sidecar's own mkdir -p/chmod 700 happen
            # before it invokes this script). No coordination with the
            # sidecar script is needed; this script writes the marker
            # directly.
            _host_access_marker_dir="${AI_SANDBOX_FIREWALL_MARKER_DIR:-/var/lib/ai-sandbox-firewall}"
            _host_access_marker="${_host_access_marker_dir}/host-access-unresolved"
            if [ -n "${_host_access_ip}" ]; then
                # Clear any stale marker from a previous container lifecycle
                # now that resolution has succeeded, so the marker's mere
                # presence is an accurate *current*-state signal rather than a
                # leftover from an earlier failed boot. Best-effort (`|| true`)
                # -- matching this whole capability's fail-soft posture --
                # so a transient permission/mount hiccup here can never abort
                # firewall application.
                rm -f "${_host_access_marker}" 2>/dev/null || true

                # Dedicated chain, mirroring web-search's shape: the chain's
                # own ACCEPT rules are unconditional (one per listening
                # port); the OUTPUT jump rule below is the actual gate and
                # only exists when host-access is active. Scoping the jump
                # to -d "${_host_access_ip}" keeps this capability from
                # granting anything beyond the host gateway, regardless of
                # what other capabilities/rules are active.
                iptables -N AI_SANDBOX_HOST_ACCESS
                # Same file-wide-IFS hazard as the capability-dispatch loop
                # above: a real host almost always has 2+ listening ports, so
                # a multi-token AI_SANDBOX_HOST_LISTEN_PORTS is the common
                # case, not an edge case. Without an explicit split, the
                # whole value would land in `--dport` as one malformed
                # argument and iptables would reject the call -- and unlike
                # every hostname-resolution call above, this one has no
                # `|| true` to fall back on, so that failure would abort the
                # whole script under `set -e` before the default-deny block
                # below ever runs. Split with the same command-scoped
                # `IFS=' ' read -ra` idiom used above.
                IFS=' ' read -ra _host_listen_ports <<< "${AI_SANDBOX_HOST_LISTEN_PORTS:-}"
                for _port in "${_host_listen_ports[@]}"; do
                    iptables -A AI_SANDBOX_HOST_ACCESS -p tcp -d "${_host_access_ip}" --dport "${_port}" -j ACCEPT
                done
                iptables -A OUTPUT -p tcp -d "${_host_access_ip}" -j AI_SANDBOX_HOST_ACCESS   # Gate: only wired in when host-access is active
            else
                # host.docker.internal failed to resolve to an IPv4 address --
                # nothing to allow-list. Best-effort, matching this script's
                # existing `|| true` posture for hostnames that don't
                # currently resolve (see the GitHub/marketplace/network.allow
                # blocks above): log and continue rather than aborting the
                # whole script under `set -e`.
                echo "init-firewall.sh: host-access capability active but host.docker.internal did not resolve to an IPv4 address; skipping"
                # Durable marker (phase-01/004-host-access-visibility): the
                # stderr line above only reaches whoever happens to be
                # watching container-init logs at the moment it prints --
                # make the fail-soft skip discoverable after the fact too, via
                # `ai-sandbox detail`/status (src/status.sh's
                # _status_gather_host_access(), which reads this file with
                # `docker exec`, unaffected by the very egress firewall this
                # script builds since it runs host-side against the
                # container's process namespace, not through its network
                # stack). Best-effort end to end (`mkdir -p ... || true`,
                # `|| true` on the write): this is a visibility aid layered on
                # top of the fail-soft contract, never a reason to abort
                # container startup on its own.
                mkdir -p "${_host_access_marker_dir}" 2>/dev/null || true
                printf '%s host-access: host.docker.internal did not resolve to an IPv4 address; host-access allow-list not applied\n' \
                    "$(date -u +%Y-%m-%dT%H:%M:%SZ)" > "${_host_access_marker}" 2>/dev/null || true
            fi
            ;;
        lan-access)
            # "Allow egress to any IP address and port on the host's LAN
            # (local subnet)." AI_SANDBOX_LAN_CIDR is computed host-side
            # (src/index.sh -> src/utils.sh's compute_lan_cidr(), via macOS's
            # `route get default` + `ipconfig`) and is empty when detection
            # failed (no default route, VPN-only interface, unrecognized
            # netmask, non-macOS host) -- fail-soft by design (see
            # plan/phase-02-network-capabilities/005-*.md Requirement 1), so
            # an empty value here means "no rule to add", not an error.
            # Unlike host-access, this rule targets the CIDR directly (real
            # LAN IPs are routable from the container through Docker
            # Desktop's VM/NAT layer the same way general internet egress
            # already is) rather than host.docker.internal -- see
            # plan/notes/investigation-findings.md's "host.docker.internal is
            # already wired..." section for why the two capabilities need
            # different routing. TCP only (no UDP -- consistent with the rest
            # of this script), all ports (no --dport), per the change
            # request's literal "any IP address and port on the host's LAN";
            # UDP-based LAN use cases (e.g. mDNS/local discovery) are
            # explicitly out of scope for V1.
            if [ -n "${AI_SANDBOX_LAN_CIDR:-}" ]; then
                iptables -A OUTPUT -p tcp -d "${AI_SANDBOX_LAN_CIDR}" -j ACCEPT   # Allow all TCP to the host's LAN CIDR
            fi
            ;;
        *)
            # Unrecognized token (or a capability with no network-runtime
            # effect, e.g. docker/chromium) -- nothing to do here.
            ;;
    esac
done

# 6.6. --allow-egress CLI-driven dynamic rules
# (plan/phase-03-allow-egress-flag/002-wire-allow-egress-into-firewall.md).
# AI_SANDBOX_ALLOW_EGRESS is '|'-joined by src/index.sh from CLI_ALLOW_EGRESS
# (repeatable --allow-egress <host-or-ip-or-cidr>:<port>), the same join
# convention as AI_SANDBOX_MARKETPLACES/AI_SANDBOX_NETWORK_ALLOW above; split
# with the same command-scoped `IFS='|' read -ra` idiom those blocks use, so
# this loop doesn't depend on the file-wide IFS either.
#
# Each entry's host-part/port-part shape was already validated syntactically
# at CLI-parse time (src/options.sh's --allow-egress parser calls
# src/utils.sh's is_valid_egress_host()/is_valid_egress_port() directly) --
# this block
# does the semantic resolution: an IPv4-literal/CIDR host-part needs none: it
# is emitted directly. A hostname host-part is resolved here, via
# `getent ahostsv4`, rather than left for `iptables -d <hostname>` to resolve
# internally, because resolution must use the same DNS resolver the
# container's traffic will actually use (the 8.8.8.8/8.8.4.4 resolvers
# docker-compose.yaml's `dns:` block configures) -- resolving with a
# different resolver (e.g. one with split-horizon DNS) could silently
# allow-list the wrong IP(s) for what the container will actually connect to.
# `ahostsv4`, not the plain `getent hosts` this task doc's Requirement 2
# names: confirmed empirically during this task's manual validation (Status
# notes), matching the host-access capability's identical finding directly
# above, that `getent hosts` returns IPv6-only results for ordinary dual-
# stack hostnames on this image (e.g. example.com, registry.npmjs.org) even
# though they also have A records -- this script is IPv4-only (`iptables`,
# not `ip6tables`), so that would make the whole hostname-resolution path
# silently non-functional. `ahostsv4` still satisfies Requirement 2's actual
# rationale (same resolver the container's traffic uses); it just restricts
# results to the address family this script can act on.
#
# Resolution happens once, here, at container-init time: if a name's DNS
# answer changes afterward (DNS rebinding, or the operator's own
# infrastructure changing), the allow-listed IP(s) go stale until the
# container is recreated. This is the same limitation the pre-existing
# hardcoded GitHub/Anthropic hostname rules above already have (see
# plan/notes/investigation-findings.md) -- not a new gap this block
# introduces, and not solved here (see plan/overview.md's "Assumptions and
# flagged items", item 2).
if [ -n "${AI_SANDBOX_ALLOW_EGRESS:-}" ]; then
    IFS='|' read -ra _ae_entries <<< "${AI_SANDBOX_ALLOW_EGRESS}"
    for _ae_entry in "${_ae_entries[@]}"; do
        _ae_host="${_ae_entry%%:*}"
        _ae_port="${_ae_entry##*:}"
        # IPv4 literal or CIDR host-parts are digits/dots (optionally
        # followed by "/<prefix>") only; a hostname host-part can never take
        # that shape (src/utils.sh's is_valid_egress_host() already rejects
        # any dotted-quad-shaped string that isn't a valid IPv4 literal, so a
        # hostname reaching this script never collides with this check).
        if [[ "${_ae_host}" == */* ]] || [[ "${_ae_host}" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]]; then
            # IPv4 literal or CIDR -- no resolution needed.
            iptables -A OUTPUT -p tcp -d "${_ae_host}" --dport "${_ae_port}" -j ACCEPT || true   # Allow --allow-egress IP/CIDR entry
        else
            # Hostname -- resolve via getent ahostsv4 (see rationale above).
            # ahostsv4 repeats each IP once per socket type (STREAM/DGRAM/
            # RAW); `sort -u` collapses that down to the distinct resolved
            # IPs so a multi-IP hostname doesn't get triplicate identical
            # ACCEPT rules. `|| true` on the pipeline guards the same
            # set -euo pipefail hazard the host-access capability's getent
            # call above documents: a resolution failure would otherwise be
            # the pipeline's only non-zero stage and abort this whole
            # script. A malformed/unreachable --allow-egress name must not
            # prevent the container from starting -- log a warning and skip
            # it instead.
            _ae_resolved="$(getent ahostsv4 "${_ae_host}" 2>/dev/null | awk '{print $1}' | sort -u || true)"
            if [ -z "${_ae_resolved}" ]; then
                echo "init-firewall.sh: --allow-egress hostname '${_ae_host}' did not resolve; skipping"
                continue
            fi
            while IFS= read -r _ae_ip; do
                iptables -A OUTPUT -p tcp -d "${_ae_ip}" --dport "${_ae_port}" -j ACCEPT || true   # Allow --allow-egress resolved IP
            done <<< "${_ae_resolved}"
        fi
    done
fi

# 7. Default-deny: log then drop everything else that didn't match an ACCEPT
# rule above. Deliberately left as explicit rules (not `iptables -P OUTPUT
# DROP`) so a future manual re-run of this script (via the
# /etc/sudoers.d/node-firewall NOPASSWD entry) stays idempotent: if the chain
# *policy* were left DROP from a prior run, the `-F` flush above would not
# reset it, and the DNS lookups this script's own `-d <hostname>` rules
# perform while rebuilding the allow-list would themselves be blocked before
# any ACCEPT rule existed to permit them. Explicit rules avoid that trap
# because `-F` clears them along with everything else, so each run starts
# from a clean, fully-open rule list before this final block re-establishes
# default-deny. This also keeps the extension point above simple: later
# phases just need their `-A OUTPUT ... -j ACCEPT` calls to run earlier in
# this script than the two lines below, which is naturally true since they
# are inserted at the marked extension point.
# The --log-prefix string is asserted on by
# test/integration/container_spec.sh's "runs init-firewall.sh during
# container init" check (greps `iptables -S OUTPUT` for it) as proof this
# script ran to completion with the correct rules applied, not just that it
# started.
iptables -A OUTPUT -j LOG --log-prefix "ai-sandbox-egress-DROP: " --log-level 4   # Log every otherwise-unmatched OUTPUT packet
iptables -A OUTPUT -j DROP                                                       # Deny everything not explicitly allowed above

# Only OUTPUT is restricted here -- INPUT/FORWARD are left at their default
# ACCEPT policy. Return traffic on already-established outbound connections
# isn't gated by the OUTPUT default-deny either way, so this doesn't weaken
# the egress restriction.

# 8. IPv6 default-deny (security-003). The IPv4 policy above establishes
# defense-in-depth against the container's actual attack surface, but the
# `iptables` apt package (docker/Dockerfile.base) installs `ip6tables`
# alongside it, left at its default ACCEPT policy with no rules of its own --
# so any IPv6 route to the internet would bypass every rule above entirely.
# This block mirrors the IPv4 policy's *shape* (flush, loopback, final
# LOG+DROP catch-all) but deliberately does NOT mirror its ACCEPT rules:
#   - No IPv6 DNS resolver ACCEPT: docker-compose.yaml's `dns:` block
#     configures only IPv4 resolvers (8.8.8.8/8.8.4.4), so DNS already works
#     end-to-end over IPv4 and nothing in this container needs to resolve
#     over IPv6.
#   - No IPv6 ACCEPT for GitHub/Anthropic/marketplace/network.allow hosts:
#     none of those are confirmed IPv6-reachable, and this project is
#     macOS/Docker-Desktop-focused (IPv6 egress is not part of its supported
#     surface today).
# The simplest, most defensible default is therefore IPv6 fully blocked --
# loopback plus a catch-all DROP, nothing else -- rather than standing up a
# second allow-list to maintain for an address family nothing here depends
# on. If a host or capability later needs verified IPv6 reachability, add
# its ACCEPT rule in this block explicitly rather than loosening the
# default.
#
# Guarded on `command -v ip6tables`: some hosts/images may not ship
# ip6tables at all, in which case IPv6 is moot -- nothing is listening for
# it -- and a *missing* binary must not fail this script or block container
# startup. Once inside this block, though, no call is wrapped in `|| true`:
# if ip6tables IS present but a call fails outright (e.g. IPv6 disabled at
# the host kernel level), that failure propagates via `set -e` and aborts
# the whole script -- matching Task 002's fail-loud posture for the IPv4
# path (a present-but-broken ip6tables must surface loudly, not be silently
# swallowed).
if command -v ip6tables >/dev/null 2>&1; then
    ip6tables -F                    # Flush all rules in the filter table (IPv6)
    ip6tables -X                    # Delete all user-defined chains in filter table (IPv6)
    ip6tables -t mangle -F          # Flush all rules in the mangle table (IPv6)
    ip6tables -t mangle -X          # Delete all user-defined chains in mangle table (IPv6)

    ip6tables -A OUTPUT -o lo -j ACCEPT   # Allow all outbound loopback traffic (IPv6)

    # The --log-prefix string is asserted on by the firewall-init sidecar
    # (docker/init-firewall-sidecar.sh) before it will signal completion, and
    # transitively by test/integration/container_spec.sh's IPv6 assertion via
    # the sidecar's completion marker -- see init-firewall-sidecar.sh for why
    # the check has to live there rather than in-container.
    ip6tables -A OUTPUT -j LOG --log-prefix "ai-sandbox-egress-ipv6-DROP: " --log-level 4   # Log every otherwise-unmatched IPv6 OUTPUT packet
    ip6tables -A OUTPUT -j DROP                                                              # Deny everything not explicitly allowed above (IPv6)
else
    echo "init-firewall.sh: ip6tables not found; skipping IPv6 default-deny (IPv6 egress is moot without it)"
fi
