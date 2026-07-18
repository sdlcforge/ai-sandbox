# Platform scope decision (Q-U4)

## Question

If the plan includes auto-detecting a host-gateway IPv4 address host-side
(option b), should that detection step be macOS-only for V1 (matching the
project's existing macOS-first stance for `compute_lan_cidr()`/host-listen-
port enumeration), or does it need to work cross-platform now?

## Answer

Not applicable — only shipping the caller-pinned flag.

Per the Q-U1 direction decision, this plan does not include host-side
IPv4-gateway auto-detection (option b) at all — only the caller-pinned
`--add-host <name>:<ip>` flag, which is inherently cross-platform since the
caller supplies the IP directly. No platform-scoping decision is needed.
