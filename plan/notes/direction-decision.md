# Direction decision (Q-U1)

## Question

The planning agent could NOT reproduce the IPv6-only host.docker.internal
regression on an identical Docker Desktop 4.82.0/darwin-arm64 stack (that
machine gets a working IPv4 via host-gateway just fine) — so the failure
looks environment-dependent, not version-dependent. Given that, what should
this plan ship for V1?

Options offered: (1) caller-pinned `--add-host` flag only, (2) caller-pinned
flag + auto-detect IPv4 default, (3) wait for research before deciding.

## Answer

Caller-pinned --add-host flag only (Recommended)

(Chosen before the Docker Desktop networking research agent's findings
landed. Those findings — Docker Desktop's per-install `IPv6Only` network
mode setting legitimately omits the IPv4 vpnkit subnet, with no documented
host-side API to detect/override it — independently confirm this was the
right call: there is no reliable host-side auto-detection mechanism to
build option (b)/(2) on top of. Ship the caller-pinned `--add-host <name>:<ip>`
flag as the sole V1 mechanism.)
