# Investigation Findings — host.docker.internal IPv4 reachability

## Purpose and scope

Empirical characterization of the reported host.docker.internal regression, run
on the planning host, to ground the plan's scope decisions. The planning host's
Docker stack matches the downstream report's stack exactly.

## Planning-host Docker stack

- Docker Desktop 4.82.0 (233772)
- Client 29.6.1 / Engine 29.6.1, API 1.55
- Context: `desktop-linux`, OS/Arch `darwin/arm64`

This is the same Docker Desktop version, engine, context, and platform the
downstream report cites — so any behavior difference is *not* explained by a
version skew.

## What reproduced

**Default `/etc/hosts` no longer carries `host.docker.internal`.** Confirmed:

```
$ docker run --rm alpine cat /etc/hosts        # no host.docker.internal line
```

Docker Desktop 4.82.0 no longer auto-injects the entry by default. This matches
downstream report point 1. ai-sandbox is unaffected by *this* specific change on
its own, because `docker/docker-compose.yaml` already forces the entry via
`extra_hosts: ["host.docker.internal:host-gateway"]` (lines 167-168) — so
ai-sandbox containers never relied on the auto-injection.

## What did NOT reproduce (the load-bearing finding)

On this identical-versioned host, `host-gateway` still yields an **IPv4**
record, and `getent ahostsv4` still returns it:

```
$ docker run --rm --add-host=host.docker.internal:host-gateway alpine cat /etc/hosts
...
192.168.65.254       host.docker.internal      # IPv4 present
fdc4:f303:9324::254  host.docker.internal      # IPv6 also present

$ docker run --rm --add-host=host.docker.internal:host-gateway alpine getent hosts host.docker.internal
fdc4:f303:9324::254  host.docker.internal ...   # getent hosts prefers IPv6 (as init-firewall.sh already documents)

$ docker run --rm --add-host=host.docker.internal:host-gateway alpine getent ahostsv4 host.docker.internal
192.168.65.254  STREAM host.docker.internal     # IPv4 returned, exit 0
```

Confirmed identical on **Ubuntu 24.04 (glibc)** and on a **user-defined bridge
network** (what Compose creates), not just Alpine on the default bridge.

An explicit literal `--add-host=<name>:<ipv4>` also resolves cleanly:

```
$ docker run --rm --add-host=myhost:192.168.65.254 alpine getent ahostsv4 myhost
192.168.65.254  STREAM myhost                   # option (a) shape works
```

### Consequence for the regression claim

- Downstream report point 2 ("`host-gateway` resolves ONLY to IPv6, never
  IPv4") — **not reproduced here**. IPv4 is present.
- Downstream report point 3 ("`getent ahostsv4` returns empty") — **not
  reproduced here**. It returns 192.168.65.254, exit 0.

So `docker/init-firewall.sh`'s `host-access` capability
(`getent ahostsv4 host.docker.internal`, line ~248) is **not currently broken on
this host** — it resolves and would allow-list the IPv4 gateway as designed.

The IPv6 ULA prefix seen here (`fdc4:f303:9324::254`) is byte-identical to the
one in the downstream report, yet this host also has the IPv4 record and the
downstream host reportedly does not. The failure is therefore **environment-
variable** (some per-host / per-install Docker Desktop networking configuration),
not a universal property of Docker Desktop 4.82.0. Root cause of the downstream
divergence is unresolved here — see
[docker-desktop-4.82-networking.md](./docker-desktop-4.82-networking.md).

## Why this points to option (a) as the robust primary fix

Because resolution behavior is not uniform even at a fixed Docker Desktop
version, any fix that depends on ai-sandbox *detecting* or *relying on* what
`host-gateway` resolves to inherits that variance. A caller-supplied
`--add-host <name>:<ipv4>` pass-through (option (a)) sidesteps resolution
entirely: the caller pins the IPv4 it wants, and ai-sandbox threads it into the
container verbatim. This is the stable, documented contract the downstream
consumer (Flow) asked for and the one least exposed to Docker Desktop's shifting
networking defaults.

## Firewall-interaction subtlety (affects the documented contract)

`--add-host` only changes **name resolution** inside the container. In
mode/isolate configurations that run the default-deny egress firewall, adding a
host entry does **not** by itself grant egress to that IP. To actually *reach*
the pinned host under the firewall, the container also needs an egress
allowance:

- If the pinned name is `host.docker.internal`, the `host-access` capability
  already allow-lists `getent ahostsv4 host.docker.internal`'s IPv4 plus the
  host's LISTENing TCP ports — so a pinned IPv4 composes cleanly with
  `host-access` (getent returns the pinned IP, host-access allow-lists it).
- If the pinned name is anything else, `host-access` (hardcoded to
  `host.docker.internal`) will not cover it; the caller needs `--allow-egress
  <ip>:<port>` instead.

The documented contract for Flow must state this coupling: pinning a name is
necessary but, under the firewall, not sufficient without a matching egress
capability/flag.

## Option (b) feasibility subtlety (host-side detection)

The request suggests `compute_lan_cidr()` as the precedent for a host-side
gateway-IPv4 detector. Note the *value* differs:

- `compute_lan_cidr()` (`route get default` + `ipconfig getifaddr`) yields the
  **host's LAN IP** (e.g. `192.168.1.x`) — the physical-LAN address.
- host.docker.internal's target is the **Docker Desktop virtual gateway**
  (`192.168.65.254`) — a daemon-managed address that NATs to the host,
  *including host loopback services*.

These are not the same address, and they have different reachability semantics
(the Docker gateway reaches host services bound to `127.0.0.1`; the LAN IP only
reaches services bound to the LAN interface). So option (b) splits into:

- **(b1)** detect the Docker Desktop gateway IPv4 and pin it — preserves exact
  host.docker.internal semantics, but there is no obvious portable host-side
  command that yields `192.168.65.254` (it is not the default-bridge gateway
  `172.17.0.1`, nor the host LAN IP); feasibility is a research question.
- **(b2)** detect the host LAN IPv4 (compute_lan_cidr mechanism) and pin it —
  easy detection, but changes reachability semantics (loopback-only host
  services become unreachable).

This distinction is load-bearing for whether option (b) is even implementable as
described and must be settled by research before committing to it.
