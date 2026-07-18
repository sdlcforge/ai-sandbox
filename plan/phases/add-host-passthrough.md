# Phase: add-host-passthrough

## Goals

Deliver the core, decision-independent fix: a supported, documented,
cross-platform way for a caller to pin a stable host→IPv4 mapping into an
ai-sandbox container, sidestepping Docker Desktop's variable `host.docker.internal`
resolution entirely. Concretely, a repeatable `--add-host <name>:<ip>` CLI flag
whose entries are threaded into the container's `extra_hosts`, so Flow's
flow-run-optimizer (and any caller) can pin e.g.
`host.docker.internal:<host-gateway-ipv4>` themselves at create/start time.

This phase comes first because it is the confident deliverable, is unblocked by
the open research (the caller supplies the IP), and establishes the stable
contract the downstream consumer needs regardless of whether option (b) is later
adopted.

## Inputs

- **CLI flag-parsing precedent** — `src/options.sh` `--allow-egress` case
  (lines ~506-538): repeatable flag → `CLI_*` array, validation via
  `src/utils.sh` helpers, `CONFIG_FLAGS_PROVIDED=true`. The new flag follows the
  same shape, validating `<name>` (hostname) and `<ip>` (IPv4 literal).
- **Compose-override threading** — `src/index.sh` compose-file assembly
  (`GENERATED_COMPOSE`, line ~506) and `docker/docker-compose.yaml`'s static
  `extra_hosts` (lines 167-168). Variable-length entries are emitted into the
  generated override rather than interpolated into the static YAML list.
- **Config-persistence triad** — `docker/docker-compose.yaml` `environment:` +
  `labels:` blocks, `src/utils.sh` `running_config_matches()` (lines 663-699),
  the `ai.sandbox.config` base64-JSON label + `restore_saved_config()`
  (lines 486+). The `--allow-egress` field is the exact precedent to mirror
  (subject to Q-U3).
- **Firewall interaction** — `docker/init-firewall.sh` `host-access`
  (lines 211-283) and `--allow-egress` rules (lines 315+): name-pinning alone
  does not grant egress under the default-deny firewall; the documented contract
  must state the composition requirement (see
  [investigation findings](../notes/investigation-findings.md) §"Firewall-
  interaction subtlety").
- **Open decision Q-U3** — whether this flag participates in the full
  config-persistence triad (recommended: yes, per `--allow-egress`, avoiding the
  `yS0R` gap). Gates the task breakdown of the persistence work.

## Outputs

- A repeatable `--add-host <name>:<ip>` CLI flag parsed and validated in
  `src/options.sh`, exposed on the create/start path.
- Caller-supplied entries present in the container's `/etc/hosts` (via
  `extra_hosts` in the generated compose override), resolvable by
  `getent ahostsv4 <name>`.
- (Subject to Q-U3) the flag's value carried through the config-persistence
  triad so it survives `start`/restore and routes through the
  `running_config_matches()` consent gate like `--allow-egress`.
- A documented, stable contract (surfaced to the doc-updates phase) telling a
  downstream automation caller exactly how to pin a host IPv4 and, under the
  firewall, how to pair it with `host-access`/`--allow-egress` to actually reach
  the host.
