# Plan Summary: lockdown-egress

## What was planned and why

`ai-sandbox`'s README claimed the container's outbound network was "clamped
via `iptables` to the handful of hosts an agent actually needs." Investigation
found this was false: `docker/init-firewall.sh` was baked into the image but
**never invoked** (no `cont-init.d` stage, no `CAP_NET_ADMIN` grant), and even
if invoked, the script never set a default-deny policy — it only appended
`ACCEPT` rules on top of iptables' default `ACCEPT` chain policy, so egress
was completely unrestricted regardless. This plan bundled four deliverables:
(1) an end-to-end test proving the regression before any fix landed, (2) the
actual firewall fix, (3) three new opt-in network-capability profiles
(`web-search`, `host-access`, `lan-access`), and (4) a new `--allow-egress`
CLI flag for ad-hoc allow-listing. The user explicitly asked "should we
consider anything else?" before implementation began — several design
questions (DNS re-resolution/TTL, macOS-only host detection, precedence
across combined grants, logging) were surfaced and answered up front (see
`plan/notes/investigation-findings.md` and the plan's original Q&A).

## What shipped

### Phase 1 — Firewall Enforcement Foundation (7 tasks)

The firewall is now genuinely enforced, after three escalating rounds of
security hardening triggered by phase-review findings — not merely made
operational on the first pass:

1. **Author Failing Egress Test** — replaced the misleading, network-blind
   `Describe 'Firewall rules'` test (which only touched a local temp file)
   with real assertions; proved 3/4 red on the unfixed baseline.
2. **Wire Firewall Init and NET_ADMIN** — granted `CAP_NET_ADMIN` directly to
   `ai-sandbox`, wired `init-firewall.sh` into a new `03-init-firewall`
   cont-init.d stage, added default-deny. Fixed two additional latent
   defects surfaced by getting the script to actually run for the first time
   (a broken NAT-restore that permanently killed DNS; several
   never-resolving per-host rules that aborted the whole script under
   `set -e`). Switched `github.com` to its published `140.82.112.0/20` CIDR
   after empirical testing showed single-IP DNS snapshots failed 15–83% of
   the time against round-robin.
3. **Wire Profile and Marketplace Allowlist** — closed a second, independently
   discovered dead-code path: the profiles-spec's `network.allow` field and
   `--add-marketplace` hosts were composed on the host but never consumed by
   the firewall; wiring them through was necessary to avoid Task 2's new
   default-deny policy silently breaking existing marketplace functionality.
4. **Move Firewall Init to Sidecar Container** *(critical fix)* — a phase-review
   security lens found that granting `CAP_NET_ADMIN` directly to `ai-sandbox`,
   combined with its pre-existing broad `NOPASSWD: ALL` sudo grant, meant any
   in-container command (including a prompt-injected agent action) could run
   `sudo iptables -F` and instantly disable the entire firewall. Fixed by
   relocating `CAP_NET_ADMIN` to a new one-shot `firewall-init` sidecar
   (mirroring the existing docker-socket-proxy privilege-isolation pattern);
   `ai-sandbox` itself never holds the capability.
5. **Add IPv6 Default-Deny Policy** — the same review found no `ip6tables`
   counterpart to the IPv4 policy; added a mirrored IPv6 default-deny
   (loopback-only, no allow-list) via the same sidecar mechanism.
6. **Fix Firewall Marker-Handshake Race** — a second review round found the
   sidecar/consumer marker-handshake (added in Task 4) had a race: the
   consumer's own marker-clear could delete a marker the sidecar had just
   freshly written, causing a spurious startup failure (fail-closed, not
   exploitable, but unreliable). Fixed by moving marker-clearing to the
   producer.
7. **Replace Marker Handshake With Nonce-Based Handshake** — a third review
   round found Task 6's fix traded the original race for its *mirror image*:
   a stale marker from a previous container lifecycle could be read as valid
   on restart, causing a **fail-open** state (critical). Replaced the
   existence-check handshake with a content/nonce-based one, correct
   regardless of startup ordering — empirically verified via a dedicated
   race-reproduction harness (5/5 fail-open reproduced pre-fix, 20/20 correct
   post-fix).

### Phase 2 — Network Capability Profiles (8 tasks)

1. **Add Dynamic Firewall Mechanism and Web-Search Capability** — built the
   `AI_SANDBOX_CAPABILITIES` dispatch mechanism and implemented `web-search`
   (public IPv4 hosts, port 443 only, RFC-reserved/private ranges excluded).
2. **Test Web-Search Capability**.
3. **Add Host-Access Capability** — any TCP port on the host machine
   (`host.docker.internal`), fed by host-side `lsof` port enumeration.
   Discovered `getent hosts` resolves IPv6-only on the base image despite
   this being an IPv4-only firewall; switched to `getent ahostsv4`.
4. **Test Host-Access Capability**.
5. **Add LAN-Access Capability** — all TCP ports on the host's detected LAN
   CIDR, via `route get default` + `ipconfig` (macOS-only, documented gap).
6. **Test LAN-Access Capability**.
7. **Fix Capability Dispatch IFS Word-Splitting Bug** *(major/critical fix)* —
   a phase-review security lens found the capability-dispatch loop and the
   host-access per-port loop relied on default word-splitting, but the
   file's global `IFS=$'\n\t'` broke it: combining 2+ capabilities silently
   applied none of their rules, and host-access's malformed multi-port
   `iptables` call could abort the script before reaching default-deny.
   Fixed using the file's own `IFS=' ' read -ra` pattern.
8. **Set S6_BEHAVIOUR_IF_STAGE2_FAILS to Actually Halt on Firewall Failure**
   *(critical fix, discovered incidentally)* — while empirically verifying
   Task 7's fix, discovered `S6_BEHAVIOUR_IF_STAGE2_FAILS` was unset
   project-wide, meaning s6-overlay's default behavior **ignores** a
   `cont-init.d` script's nonzero exit — so `03-init-firewall`'s "fail loud"
   design (the entire basis of Phase 1's safety claims) never actually
   halted the container on a real sidecar failure. Fixed by baking
   `ENV S6_BEHAVIOUR_IF_STAGE2_FAILS=2` into the base image, proven correct
   against s6-overlay's own source and real container reproductions.

### Phase 3 — Allow-Egress CLI Flag (3 tasks + 1 follow-up fix)

1. **Add Allow-Egress Flag Parsing** — `--allow-egress <host-or-ip[/cidr]>:<port>`,
   repeatable, full participation in the project's 8-dimension
   config-persistence contract (avoiding the gap Phase 2 left for
   `AI_SANDBOX_LAN_CIDR`/`HOST_LISTEN_PORTS`).
2. **Wire Allow-Egress Into Firewall** — resolves name-form entries via
   `getent ahostsv4` at container-init, applies the Phase 1/2 IFS and
   sidecar lessons correctly on first attempt.
3. **Test Allow-Egress Flag**.
4. *(ad-hoc follow-up, post phase-review)* fixed a trailing-dot IPv4
   validation bypass, corrected doc-attribution drift, and added the missing
   `--allow-egress` help-text entry.

This phase's review found no critical or major issues — the lessons from
Phases 1–2 (IFS word-splitting, sidecar-only capability grants) were
correctly reused.

### Phase 4 — Documentation Updates (1 task + 1 follow-up fix)

1. **Update Architecture Docs** — updated `README.md`, `docs/architecture.md`,
   and `docs/ai-sandbox-profiles-spec.md` to describe what actually shipped
   (cross-checked against source, not task docs' original plans, since
   several tasks evolved substantially through review).
2. *(ad-hoc follow-up, post phase-review)* a final documentation-accuracy
   audit found two known residual limitations were undisclosed — undermining
   the docs' own claims of narrowness/safety — and one factual slip. Fixed:
   disclosed `--allow-egress`'s CIDR has no minimum-prefix floor; disclosed a
   narrow `enter`/`docker exec` boot-window race that can attach before the
   firewall handshake completes (tracked in `docs/next-steps.md`, not fixed —
   see Follow-up items); corrected a minor `ifconfig` inaccuracy.

## Key decisions

- **Sidecar-based privilege isolation, not sudoers surgery.** When the
  critical `CAP_NET_ADMIN` + broad-sudo bypass was found, the user explicitly
  chose relocating the capability to a dedicated sidecar (mirroring the
  existing docker-socket-proxy pattern) over cheaper alternatives (sudoers
  negation, or just documenting the limitation) — the only option that
  actually closes the gap rather than raising the bar.
- **IPv6: add a real default-deny policy**, not just verify-and-document that
  IPv6 is disabled — user's explicit choice for genuine defense-in-depth.
- **Content/nonce-based handshake over timing-dependent designs.** After two
  successive marker-handshake races were found and "fixed" only to reveal a
  mirror-image race, the final fix was deliberately chosen to be
  *structurally* race-free (correct by content comparison, not by which
  container wins a startup race) rather than another clever-but-still-timing-
  dependent scheme.
- **Every phase boundary was gated by a dedicated correctness/security/
  architecture review pass** (not just the implementing agents' own
  self-testing) — this is what caught all of the critical/major findings
  above. Self-review by implementing agents consistently missed multi-step
  interaction bugs (capability composition, restart-lifecycle races,
  s6-overlay's actual failure semantics) that only surfaced under
  independent, adversarial review with a different agent and a fresh reading
  of the merged diff.
- **`--allow-egress`'s CIDR form has no minimum-prefix floor** (down to
  `/0`) — a deliberate design choice per the task's own requirements (the
  flag is an explicit, operator-driven allow-list), now honestly disclosed
  in the docs rather than left implicit.
- **Host-side detection (host-access, lan-access) is macOS-only for V1** —
  consistent with the project's macOS-first stance; Linux support deferred
  to a tracked follow-up.

## Follow-up items

35 items were recorded to `plan/followups.yaml` during this session, split
across two copies (the plan branch's own copy, where `apply_report`'s
automatic flagged-item appends landed, and the main working branch's copy,
where the manager's direct `followups_add` calls for phase-review findings
landed) — **these need reconciliation as part of this merge.** Highlights,
by severity/importance:

- **Linux support for `host-access`/`lan-access`** — needs Linux equivalents
  for the macOS-only `lsof`/`route`/`ipconfig` detection commands, plus a
  cross-platform (host + Docker-multi-OS) test structure. (Recorded before
  implementation began, per the user's explicit direction.)
- **Boot-window `docker exec`/`enter` race** — `start_shell()` execs into the
  container immediately after `up -d` with no wait on the firewall
  completion marker; a narrow (~1–2s) window exists where a race could
  attach before the firewall is confirmed applied. Documented in
  `docs/next-steps.md`; not fixed.
- **`AI_SANDBOX_LAN_CIDR`/`HOST_LISTEN_PORTS` missing from the
  config-persistence contract** — unlike `--allow-egress`, these two Phase 2
  values aren't in `running_config_matches()`, so it's unclear whether host
  state changes (e.g. switching WiFi networks) trigger a silent recreate or
  leave the documented remediation path non-functional. Needs empirical
  verification and a decision before any future capability reuses this
  pattern.
- **Dead per-host allow-list entries** in `docker/init-firewall.sh`
  (leading-dot wildcard syntax, non-resolving bare `githubusercontent.com`/
  `githubassets.com`) — pre-existing, harmless, needs real subdomain
  coverage.
- **`--quiet` stdout leak** (`check_docker()`'s banner) and a
  **`src/options.sh` leading-flag-before-command-word parse bug** — both
  pre-existing, break several unrelated integration specs, already tracked
  before this plan started.
- Several lower-priority hardening items: no CIDR-breadth validation on
  `network.allow`/`--allow-egress`, non-atomic firewall flush window, a
  label-join delimiter-confusion edge case shared with the pre-existing
  marketplace/plugin persistence pattern, missing `web-search`/`host-access`/
  `lan-access` IANA range completeness, `profiles/README.md` not updated for
  the three new profiles, a dead sudoers entry for the now-unreachable
  `init-firewall.sh` direct-invocation path, and a stray `ai-sandbox`
  test-debris container left on the local Docker daemon (blocked from
  auto-removal by the safety classifier — needs manual `docker rm -f
  ai-sandbox` after confirming it's not a real user instance).

Full text of every item is in the reconciled `plan/followups.yaml`.

## Final Task State

# TODO

## Purpose and scope

Tracking document for the active plan.

## Tasks

### Phase 01 — Firewall Enforcement Foundation

- [x] [001-author-failing-egress-test.md](./phase-01-firewall-enforcement/001-author-failing-egress-test.md) — tier `sonnet-med` · branch `phase-01-task-01-author-failing-egress-test` · commit `…` · merge `5cfd5c3a8b78eb5f22f9a90170d305b0d27c62d2`
- [x] [002-wire-firewall-init-and-net-admin.md](./phase-01-firewall-enforcement/002-wire-firewall-init-and-net-admin.md) — tier `sonnet-high` · branch `phase-01-task-02-wire-firewall-init-and-net-adm` · commit `…` · merge `9c44954303c0b506539a9f3790eba96a1c26c179`
- [x] [003-wire-profile-and-marketplace-allowlist.md](./phase-01-firewall-enforcement/003-wire-profile-and-marketplace-allowlist.md) — tier `sonnet-high` · branch `phase-01-task-03-wire-profile-and-marketplace-a` · commit `…` · merge `ff58bb45e3455e04f1486c94028d52fee2ebfb9f`
- [x] [004-move-firewall-init-to-sidecar.md](./phase-01-firewall-enforcement/004-move-firewall-init-to-sidecar.md) — tier `opus-high` · branch `phase-01-task-04-move-firewall-init-to-sidecar` · commit `…` · merge `b8344c92ef23b2444f3f46203c2911310abfffc3`
- [x] [005-add-ipv6-default-deny.md](./phase-01-firewall-enforcement/005-add-ipv6-default-deny.md) — tier `sonnet-high` · branch `phase-01-task-05-add-ipv6-default-deny-policy` · commit `…` · merge `…`
- [x] [006-fix-marker-handshake-race.md](./phase-01-firewall-enforcement/006-fix-marker-handshake-race.md) — tier `sonnet-high` · branch `phase-01-task-06-fix-marker-handshake-race` · commit `…` · merge `3119b7ebd992033fa1c761f4721f64650480cb72`
- [x] [007-nonce-based-firewall-handshake.md](./phase-01-firewall-enforcement/007-nonce-based-firewall-handshake.md) — tier `sonnet-high` · branch `phase-01-task-07-nonce-based-firewall-handshake` · commit `…` · merge `0211b54fe068a3fb22673445118d73afe97e6fa5`

### Phase 02 — Network Capability Profiles

- [x] [001-add-dynamic-firewall-mechanism-and-web-search.md](./phase-02-network-capabilities/001-add-dynamic-firewall-mechanism-and-web-search.md) — tier `sonnet-high` · branch `phase-02-task-01-add-dynamic-firewall-mechanism` · commit `…` · merge `1e0d6e43b3acaf8fa1236f61268ffa0b8001ef34`
- [x] [002-test-web-search-capability.md](./phase-02-network-capabilities/002-test-web-search-capability.md) — tier `sonnet-med` · branch `phase-02-task-02-test-web-search-capability` · commit `…` · merge `df5ca38cb1c7bfdc8dc44b2c3f0e3bdfa368b4e0`
- [x] [003-add-host-access-capability.md](./phase-02-network-capabilities/003-add-host-access-capability.md) — tier `sonnet-high` · branch `phase-02-task-03-add-host-access-capability` · commit `…` · merge `5ca9e6bda0c0b5cb65f4b63a221c461822b6b1b4`
- [x] [004-test-host-access-capability.md](./phase-02-network-capabilities/004-test-host-access-capability.md) — tier `sonnet-med` · branch `phase-02-task-04-test-host-access-capability` · commit `…` · merge `055ee378a29347c83f7b2825c22e0144175a7923`
- [x] [005-add-lan-access-capability.md](./phase-02-network-capabilities/005-add-lan-access-capability.md) — tier `sonnet-high` · branch `phase-02-task-05-add-lan-access-capability` · commit `…` · merge `b5b56c0`
- [x] [006-test-lan-access-capability.md](./phase-02-network-capabilities/006-test-lan-access-capability.md) — tier `sonnet-med` · branch `phase-02-task-06-test-lan-access-capability` · commit `…` · merge `6b0dc4f8ddea7a055e092ebbe5b9b8acdde9f60d`
- [x] [007-fix-capability-ifs-word-splitting.md](./phase-02-network-capabilities/007-fix-capability-ifs-word-splitting.md) — tier `sonnet-high` · branch `phase-02-task-07-fix-capability-ifs-word-splitt` · commit `…` · merge `…`
- [x] [008-set-s6-stage2-fail-behavior.md](./phase-02-network-capabilities/008-set-s6-stage2-fail-behavior.md) — tier `opus-high` · branch `phase-02-task-08-set-s6-stage2-fail-behavior` · commit `…` · merge `eff2a52b6d98b7693b5e26b4f2e7cce427604117`

### Phase 03 — Allow-Egress CLI Flag

- [x] [001-add-allow-egress-flag-parsing.md](./phase-03-allow-egress-flag/001-add-allow-egress-flag-parsing.md) — tier `sonnet-high` · branch `phase-03-task-01-add-allow-egress-flag-parsing` · commit `…` · merge `756178c6e90389985caa483117b2494c84515d18`
- [x] [002-wire-allow-egress-into-firewall.md](./phase-03-allow-egress-flag/002-wire-allow-egress-into-firewall.md) — tier `sonnet-high` · branch `phase-03-task-02-wire-allow-egress-into-firewal` · commit `…` · merge `8769c260bb688987954e9eee1768207fb39b1f3f`
- [x] [003-test-allow-egress-flag.md](./phase-03-allow-egress-flag/003-test-allow-egress-flag.md) — tier `sonnet-med` · branch `phase-03-task-03-test-allow-egress-flag` · commit `…` · merge `88a2cd0ca20f6290fc8c1f5652d697be01bcd819`

### Phase 04 — Documentation Updates

- [x] [001-update-architecture-docs.md](./phase-04-doc-updates/001-update-architecture-docs.md) — tier `sonnet-high` · branch `phase-04-task-01-update-architecture-docs` · commit `…` · merge `6f7b2b6c4e78eb056e8adb318e8bc44847f80587`
