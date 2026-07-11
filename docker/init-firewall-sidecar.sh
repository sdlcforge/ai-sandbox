#!/bin/bash
# Firewall-init sidecar entrypoint. Runs inside a throwaway container that holds
# CAP_NET_ADMIN and shares the ai-sandbox container's network namespace (see the
# firewall-init service in docker/docker-compose.yaml). It applies the
# default-deny egress firewall into that shared namespace once, verifies the
# rules actually landed, records a completion marker on the shared
# firewall-handshake volume, and exits.
#
# The ai-sandbox container itself does NOT hold CAP_NET_ADMIN (security-001): it
# carries a broad NOPASSWD sudo grant, so if it could touch iptables a
# prompt-injected agent could `sudo iptables -F` and disable the firewall. By
# holding the capability here instead -- in a container the agent cannot reach
# -- the firewall becomes non-bypassable from inside the sandbox. ai-sandbox's
# own 03-init-firewall cont-init stage blocks on the marker this script writes
# before letting any later init stage or agent process send egress.
set -euo pipefail  # Exit on error, undefined vars, and pipeline failures
IFS=$'\n\t'        # Stricter word splitting (matches init-firewall.sh)

MARKER_DIR="${AI_SANDBOX_FIREWALL_MARKER_DIR:-/var/lib/ai-sandbox-firewall}"
MARKER="${MARKER_DIR}/applied"
# Per-boot token written by ai-sandbox's 03-init-firewall stage as its very
# first action (007-nonce-based-firewall-handshake). We wait for it below,
# read it, then echo the same value back into MARKER (and IPV6_MARKER) once
# the firewall is verified applied -- single-sourced name, 03-init-firewall
# reads/writes the same path.
TOKEN_FILE="${MARKER_DIR}/expected-token"
# Bound on how long to wait for 03-init-firewall's token (Assumptions,
# 007-nonce-based-firewall-handshake): writing the token is 03-init-firewall's
# very first action, so this handshake step should be near-instant relative to
# the ~1-2s of DNS lookups and rule application that follows -- but must not
# assume zero delay, so we still bound it with a clear failure mode rather
# than waiting forever if 03-init-firewall never runs at all (itself a sign of
# a deeper problem).
TOKEN_WAIT_TIMEOUT="${AI_SANDBOX_FIREWALL_TOKEN_WAIT_TIMEOUT:-30}"
TOKEN_POLL_INTERVAL=0.2
# Second marker, specifically for the IPv6 policy (security-003). ai-sandbox
# itself never holds CAP_NET_ADMIN (security-001), so unlike this sidecar it
# cannot run `ip6tables -S` to check its own namespace's IPv6 rules directly.
# This sidecar -- which does hold NET_ADMIN -- performs that check here and
# records the verified result as this marker's *content*, so
# test/integration/container_spec.sh can assert on trustworthy evidence of
# the actual applied IPv6 policy (via a plain file read, which needs no
# special capability) instead of either querying ip6tables from a container
# that cannot, or a live `curl -6` probe that would false-pass on hosts with
# no IPv6 route at all (e.g. Docker Desktop's default bridge network).
IPV6_MARKER="${MARKER_DIR}/applied-ipv6"
# Must match the LOG --log-prefix init-firewall.sh sets immediately before its
# default-deny DROP (and the prefix test/integration/container_spec.sh asserts
# on). Greping for it proves the rules are actually in place before we signal
# success, so the marker means "rules applied and verified", not merely
# "script started".
FIREWALL_LOG_PREFIX='ai-sandbox-egress-DROP'
# IPv6 counterpart -- see init-firewall.sh's IPv6 section for why it uses a
# distinct log prefix rather than reusing the IPv4 one.
FIREWALL_LOG_PREFIX_V6='ai-sandbox-egress-ipv6-DROP'

# The marker directory is the shared handshake volume's mountpoint (already
# present via the volume mount); mkdir -p is defensive. chmod 700 makes the
# write-restriction (only this root-run sidecar and 03-init-firewall, also
# root-run, ever touch this directory) a stated invariant rather than an
# artifact of default umask (security-005).
mkdir -p "${MARKER_DIR}"
chmod 700 "${MARKER_DIR}"

