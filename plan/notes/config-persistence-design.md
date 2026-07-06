# Config Persistence Design Recommendation

## Purpose and scope

This note is the design-exploration output mandated by the change request. It analyses the current create/start/enter configuration lifecycle and makes a concrete, load-bearing recommendation for how the **full** ai-sandbox configuration should be persisted to and restored from Docker-side artifacts, so that a bare `enter`/`start` (no flags) reconstructs the exact configuration the container was created with. All phase decomposition and task breakdown in `plan/overview.md` are derived from this recommendation; task documents should not re-derive it.

## 1. The current lifecycle, as-built

### 1.1 The config-input set (source: `src/options.sh`)

Exactly seven CLI flags set `CONFIG_FLAGS_PROVIDED=true` — i.e. they change container configuration. These are the complete set of **config inputs**:

| Flag | Global set | Type | Nature |
|------|-----------|------|--------|
| `--profile <name>` (repeatable) | `PROFILES` (array, ordered) | list | input; layered left-to-right |
| `--mode <mirror\|static>` | `MODE_OVERRIDE` | scalar | input (override) |
| `--no-isolate-config` | `NO_ISOLATE_CONFIG` | bool | pass-through (input == effective) |
| `--add-marketplace <ref>` (repeatable) | `CLI_MARKETPLACES` (array) | list | input; CLI addition on top of profile |
| `--enable-plugin <name>` (repeatable) | `CLI_PLUGINS` (array) | list | input; CLI addition on top of profile |
| `--enable-all` | `CLI_ENABLE_ALL` | bool | input; OR'd with profile value |
| `--clean` | `CLEAN_SLATE` | bool | pass-through (input == effective) |

Invocation-behavior flags (`--enter`, `--json`, `--test-check`, `--force`, `--yes`, `--quiet`) deliberately do **not** set `CONFIG_FLAGS_PROVIDED` and are correctly out of scope — they do not describe the container's configuration.

### 1.2 How inputs become effective config (source: `src/index.sh`)

On every `start`/`enter`/`create`/`up`, `index.sh` re-runs the full resolution pipeline:

