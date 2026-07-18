# Docker Desktop 4.82 `host-gateway` IPv4 availability research

## Summary

Docker Desktop 4.42 (July 2025-ish) introduced a first-class **networking mode** setting (Settings → Resources → Network) with three options: **Dual IPv4/IPv6** (default), **IPv4-only**, and **IPv6-only**, persisted in `~/Library/Group Containers/group.com.docker/settings.json` / `settings-store.json` as a boolean-ish `IPv6Only` field (alongside `networkType: gvisor|vpnkit`, `useVpnkit`, `vpnKitAllowedBindAddresses`, `vpnkitCIDR`, etc.). When the host is in Dual or IPv4-only mode, Docker Desktop provisions the vpnkit IPv4 NAT subnet (default `192.168.65.0/24`, auto-relocated since 4.50.0 if it conflicts with the host's real network) and writes **both** an IPv4 and an IPv6-ULA line for `host.docker.internal` into every container's `/etc/hosts` (confirmed empirically below). When a host is switched to (or defaults to) IPv6-only mode, that IPv4 vpnkit network is never provisioned, so `host-gateway` / `host.docker.internal` has no IPv4 address to hand out — `getent ahostsv4` legitimately returns empty, not a bug. This is per-install, user/policy-configurable state, not something tied to the Docker Desktop version string — which is why two machines on identical 4.82.0/Engine 29.6.1 builds can differ. **Recommendation: do not attempt host-side auto-detection/injection of a "the" IPv4 gateway address — there is no documented, stable API for it, the underlying subnet is explicitly documented as auto-relocatable, and on a genuinely IPv6-only-mode host no IPv4 address exists to detect at all. A caller-pinned `--add-host`/config override (with in-container `host-access` capability gracefully degrading/warning when no IPv4 record exists) is the only reliable approach for v1.**

## Root cause findings

- **Docker Desktop 4.42 added a tri-state networking mode** (Dual IPv4/IPv6 default, IPv4-only, IPv6-only) under Settings → Resources → Network, enforceable org-wide via Settings Management, plus "intelligent DNS resolution" that filters A/AAAA records to match the detected host stack. Confidence: **high** (Docker's own release announcement). Source: https://www.docker.com/blog/docker-desktop-4-42-native-ipv6-built-in-mcp-and-better-model-packaging/
  - Note: the "intelligent DNS resolution / record filtering" piece applies to Docker's embedded DNS resolver (127.0.0.11) for ordinary name lookups, and is a *separate* mechanism from the static `/etc/hosts` entries `host-gateway` produces — don't conflate the two when reading Docker's docs.
- **This setting is what's serialized as `IPv6Only` in `settings.json`/`settings-store.json`.** On this test machine (which *does* get an IPv4 host-gateway record), `IPv6Only: False`, `networkType: gvisor`, `useVpnkit: True`, `vpnkitCIDR: 192.168.65.0/24`. Confidence: **medium-high** — the key name and semantics line up exactly with the documented tri-state mode and with the observed behavior, but I did not get direct confirmation from a machine with `IPv6Only: True` (no access to the downstream reporter's machine) to prove the causal link end-to-end.
- **The vpnkit IPv4 subnet is documented as relocatable, not a fixed address.** Docker Desktop 4.50.0 added automatic detection to move the Docker/vpnkit subnet off `192.168.65.0/24` when it overlaps the host's real routes. There is a long history of user-configured overrides for this CIDR too (moby/vpnkit#427, Docker forums). Confidence: **high**. Sources: https://docs.docker.com/desktop/release-notes/ (4.50.0 entry), https://github.com/moby/vpnkit/issues/427, https://forums.docker.com/t/configure-vpnkits-internal-network-addresses/44270
- **`host-gateway` / `host.docker.internal` has a documented history of IPv6-related regressions and ambiguity going back years**, independent of the 4.42 feature — e.g. `host.docker.internal` resolving to an IPv6 address in an "unreachable" network as far back as 4.31.0 (docker/for-mac#7332), `localhost` resolving to `::1` instead of `127.0.0.1` after IPv6 was enabled (docker/for-mac#7269), and moby/moby#47055 (IPv4-only containers being handed IPv6 addresses on dual-stack networks). These show Docker Desktop's IPv4/IPv6 precedence for `host.docker.internal`-style names has been in flux release over release and is sensitive to per-host toggles, not just engine version. Confidence: **medium** (issue reports, not root-caused by maintainers in the fetched threads).
- **No evidence found of a VPN-software / multiple-active-interface / Virtualization-Framework-vs-QEMU root cause specific to 4.82** — searches turned up nothing tying backend choice (Apple Virtualization Framework vs QEMU) or VPN software directly to whether `host-gateway` gets an IPv4 record. The `networkType` (gvisor vs legacy vpnkit) and `IPv6Only` settings remain the best-documented lever. Confidence: **low** on ruling this out — absence of search hits isn't proof, just what's findable.
- **Docker's own compose/CLI docs describe `host-gateway` as resolving to "the internal IP address of the host"** without ever committing to IPv4-only or dual-stack semantics; separately, `extra_hosts`/`--add-host` are documented as supporting arbitrary IPv4 *or* IPv6 literal mappings, i.e. the mechanism itself is address-family-agnostic — Docker Desktop's *runtime* decides what family(ies) to populate. Confidence: **medium** (docs describe the mechanism generically; no explicit "may be IPv6-only" caveat was found in the primary Docker docs pages fetched, e.g. https://docs.docker.com/desktop/features/networking/networking-how-tos/ and https://docs.docker.com/desktop/features/networking/).

## Empirical results (this machine)

Machine: macOS darwin/arm64, Docker Desktop 4.82.0 (233772), Engine 29.6.1, context `desktop-linux`, `networkType: gvisor`, `IPv6Only: False`.

```
$ docker version
Server: Docker Desktop 4.82.0 (233772)
 Engine: Version: 29.6.1  ... OS/Arch: linux/arm64
Client: ... OS/Arch: darwin/arm64  Context: desktop-linux
```

```
$ docker run --rm --add-host=host.docker.internal:host-gateway alpine getent hosts host.docker.internal
fdc4:f303:9324::254  host.docker.internal  host.docker.internal
```
(`getent hosts` on Alpine/musl returned only the IPv6 line — musl's address-selection picks one representative record, and here it picked the IPv6 one, RFC 6724-style preference, even though the IPv4 line is present in `/etc/hosts` — see below. This alone would look identical to the "broken" report if you only ran plain `getent hosts`.)

```
$ docker run --rm --add-host=host.docker.internal:host-gateway alpine getent ahosts host.docker.internal
192.168.65.254  STREAM host.docker.internal
192.168.65.254  DGRAM  host.docker.internal
fdc4:f303:9324::254 STREAM host.docker.internal
fdc4:f303:9324::254 DGRAM  host.docker.internal
```

```
$ docker run --rm --add-host=host.docker.internal:host-gateway alpine getent ahostsv4 host.docker.internal
192.168.65.254  STREAM host.docker.internal
192.168.65.254  DGRAM  host.docker.internal
```
This is the exact command `docker/init-firewall.sh`'s `host-access` capability uses — **it succeeds on this machine**, corroborating the second (non-reproducing) data point from the prior investigation, not the downstream reporter's broken one.

```
$ docker run --rm --add-host=host.docker.internal:host-gateway alpine cat /etc/hosts
127.0.0.1	localhost
::1	localhost ip6-localhost ip6-loopback
fe00::	ip6-localnet
ff00::	ip6-mcastprefix
ff02::1	ip6-allnodes
ff02::2	ip6-allrouters
192.168.65.254	host.docker.internal
fdc4:f303:9324::254	host.docker.internal
172.17.0.2	c982b433e1ac
```
Both an IPv4 and an IPv6 line for `host.docker.internal` are written directly into `/etc/hosts` by Docker Desktop (`updateHostsFile: True` in settings.json) — this is a static write at container start, not a live DNS query.

```
$ docker network inspect bridge   # default bridge network, NOT the host-gateway mechanism
"EnableIPv4": true, "EnableIPv6": false,
"Subnet": "172.17.0.0/16", "Gateway": "172.17.0.1"
```
Confirms the default bridge gateway (`172.17.0.1`) is a distinct address from the Docker-Desktop-VM's host-gateway (`192.168.65.254`) — the two must not be conflated.

```
$ python3 -c "... parse settings.json ..."
IPv6Only = False
hostNetworkingEnabled = False
hostNetworkingPreferEnabled = False
kernelForUDP = True
networkType = gvisor
proxyLocalhostPort = 0
requireVmnetd = False
updateHostsFile = True
useVirtualizationFramework = True
useVpnkit = True
vpnKitAllowedBindAddresses = 0.0.0.0
vpnkitCIDR = 192.168.65.0/24
```
(`settings-store.json` has the equivalent `IPv6Only = False`, `NetworkType = gvisor`, `UseVirtualizationFramework = False` — the two files disagree slightly on `Use*VirtualizationFramework*`, suggesting `settings.json` reflects effective/active config while `settings-store.json` may lag or reflect a different snapshot; not investigated further.)

**Conclusion from this machine's data**: this is a third data point confirming the "working" (IPv4-present) case, with `IPv6Only: False` as the standout config flag matching the documented 4.42 tri-state Network mode. I did not have access to a genuinely IPv6-only-mode machine to directly confirm `IPv6Only: True` produces the reported empty `ahostsv4` result — that inference rests on the settings-key/feature-documentation match, not a direct repro.

## Recommendation

**No — ai-sandbox should not try to auto-detect/inject "the" Docker-Desktop-VM IPv4 gateway address host-side as a reliable, general mechanism.** Reasons:

1. **No documented, stable host-side API exists for it.** `docker context inspect`, `docker network inspect`, and `docker info` do not expose the vpnkit/gvisor VM's host-gateway IPv4 address — only the ordinary bridge network gateway (`172.17.0.1`), which is a different address entirely. The only places the address is discoverable are (a) in-container resolution of `host.docker.internal` (works only when the host isn't in IPv6-only mode) or (b) parsing Docker Desktop's undocumented internal `settings.json`/`settings-store.json` `vpnkitCIDR` field and guessing `.254`/`.1` — both fragile, unsupported surfaces that Docker has already changed shape on before (4.50.0 auto-relocation of the subnet) and could change again without notice.
2. **On a host actually configured for IPv6-only networking mode, there is no IPv4 gateway address to detect at all** — it's not a resolution failure to work around, it's the intended state of that install. Any host-side "detection" logic would need to also decide what to do when the answer is legitimately "none," which is functionally identical to just not having one.
3. **The variability is per-install/per-policy (Settings → Resources → Network, potentially enforced by org Settings Management), not per-version.** This matches the observed discrepancy between two machines on identical Docker Desktop/Engine versions. A host-side heuristic would need to re-derive Docker Desktop's own configuration state reliably across future Docker Desktop releases — brittle, and duplicative of information Docker Desktop already has and could change the shape of at any time.
4. A **caller-supplied `--add-host` / config-driven IPv4 pin** (i.e., let the operator specify the known-good host IPv4 address, or explicitly opt into "attempt in-container `getent ahostsv4 host.docker.internal` resolution, and clearly warn/degrade the `host-access` firewall capability if it comes back empty rather than silently producing a broken allow-list") is the only approach that works uniformly regardless of the host's networking mode, and doesn't depend on parsing Docker Desktop internals. This should be the v1 design; auto-detection convenience (e.g., "try `getent ahostsv4` in-container first, fall back to requiring an explicit override") can be layered on top as a best-effort nicety, never as the sole mechanism.

## Sources consulted

- https://www.docker.com/blog/docker-desktop-4-42-native-ipv6-built-in-mcp-and-better-model-packaging/ (tri-state Network mode, intelligent DNS resolution)
- https://docs.docker.com/desktop/release-notes/ (4.50.0 subnet auto-relocation; 4.60.0 `ping6 host.docker.internal` fix; 4.82.0 changelog scan — no explicit IPv6/host-gateway entry found for 4.82 itself)
- https://docs.docker.com/desktop/features/networking/networking-how-tos/ (DNS record filtering modes: Auto / Filter IPv4 / Filter IPv6 / No filtering)
- https://docs.docker.com/desktop/features/networking/ (host.docker.internal vs gateway.docker.internal distinction; general VM networking architecture)
- https://github.com/docker/for-mac/issues/7332 (host.docker.internal → IPv6 in "unreachable network", regression reported at 4.31.0, unresolved/untriaged as of fetch)
- https://github.com/docker/for-mac/issues/7269 (`localhost` → `::1` after IPv6 enablement)
- https://github.com/docker/for-mac/issues/6776 (IPv6-only host, Docker Desktop itself IPv4-only for its own login traffic — different symptom, same family of IPv4/IPv6 precedence bugs)
- https://github.com/moby/moby/issues/47055 and https://github.com/docker/cli/issues/4770 (IPv4-only containers handed IPv6 addresses on dual-stack networks — related precedence bug, not host-gateway specific)
- https://github.com/moby/vpnkit/issues/427, https://forums.docker.com/t/configure-vpnkits-internal-network-addresses/44270 (vpnkit CIDR configurability/overlap history)
- https://ounapuu.ee/posts/2024/12/20/docker-ipv6/ (general Docker Engine v27+ IPv6 context; not Docker-Desktop-specific, limited direct relevance)
- Empirical: this machine's `docker version`, `docker run --add-host=host.docker.internal:host-gateway ...`, `docker network inspect bridge`, and parsed `~/Library/Group Containers/group.com.docker/settings.json` / `settings-store.json`.