# Wait for ai-sandbox's 03-init-firewall stage to write its fresh per-boot
# token (007-nonce-based-firewall-handshake, replacing 006's producer-side
# `rm -f` of any stale marker). Content comparison, not marker-clearing,
# is what makes this handshake race-free now: this sidecar has no dependency
# on ai-sandbox's own cont-init.d stages having run -- only on the shared
# network namespace existing, which is true the instant ai-sandbox's
# container starts -- so it can plausibly reach this point before
# 03-init-firewall has even generated its token (03-init-firewall must first
# run s6-overlay's own bootstrap plus 01-setup-ssh and 02-overlay-config
# before it even reaches stage 03). The old existence-only handshake handled
# that ordering by having the producer clear any leftover marker first, which
# in turn reopened the *opposite* race on a container restart: a leftover
# marker from a previous lifecycle could satisfy 03-init-firewall's poll
# before this sidecar's `rm -f` for the current lifecycle executed, causing
# 03-init-firewall to observe a stale "already applied" marker and start the
# container with no firewall rules in its fresh network namespace (fail
# open). Waiting for and echoing back 03-init-firewall's own per-boot token
# closes both directions at once: MARKER's content only ever matches the
# token the CURRENT lifecycle's 03-init-firewall generated, so a stale
# leftover marker (carrying a different, previous-lifecycle token) can never
# be mistaken for current-lifecycle completion, and there is no
# clear-before-write step left to race in the first place.
#
# NOTE (self-review finding, see this task's Status notes): TOKEN_FILE
# itself also persists across restarts, and reading it on mere existence
# has a narrower, fail-closed-only exposure symmetric to the one above --
# if this sidecar reads it before 03-init-firewall has overwritten a stale
# leftover value with its fresh one, the marker gets signed with the wrong
# token, and 03-init-firewall's own content check (correctly) never accepts
# it, timing out instead of succeeding. This cannot cause a false success
# (no fail-open regression -- MARKER content-equality is what the consumer
# actually trusts), only a spurious-but-safe abort in a narrow timing
# window. A content-only fix attempted during implementation
# (snapshot-and-wait-for-change) closed that window but reintroduced a
# regression in the *opposite*, explicitly-validated direction (this
# task's own inverted-race scenario), so it was not kept; see Status notes
# and flagged_for_manager for the empirical detail.
# TOKEN_POLL_INTERVAL is fixed at 0.2s (5 polls/second); derive the iteration
# budget from TOKEN_WAIT_TIMEOUT in whole seconds rather than doing
# floating-point arithmetic in bash.
token_wait_iterations=$((TOKEN_WAIT_TIMEOUT * 5))
iterations=0
token=''
while [ -z "${token}" ]; do
  if [ -e "${TOKEN_FILE}" ]; then
    token="$(cat "${TOKEN_FILE}")"
    break
  fi
  if [ "${iterations}" -ge "${token_wait_iterations}" ]; then
    echo "firewall-init: ai-sandbox's 03-init-firewall did not write a boot token within ${TOKEN_WAIT_TIMEOUT}s;" >&2
    echo "               refusing to proceed (is the 03-init-firewall stage running?)" >&2
    exit 1
  fi
  sleep "${TOKEN_POLL_INTERVAL}"
  iterations=$((iterations + 1))
done

# Apply the egress allow-list + default-deny into the shared network namespace.
/usr/local/bin/init-firewall.sh

# Never signal completion for a run that did not land its default-deny rule:
# fail loudly instead, so ai-sandbox's wait stage times out and refuses to
# start rather than running unprotected.
if ! iptables -S OUTPUT | grep -q "${FIREWALL_LOG_PREFIX}"; then
  echo "firewall-init: default-deny rule (${FIREWALL_LOG_PREFIX}) not found after init-firewall.sh; refusing to signal completion" >&2
  exit 1
fi

# IPv6: verify the mirrored default-deny landed too, or record that it was
# skipped because ip6tables isn't available on this host (init-firewall.sh's
# own guard). A present-but-broken ip6tables would already have aborted
# init-firewall.sh above via `set -e` (fail-loud, per Task 002's posture), so
# reaching this point with the binary present but the rule missing should
# not happen -- but we still refuse to signal completion rather than assume,
# matching the IPv4 check's belt-and-suspenders verification immediately
# above.
if command -v ip6tables >/dev/null 2>&1; then
  if ! ip6tables -S OUTPUT | grep -q "${FIREWALL_LOG_PREFIX_V6}"; then
    echo "firewall-init: ipv6 default-deny rule (${FIREWALL_LOG_PREFIX_V6}) not found after init-firewall.sh; refusing to signal completion" >&2
    exit 1
  fi
  ipv6_status='applied'
else
  ipv6_status='skipped: ip6tables unavailable on this host'
fi

# Signal completion to ai-sandbox's 03-init-firewall wait stage by echoing
# back the SAME token it generated and wrote to TOKEN_FILE
# (007-nonce-based-firewall-handshake). MARKER_DIR was already created (and
# chmod 700'd) above, so no mkdir -p is needed here. Do not write a marker
# whose content doesn't match the token read above: MARKER's content is what
# lets 03-init-firewall distinguish "applied for THIS lifecycle" from a
# leftover marker carrying a stale, previous-lifecycle token. IPV6_MARKER
# keeps the applied/skipped distinction Task 005 established, now
# token-qualified the same way so a stale IPv6 marker is equally
# distinguishable from a current one. Both are written via a temp file +
# atomic rename (same directory/filesystem), matching TOKEN_FILE's write
# above, so 03-init-firewall's poll loop can never observe a torn/truncated
# read -- only "not yet present" or "complete".
marker_tmp="$(mktemp "${MARKER_DIR}/.applied.XXXXXX")"
echo "${token}" > "${marker_tmp}"
mv -f "${marker_tmp}" "${MARKER}"
ipv6_marker_tmp="$(mktemp "${MARKER_DIR}/.applied-ipv6.XXXXXX")"
echo "${token} ${ipv6_status}" > "${ipv6_marker_tmp}"
mv -f "${ipv6_marker_tmp}" "${IPV6_MARKER}"
echo "firewall-init: egress firewall applied and verified; wrote ${MARKER}"
echo "firewall-init: ipv6 status: ${ipv6_status}"
