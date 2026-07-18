# host-access capability scope decision (Q-U2)

## Question

docker/init-firewall.sh's existing host-access capability independently
resolves host.docker.internal via `getent ahostsv4` and is plausibly (but
not confirmed on this machine) broken by the same regression downstream —
it currently just logs a warning and silently allow-lists nothing if
resolution fails. What should this plan do about it?

Options offered: (1) harden visibility only, (2) reroute host-access to
also consume the pinned host, (3) defer entirely to a followup.

## Answer

Harden visibility only (Recommended)

Keep host-access's current fail-soft behavior (log-and-skip when
`getent ahostsv4 host.docker.internal` returns nothing) but make the
failure impossible to miss — e.g. surface it in `ai-sandbox detail`/status
output, not just a stderr log line during container init. This is
low-cost and doesn't depend on the Q-U1 direction decision. Do not couple
host-access's own resolution path to the new caller-pinned `--add-host`
flag in this plan — that coupling is explicitly out of scope for V1.
