# Phase 01 Task 001 — Profile Schema and Installer

**Tier:** `sonnet-high`
**Depends on:** nothing (foundation task)
**Parallel-eligible with:** nothing

---

## Purpose and scope

Establish the data-layer foundation for marketplace and plugin configuration. This task updates the profile YAML specification document and extends `bin/profile-installer.js` to parse, validate, compose, and emit two new fields — `marketplaces` and `enable_all_plugins` — alongside the existing `plugins` field.

No bash or container changes happen in this task. All subsequent tasks depend on the schema and installer output that this task defines.

---

## Requirements

### 1. `docs/ai-sandbox-profiles-spec.md` — schema additions

Add the following two fields to the field-reference section of the spec. Place them in a logical grouping near the existing `plugins` field (the fields are related — `marketplaces` is a prerequisite for `plugins` to work with non-default registries).

**`marketplaces`**

```yaml
marketplaces:
  - https://registry.example.com/plugins
  - file:///home/user/my-local-plugin
```

- Type: list of strings
- Each entry must start with `https://` or `file://`
- Composition rule: **union** (same as `packages` and `plugins`) — entries from all composed profiles are merged, duplicates removed, original order preserved
- Purpose: registers marketplace sources inside the container at init time via `claude plugins marketplace add <ref>`
- Default: `[]`

**`enable_all_plugins`**

```yaml
enable_all_plugins: true
```

- Type: boolean
- Composition rule: **OR** (true if any composed profile or CLI flag sets it to true)
- Purpose: when true, enables all plugins from the last registered marketplace
- Default: `false`

**Update the `plugins` field entry** to add a cross-reference note: "Plugin names listed here are enabled individually. To register the marketplace that provides them, use the `marketplaces` field."

**Add a composition rules table** (or update the existing one) that shows:

| Field | Type | Composition |
|-------|------|-------------|
| `marketplaces` | `[string]` | union |
| `enable_all_plugins` | `bool` | OR |
| `plugins` | `[string]` | union (existing) |

### 2. `bin/profile-installer.js` — parser and emitter changes

**Add `marketplaces` to `KNOWN_KEYS`:**

```js
'marketplaces',
'enable_all_plugins',
```

**Add `marketplaces` to `STRING_LIST_FIELDS`** (so it gets the same list-parse and union-compose treatment as `packages` and `plugins`).

**Add `enable_all_plugins` to `SCALAR_FIELDS`** (it is a per-document scalar boolean, not a list).

**Validation in the document-parse step:** After loading each profile YAML document, validate:
- `marketplaces`: if present, must be an array; each entry must be a string starting with `https://` or `file://`. Emit a clear error (call `die()`) if any entry fails validation.
- `enable_all_plugins`: if present, must be a boolean. Emit a clear error if it is not.

**Merge/compose step:** The `compose()` function already handles union for string-list fields and pass-through for scalar fields. Because `enable_all_plugins` is a boolean that should OR across profiles (not just take the last value), it needs explicit handling:

```js
// In the compose() function, after merging scalar fields:
merged.enable_all_plugins = profiles.some(p => p.enable_all_plugins === true);
```

Initialize the merged object default: `enable_all_plugins: false`.

**`renderJsonBlob()` — emit both new fields:**

```js
function renderJsonBlob(merged) {
  return JSON.stringify({
    packages: merged.packages,
    plugins: merged.plugins,
    marketplaces: merged.marketplaces,
    enable_all_plugins: merged.enable_all_plugins,
    capabilities: merged.capabilities.slice().sort(),
    network_allow: merged.network_allow,
    required_env: merged.required_env,
    optional_env: merged.optional_env,
  });
}
```

### 3. Unit tests — `test/unit/profile_installer_spec.js` (or equivalent)

Write or add to the existing profile-installer test file. Required test cases:

- A profile with `marketplaces: [https://example.com/plugins]` is parsed, composed, and emitted in the JSON blob with the correct value.
- A profile with `marketplaces: [file:///some/path]` passes validation.
- A `marketplaces` entry that does not start with `https://` or `file://` causes `die()` to be called (or the process to exit non-zero).
- `enable_all_plugins: true` on one profile in a two-profile composition makes the output `enable_all_plugins: true`.
- `enable_all_plugins: false` on both profiles in a two-profile composition makes the output `enable_all_plugins: false`.
- `marketplaces` union: two profiles each with one marketplace entry produce a two-entry union with no duplicates.
- `marketplaces` defaults to `[]` when the field is absent from the profile YAML.
- `enable_all_plugins` defaults to `false` when absent.

---

## Checkpoint hints

This task touches three files. Recommended checkpoints:

1. **After updating `docs/ai-sandbox-profiles-spec.md`:** Manually review that the field table is internally consistent (types, composition rules) and the cross-reference in the `plugins` entry is accurate.

2. **After updating `bin/profile-installer.js`:** Run `node bin/profile-installer.js` with a minimal test profile that includes `marketplaces` and `enable_all_plugins` fields. Verify the `### PROFILE_JSON ###` block in stdout contains both fields. Run `node bin/profile-installer.js` with a profile containing an invalid marketplace ref (e.g., `ftp://bad`) and confirm it exits non-zero with a clear error.

3. **After writing unit tests:** Run the test suite: `shellspec test/unit/profile_installer_spec.sh` (or `node` equivalent) and confirm all new cases pass. Then run `make lint` to confirm shellcheck is still happy (no bash was changed, but lint runs across all files).

---

## Validation

The task is complete when:

- [ ] `docs/ai-sandbox-profiles-spec.md` documents `marketplaces` and `enable_all_plugins` with type, composition rule, and an example.
- [ ] `bin/profile-installer.js` rejects a profile with a `marketplaces` entry that doesn't start with `https://` or `file://`.
- [ ] `bin/profile-installer.js` emits `marketplaces` and `enable_all_plugins` in the `### PROFILE_JSON ###` output block.
- [ ] `enable_all_plugins` ORs correctly across a two-profile composition.
- [ ] `marketplaces` unions correctly across a two-profile composition (no duplicates).
- [ ] All new unit tests pass.
- [ ] `make lint` passes (no regressions).