1. `restore_saved_config` (only for `start`/`enter`, only when `CONFIG_FLAGS_PROVIDED != true`) rehydrates a subset of inputs from container labels.
2. `profile-installer.js` composes `PROFILES` (+`MODE_OVERRIDE`) → emits `PROFILE_MODE`, `PROFILE_CAPABILITIES`, `PROFILE_COMPOSITION_HASH`, and a `PROFILE_JSON` blob (`marketplaces`, `plugins`, `enable_all_plugins`, `packages`, `network_allow`, …).
3. `index.sh` merges `CLI_MARKETPLACES`/`CLI_PLUGINS`/`CLI_ENABLE_ALL` into `PROFILE_JSON` (union + OR).
4. Derived effective values are computed: `EFFECTIVE_MODE` (`--clean` forces `static`; else `MODE_OVERRIDE`; else `PROFILE_MODE`; else `mirror`), `EFFECTIVE_PROXY` (true iff `docker` capability present), `AI_SANDBOX_IMAGE_TAG` (from the hash), and `AI_SANDBOX_MARKETPLACES`/`AI_SANDBOX_PLUGINS`/`AI_SANDBOX_ENABLE_ALL_PLUGINS` (pipe/bool env vars extracted from `PROFILE_JSON`, consumed by `docker-compose.yaml` and the container's `10-plugin-setup` init).

The critical architectural fact: **the pipeline re-runs from inputs on every invocation.** Derived values are never trusted across invocations — they are recomputed. This is the natural seam for persistence: persist *inputs*, re-derive the rest.

### 1.3 What is persisted today (source: `docker/docker-compose.yaml` labels)

| Label | Value written | Consumer |
|-------|---------------|----------|
| `ai.sandbox.profiles` | `SANDBOX_PROFILES` (comma-joined `PROFILES`) | `restore_saved_config`, `list_instances` (human display) |
| `ai.sandbox.mode` | `EFFECTIVE_MODE` | `restore_saved_config`, `running_config_matches` |
| `ai.sandbox.clean-slate` | `AI_SANDBOX_CLEAN_SLATE` | `restore_saved_config`, `running_config_matches` |
| `ai.sandbox.no-isolate-config` | `NO_ISOLATE_CONFIG` | `running_config_matches` only |
| `ai.sandbox.docker-proxy` | `EFFECTIVE_PROXY` | `running_config_matches` only |
| `ai.sandbox.profile-hash` | `PROFILE_COMPOSITION_HASH` | `running_config_matches`, `is_build_stale` |
| `ai.sandbox.managed` / `ai.sandbox.instance` | mgmt metadata | `list_instances` |
| `ai.sandbox.ssh-auth-sock-host` | SSH sock path | SSH drift detection |

Marketplaces, plugins, and enable-all are **not persisted in any label** — they only ever exist as compose env vars at create time.

### 1.4 The divergence (the bug class)

- **`restore_saved_config` restores 3 of the 7 inputs**: `profiles`, `mode`, `clean-slate`. It does **not** restore `NO_ISOLATE_CONFIG`, `CLI_MARKETPLACES`, `CLI_PLUGINS`, or `CLI_ENABLE_ALL`.
- **`running_config_matches` compares 5 derived dimensions**: image tag, `profile-hash`, `mode`, `no-isolate-config`, `docker-proxy`, `clean-slate`. It ignores marketplaces/plugins/enable-all.

Two concrete failures fall out of this incompleteness:

1. **`--no-isolate-config` is silently dropped AND triggers a false-positive recreate.** Created with `--no-isolate-config` → label `no-isolate-config=true`. Bare `enter` → `NO_ISOLATE_CONFIG` defaults to `false` (restore does not touch it) → `running_config_matches` compares `cur_no_isolate=true` vs `false` → mismatch → false "stop and recreate" prompt; if accepted, the container is rebuilt in the *wrong* (isolated) mode. This is the same shape of bug the `enter-mode-restore` plan just fixed for `mode`/`clean-slate`, still latent for `no-isolate-config`.
2. **`--add-marketplace`/`--enable-plugin`/`--enable-all` are silently dropped** (followup AL7i). They are never persisted, so a bare `enter` reproduces the container without them. No false recreate (matches ignores them), but the container loses its requested plugin/marketplace setup.

The root cause is not that the two functions read *different labels* — they legitimately operate at different pipeline stages (restore consumes inputs *before* resolution; matches compares derived values *after*). The root cause is that the **set of persisted+restored input dimensions is incomplete**, so restore cannot reproduce every effective-config dimension that matches (or the container's init) depends on.

## 2. Design questions and recommendations

### 2.1 What gets persisted, and in what shape

**Recommendation: persist the complete config-*input* set (all seven dimensions), as a single structured JSON object in one base64-encoded Docker label `ai.sandbox.config`.** Keep the existing plain-text labels that serve independent consumers.

Rationale for **inputs, not derived values**: the pipeline already re-derives everything from inputs on every invocation (§1.2). Persisting inputs and letting `profile-installer.js` + the merge re-run is exactly symmetric to how `profiles`/`mode`/`clean` already work, keeps `profile-installer.js` the single source of truth for resolution, and automatically picks up profile-file edits the same way `is_build_stale` already does. Persisting *derived* values instead would bypass the resolver and risk the restored config diverging from a fresh resolution — the very thing `running_config_matches` guards against. For marketplaces/plugins specifically, persist the **CLI additions** (`CLI_MARKETPLACES`/`CLI_PLUGINS`/`CLI_ENABLE_ALL`), not the merged effective set: the profile-contributed entries are reproduced for free by re-running `profile-installer.js`, and re-injecting only the CLI deltas avoids baking a stale copy of the profile's marketplaces into the label.

Rationale for **one JSON label vs. per-field labels**: this directly serves generalization goal #4 (see §2.4). A per-field scheme requires three edits per new config flag — a new `export` in `index.sh`, a new `label:` line in the static `docker-compose.yaml`, and a new read in `restore_saved_config`. The static compose file is the friction point: it cannot iterate over a dynamic set. A single JSON label moves the whole record behind one never-changing compose line (`ai.sandbox.config: "${AI_SANDBOX_CONFIG_B64}"`); adding a flag becomes two co-located bash edits (extend the JSON assembly in `index.sh`; extend the extraction in `restore_saved_config`) and no compose change. The input set is small and bounded (7 dimensions, lists of a handful of entries), so Docker label size limits are a non-issue in practice — but the JSON shape is the one that scales cleanly if the flag surface grows.

Rationale for **base64 encoding** (see §2.5 for the full tradeoff): it eliminates every JSON-in-a-label escaping and compose-`$`-interpolation footgun, and it mirrors the established `AI_SANDBOX_CREDENTIALS_JSON_B64` precedent already in `src/credentials.sh`. The cost — the label is not human-readable via `docker inspect` — is fully mitigated by retaining the plain-text `ai.sandbox.profiles` label (already used by `ai-sandbox list`) and the plain derived labels used by matches.

Proposed JSON shape (the `ai.sandbox.config` payload, before base64):

```json
{
  "version": 1,
  "profiles": ["base", "docker"],
  "mode": "static",
  "no_isolate_config": false,
  "clean_slate": true,
  "marketplaces": ["https://registry.example.com/plugins"],
  "plugins": ["claude-mem"],
  "enable_all_plugins": false
}
```

`mode` is the empty string when no `--mode` override was given (mirrors `MODE_OVERRIDE`). A `version` field is included so future schema changes are detectable.

### 2.2 Where/when it is written

**Recommendation: write at container-create time only — i.e. whenever `docker compose up -d` (re)creates the container** — which is exactly what the existing labels already do, since labels are baked into the container at create/recreate. `index.sh` assembles `AI_SANDBOX_CONFIG_B64` from the resolved input globals and exports it before compose assembly; `docker-compose.yaml` interpolates it into the `ai.sandbox.config` label. No refresh-on-every-start is needed or desirable: a bare `start`/`enter` of an unchanged container is a compose no-op and must not rewrite labels (rewriting would force a recreate, defeating the purpose). When an explicit-flags invocation *does* recreate the container, the label is naturally rewritten with the new config — correct by construction.

Assembly point: after the CLI-merge block (`src/index.sh` ~line 133, where `PROFILE_JSON` and the CLI arrays are all final) and before compose-file assembly. The base64 form should be produced defensively single-line, mirroring `credentials.sh`: `printf '%s' "${json}" | base64 | tr -d '\n'`.

### 2.3 Reconciling `restore_saved_config` and `running_config_matches`

The two functions cannot literally read the same labels (they operate at different pipeline stages, §1.4). The correct reconciliation is **completeness and mutual consistency of the dimension set**, achieved as follows:

1. **`restore_saved_config` reads the single `ai.sandbox.config` label** (base64-decode → jq) and sets **all seven** input globals (`PROFILES`, `MODE_OVERRIDE`, `NO_ISOLATE_CONFIG`, `CLEAN_SLATE`, `CLI_MARKETPLACES`, `CLI_PLUGINS`, `CLI_ENABLE_ALL`), gated on `CONFIG_FLAGS_PROVIDED != true` exactly as today. This closes both the `no-isolate-config` restore gap and the marketplaces/plugins/enable-all gap (AL7i). Because restore now reconstructs *every* input, the pipeline re-derives *every* effective dimension identically — so after a bare-enter restore, `running_config_matches` returns true by construction and never false-prompts.
2. **`running_config_matches` stays a derived-value comparison** but is extended to cover the previously-ignored dimensions (marketplaces, plugins, enable-all), so that an *explicit* invocation that changes them (e.g. `enter --add-marketplace NEW` on a container created without it) is correctly detected as a config change and prompts a recreate — otherwise the new setup would silently never apply. This is the completeness half of goal #3. It requires the effective marketplace/plugin values to be available on the container as derived labels (see §2.6).

This split — restore reads the canonical **input** record; matches compares the **derived** record; both cover the full dimension set — is the durable reconciliation. It is documented here so future maintainers do not "unify" them into reading one literal label set, which their differing pipeline stages make impossible.

### 2.4 Generalization to future config flags

With the single JSON input label, adding a new config-changing flag `--foo` requires, beyond the option-parsing addition itself:

1. Add `foo` to the JSON assembled in `index.sh` (one line).
2. Add `foo` extraction to `restore_saved_config` (one line).
3. (Only if the flag affects the effective composition and should force a recreate) add a derived-label + a comparison in `running_config_matches`.

No new static compose label line, no new `export` plumbing for the input record. The JSON `version` field lets restore handle older payloads gracefully. This is a strict improvement over today's per-field scheme, where every new flag needs a compose edit that the static YAML makes verbose and error-prone.

### 2.5 Concrete tradeoffs

- **Docker label size limits.** Docker imposes no hard per-label limit, but the total container config should stay modest. The input record is a handful of short strings and a few URLs — well under any practical bound. Not a concern; noted only to record that it was considered. Were the record ever to grow large (hundreds of entries), the JSON-in-a-label approach would still be the more size-efficient of the label options, and only then would an external file warrant reconsideration (see §3).
- **JSON-in-a-label escaping.** Plain JSON in a label is *technically* viable — Docker Compose interpolates env vars into already-parsed YAML scalars, so embedded quotes survive without YAML escaping, and `docker inspect | jq` round-trips. But two footguns remain: a literal `$` in any value (a marketplace URL) would be treated as a compose interpolation token, and Go-template/`docker inspect -f` handling of embedded quotes is fragile. **Base64 encoding sidesteps all of it** — the label value is `[A-Za-z0-9+/=]` only, inert to compose interpolation and YAML alike. macOS `base64` may line-wrap; `| tr -d '\n'` guarantees a single-line value. This is why base64 is recommended over plain JSON despite the readability cost.
- **Readability.** A base64 label is opaque to `docker inspect`. Mitigation: the plain `ai.sandbox.profiles` label (needed anyway by `ai-sandbox list`) and the plain derived labels (`mode`, `no-isolate-config`, `docker-proxy`, `clean-slate`, `profile-hash`) remain human-readable; only the full input record is encoded. A future `ai-sandbox status` enhancement could decode and pretty-print `ai.sandbox.config` if desired (out of scope here).
- **Backward compatibility with pre-existing containers.** Containers created before this change carry no `ai.sandbox.config` label. `restore_saved_config` MUST detect the absent/empty label and fall back to the current behavior — reading the legacy `ai.sandbox.profiles`/`ai.sandbox.mode`/`ai.sandbox.clean-slate` labels. Such containers simply won't restore marketplaces/plugins/no-isolate-config (which they never persisted anyway) — identical to today's behavior, no regression. This fallback is a hard requirement of the implementation, not optional.

### 2.6 Label inventory after the change

- **New:** `ai.sandbox.config` (base64 JSON, the canonical input record; sole restore source).
- **Retained unchanged:** `ai.sandbox.profiles` (list display), `ai.sandbox.managed`, `ai.sandbox.instance`, `ai.sandbox.ssh-auth-sock-host`, `ai.sandbox.profile-hash`, `ai.sandbox.mode`, `ai.sandbox.no-isolate-config`, `ai.sandbox.docker-proxy`, `ai.sandbox.clean-slate` (matches + display).
- **New derived labels (for the matches-completeness half of §2.3):** `ai.sandbox.marketplaces`, `ai.sandbox.plugins`, `ai.sandbox.enable-all-plugins`, written from the effective `AI_SANDBOX_MARKETPLACES`/`AI_SANDBOX_PLUGINS`/`AI_SANDBOX_ENABLE_ALL_PLUGINS` env vars, so `running_config_matches` can compare them.

The minor redundancy (e.g. `clean_slate` appears both inside `ai.sandbox.config` and as the plain `ai.sandbox.clean-slate` derived label) is intentional and acceptable: the two serve different stages (input reconstruction vs. derived comparison) and the pass-through dimensions have input == derived, so they cannot drift.

## 3. Recommendation summary and the external-file question

**Recommended design:** a single base64-encoded JSON label `ai.sandbox.config` holding the complete seven-dimension config-input record, written at create/recreate time by `index.sh` + `docker-compose.yaml`; read by an extended `restore_saved_config` (with legacy-label fallback for pre-existing containers) to rehydrate all inputs on a bare `enter`/`start`; complemented by an extended `running_config_matches` that compares the full derived-config dimension set (adding marketplaces/plugins/enable-all via three new plain derived labels). The existing plain labels are retained for `list` display and matches.

**No external state file.** The Docker-label approach is fully workable here: the record is small, base64 removes every escaping/interpolation concern, and labels are precisely Docker's intended metadata channel. An external file (e.g. under `$XDG_CACHE_HOME/ai-sandbox/<name>/`) would introduce a second source of truth that can desynchronize from the container's actual identity, would not travel with `docker commit`/inspect tooling, and would need its own lifecycle/cleanup on `delete`/`clean`. It is justified only if the record ever became genuinely too large or structurally too complex for a label (see §2.5) — not the case for this change. The "no external database/file" preference is honored.
