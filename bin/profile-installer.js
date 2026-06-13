#!/usr/bin/env node
'use strict';

// profile-installer.js — the boundary between profile YAML and the bash launcher.
//
// Given one or more profile names, this script:
//   1. resolves each name through the discovery order,
//   2. composes the profiles per the merge rules,
//   3. validates paths / required_env / capability fragments,
//   4. computes a deterministic composition hash, and
//   5. writes three sentinel-delimited output blocks to stdout for bash to consume.
//
// Canonical references:
//   docs/ai-sandbox-profiles-spec.md  ("The profile-installer.js Node script")
//   plan/phase-02-foundation/002-profile-installer.md
//
// This script runs in the HOST Node environment, never inside the container.
// It uses only Node built-ins plus js-yaml.
//
// ---------------------------------------------------------------------------
// Output-block sentinels (CONTRACT — Task 004 parses these exactly).
// Define them once here; downstream parsers must match these strings byte-for-byte.
// ---------------------------------------------------------------------------
const SENTINEL = {
  envBegin: '### PROFILE_ENV ###',
  envEnd: '### END_PROFILE_ENV ###',
  pathsBegin: '### PROFILE_PATHS ###',
  pathsEnd: '### END_PROFILE_PATHS ###',
  skillsBegin: '### PROFILE_PATHS_SKILLS ###',
  hooksBegin: '### PROFILE_PATHS_HOOKS ###',
  agentsBegin: '### PROFILE_PATHS_AGENTS ###',
  jsonBegin: '### PROFILE_JSON ###',
  jsonEnd: '### END_PROFILE_JSON ###',
};

// ---------------------------------------------------------------------------
// Composition-hash recipe (CONTRACT — Task 005 sources PROFILE_IMAGE_TAG and
// PROFILE_COMPOSITION_HASH from this script and MUST NOT recompute the hash).
//
//   input  = orderedDedupedProfileNames.join(':')
//            + ':'
//            + sortedCapabilities.join(':')
//   hash   = sha256(input) hex, first 8 chars
//
// The hash input contains NO wall-clock time and NO absolute paths, so it is
// stable across runs and machines. Capabilities are part of the input because
// the same profile names with different capability sets must yield different
// images (and therefore different tags).
// ---------------------------------------------------------------------------
const HASH_LENGTH = 8;

const fs = require('fs');
const path = require('path');
const crypto = require('crypto');
const os = require('os');
// js-yaml v4: yaml.load() uses DEFAULT_SCHEMA and does NOT construct arbitrary
// types — there is no unsafe object-tag execution (that was removed from the v4
// API). This is the safe loader for our simple data-only profile YAML.
const yaml = require('js-yaml');

const SCRIPT_DIR = __dirname;
const REPO_ROOT = path.resolve(SCRIPT_DIR, '..');

// Recognized top-level keys. Anything else triggers a warning (not an error).
const KNOWN_KEYS = new Set([
  'metadata',
  'mode',
  'capabilities',
  'packages',
  'setup_script',
  'plugins',
  'marketplaces',
  'enable_all_plugins',
  'skills',
  'hooks',
  'agents',
  'required_env',
  'optional_env',
  'network',
]);

const STRING_LIST_FIELDS = ['packages', 'plugins', 'marketplaces', 'capabilities', 'required_env', 'optional_env'];
const OBJECT_LIST_FIELDS = ['skills', 'hooks', 'agents'];
const SCALAR_FIELDS = ['mode', 'setup_script'];

function die(message) {
  process.stderr.write(`profile-installer: ${message}\n`);
  process.exit(1);
}

function warn(message) {
  process.stderr.write(`warning: ${message}\n`);
}

function xdgConfigHome() {
  return process.env.XDG_CONFIG_HOME && process.env.XDG_CONFIG_HOME.length > 0
    ? process.env.XDG_CONFIG_HOME
    : path.join(os.homedir(), '.config');
}

function xdgCacheHome() {
  return process.env.XDG_CACHE_HOME && process.env.XDG_CACHE_HOME.length > 0
    ? process.env.XDG_CACHE_HOME
    : path.join(os.homedir(), '.cache');
}

// ---------------------------------------------------------------------------
// CLI parsing
// ---------------------------------------------------------------------------
function parseArgs(argv) {
  const opts = { mode: null, output: null, names: [] };
  for (let i = 0; i < argv.length; i++) {
    const arg = argv[i];
    if (arg === '--mode') {
      opts.mode = argv[++i];
      if (opts.mode === undefined) die('--mode requires a value');
    } else if (arg.startsWith('--mode=')) {
      opts.mode = arg.slice('--mode='.length);
    } else if (arg === '--output') {
      opts.output = argv[++i];
      if (opts.output === undefined) die('--output requires a value');
    } else if (arg.startsWith('--output=')) {
      opts.output = arg.slice('--output='.length);
    } else if (arg === '--') {
      // remaining args are positional
      opts.names.push(...argv.slice(i + 1));
      break;
    } else if (arg.startsWith('-')) {
      die(`unknown option: ${arg}`);
    } else {
      opts.names.push(arg);
    }
  }
  if (opts.output !== null && !['env', 'paths', 'json'].includes(opts.output)) {
    die(`unknown --output value "${opts.output}" (expected one of: env, paths, json)`);
  }
  if (opts.mode !== null && !['mirror', 'static'].includes(opts.mode)) {
    die(`invalid --mode value "${opts.mode}" (expected one of: mirror, static)`);
  }
  return opts;
}

// ---------------------------------------------------------------------------
// Default-profile resolution (from config.yaml, else hardcoded [base, mirror])
// ---------------------------------------------------------------------------
function resolveDefaultProfiles() {
  const configPath = path.join(xdgConfigHome(), 'ai-sandbox', 'config.yaml');
  if (fs.existsSync(configPath)) {
    let doc;
    try {
      doc = yaml.load(fs.readFileSync(configPath, 'utf8'));
    } catch (err) {
      die(`failed to parse config "${configPath}": ${err.message}`);
    }
    if (doc && Array.isArray(doc.default_profiles) && doc.default_profiles.length > 0) {
      for (const n of doc.default_profiles) {
        if (typeof n !== 'string') {
          die(`config "${configPath}": default_profiles must be a list of strings`);
        }
      }
      return doc.default_profiles.slice();
    }
  }
  return ['base', 'mirror'];
}

// ---------------------------------------------------------------------------
// Profile discovery: returns the first-matching absolute path or null.
// ---------------------------------------------------------------------------
function findProfile(name) {
  const candidates = [
    path.resolve(process.cwd(), 'profiles', `${name}.yaml`),
    path.join(xdgConfigHome(), 'ai-sandbox', 'profiles', `${name}.yaml`),
    path.join(SCRIPT_DIR, '..', 'profiles', `${name}.yaml`),
  ];
  for (const candidate of candidates) {
    if (fs.existsSync(candidate) && fs.statSync(candidate).isFile()) {
      return path.resolve(candidate);
    }
  }
  return null;
}

// ---------------------------------------------------------------------------
// Per-profile load + schema validation. Returns { name, file, dir, doc }.
// ---------------------------------------------------------------------------
function loadProfile(name) {
  if (name.includes('/') || name.includes(path.sep)) {
    die(`invalid profile name "${name}": names must not contain a path separator`);
  }
  const file = findProfile(name);
  if (!file) {
    die(
      `profile "${name}" not found in any search location ` +
        `(./profiles, ${path.join(xdgConfigHome(), 'ai-sandbox', 'profiles')}, ${path.join(REPO_ROOT, 'profiles')})`
    );
  }

  let doc;
  try {
    doc = yaml.load(fs.readFileSync(file, 'utf8'));
  } catch (err) {
    die(`failed to parse profile "${name}" (${file}): ${err.message}`);
  }
  // An empty YAML file parses to undefined/null — treat as an empty profile.
  if (doc === undefined || doc === null) {
    doc = {};
  }
  if (typeof doc !== 'object' || Array.isArray(doc)) {
    die(`profile "${name}" (${file}): top-level YAML must be a mapping`);
  }

  validateSchema(name, file, doc);
  return { name, file, dir: path.dirname(file), doc };
}

function validateSchema(name, file, doc) {
  for (const key of Object.keys(doc)) {
    if (!KNOWN_KEYS.has(key)) {
      warn(`profile "${name}" (${file}): unknown top-level key "${key}" — ignoring`);
    }
  }
  // Type checks for recognized fields.
  for (const field of STRING_LIST_FIELDS) {
    if (doc[field] !== undefined && !isStringList(doc[field])) {
      die(`profile "${name}" (${file}): field "${field}" must be a list of strings`);
    }
  }
  // marketplaces entries must each start with https:// or file://.
  if (doc.marketplaces !== undefined) {
    for (const entry of doc.marketplaces) {
      if (!entry.startsWith('https://') && !entry.startsWith('file://')) {
        die(
          `profile "${name}" (${file}): marketplaces entry "${entry}" must start with https:// or file://`
        );
      }
    }
  }
  // enable_all_plugins must be a boolean.
  if (doc.enable_all_plugins !== undefined && typeof doc.enable_all_plugins !== 'boolean') {
    die(`profile "${name}" (${file}): field "enable_all_plugins" must be a boolean`);
  }
  for (const field of SCALAR_FIELDS) {
    if (doc[field] !== undefined && typeof doc[field] !== 'string') {
      die(`profile "${name}" (${file}): field "${field}" must be a string`);
    }
  }
  for (const field of OBJECT_LIST_FIELDS) {
    if (doc[field] !== undefined) {
      if (!Array.isArray(doc[field])) {
        die(`profile "${name}" (${file}): field "${field}" must be a list`);
      }
      for (const entry of doc[field]) {
        if (
          entry === null ||
          typeof entry !== 'object' ||
          Array.isArray(entry) ||
          typeof entry.src !== 'string' ||
          typeof entry.dst !== 'string'
        ) {
          die(`profile "${name}" (${file}): each "${field}" entry must have string "src" and "dst" fields`);
        }
      }
    }
  }
  if (doc.network !== undefined) {
    if (typeof doc.network !== 'object' || Array.isArray(doc.network) || doc.network === null) {
      die(`profile "${name}" (${file}): field "network" must be a mapping`);
    }
    if (doc.network.allow !== undefined && !isStringList(doc.network.allow)) {
      die(`profile "${name}" (${file}): field "network.allow" must be a list of strings`);
    }
  }
}

function isStringList(value) {
  return Array.isArray(value) && value.every((v) => typeof v === 'string');
}

// ---------------------------------------------------------------------------
// Composition / merge
// ---------------------------------------------------------------------------
function compose(profiles) {
  const merged = {
    mode: undefined,
    setup_script: undefined,
    setup_script_profile: null, // bookkeeping: which profile set setup_script
    capabilities: [],
    packages: [],
    plugins: [],
    marketplaces: [],
    enable_all_plugins: false,
    required_env: [],
    optional_env: [],
    network_allow: [],
    skills: [],
    hooks: [],
    agents: [],
    local: false,
  };

  // Track which profile last set each scalar, for conflict messages.
  const scalarOwner = {}; // field -> { profile, value }

  for (const p of profiles) {
    const { doc, name, dir } = p;

    // Scalars.
    for (const field of SCALAR_FIELDS) {
      if (doc[field] === undefined) continue;
      const value = doc[field];
      const prior = scalarOwner[field];
      if (prior && prior.value !== value) {
        die(
          `scalar conflict on field "${field}":\n` +
            `  profile "${prior.profile}" sets ${field}=${prior.value}\n` +
            `  profile "${name}" sets ${field}=${value}\n` +
            `Resolve by using only one of these profiles, or override with --mode at invocation time.`
        );
      }
      scalarOwner[field] = { profile: name, value };
    }

    // String lists (union, dedup, first-occurrence order).
    unionInto(merged.packages, doc.packages);
    unionInto(merged.plugins, doc.plugins);
    unionInto(merged.marketplaces, doc.marketplaces);
    unionInto(merged.capabilities, doc.capabilities);
    unionInto(merged.required_env, doc.required_env, p, 'required_env');
    unionInto(merged.optional_env, doc.optional_env);
    if (doc.network && doc.network.allow) {
      unionInto(merged.network_allow, doc.network.allow);
    }

    // enable_all_plugins: OR across all profiles.
    if (doc.enable_all_plugins === true) {
      merged.enable_all_plugins = true;
    }

    // Object lists (skills/hooks/agents) — resolve src relative to profile dir.
    for (const field of OBJECT_LIST_FIELDS) {
      if (doc[field] === undefined) continue;
      for (const entry of doc[field]) {
        const resolvedSrc = path.resolve(dir, entry.src);
        const pair = { src: resolvedSrc, dst: entry.dst, profile: name, profileDir: dir };
        // Dedup identical {resolvedSrc, dst}.
        const exists = merged[field].some((e) => e.src === pair.src && e.dst === pair.dst);
        if (!exists) merged[field].push(pair);
      }
    }
  }

  merged.mode = scalarOwner.mode ? scalarOwner.mode.value : undefined;
  if (scalarOwner.setup_script) {
    merged.setup_script = scalarOwner.setup_script.value;
    merged.setup_script_profile = scalarOwner.setup_script.profile;
  }

  return merged;
}

// Track which profile first introduced each required_env name (for error msgs).
const requiredEnvOwner = {};

function unionInto(target, source, profileObj, fieldTag) {
  if (!Array.isArray(source)) return;
  for (const item of source) {
    if (!target.includes(item)) {
      target.push(item);
      if (fieldTag === 'required_env' && profileObj && !(item in requiredEnvOwner)) {
        requiredEnvOwner[item] = profileObj.name;
      }
    }
  }
}

// ---------------------------------------------------------------------------
// Validation passes that run after composition.
// ---------------------------------------------------------------------------
function validateScalarPaths(profiles) {
  // setup_script resolves relative to the profile that declared it; existence-checked.
  for (const p of profiles) {
    if (typeof p.doc.setup_script === 'string') {
      const resolved = path.resolve(p.dir, p.doc.setup_script);
      if (!fs.existsSync(resolved)) {
        die(`profile "${p.name}": setup_script not found: ${resolved}`);
      }
    }
  }
}

function validateAndDetectLocal(merged) {
  const configRoot = path.resolve(path.join(xdgConfigHome(), 'ai-sandbox'));
  let local = false;
  let localWarned = false;

  for (const field of OBJECT_LIST_FIELDS) {
    for (const entry of merged[field]) {
      if (!fs.existsSync(entry.src)) {
        die(`profile "${entry.profile}": ${field} src not found: ${entry.src}`);
      }
      const profileDir = path.resolve(entry.profileDir);
      const insideProfileDir = isInside(entry.src, profileDir);
      const insideConfig = isInside(entry.src, configRoot);
      if (!insideProfileDir && !insideConfig) {
        local = true;
        if (!localWarned) {
          warn(
            `profile "${entry.profile}" references paths outside its directory and outside\n` +
              `${configRoot}. Setting local=true. This profile may not be usable\n` +
              `on other machines.`
          );
          localWarned = true;
        }
      }
    }
  }
  merged.local = local;
}

function isInside(child, parent) {
  const rel = path.relative(parent, child);
  return rel === '' || (!rel.startsWith('..') && !path.isAbsolute(rel));
}

function validateCapabilities(merged) {
  for (const cap of merged.capabilities) {
    const fragment = path.join(REPO_ROOT, 'docker', 'capabilities', `${cap}.dockerfile`);
    if (!fs.existsSync(fragment)) {
      die(`unknown capability "${cap}" — Dockerfile fragment not found: ${fragment}`);
    }
  }
}

function validateRequiredEnv(merged) {
  const missing = [];
  for (const name of merged.required_env) {
    if (!(name in process.env)) {
      const owner = requiredEnvOwner[name] || 'unknown';
      missing.push(`  ${name} (required by profile "${owner}")`);
    }
  }
  if (missing.length > 0) {
    die(`missing required environment variable(s):\n${missing.join('\n')}`);
  }
}

// ---------------------------------------------------------------------------
// Hash + tag
// ---------------------------------------------------------------------------
function computeHash(orderedNames, capabilities) {
  const sortedCaps = capabilities.slice().sort();
  const input = `${orderedNames.join(':')}:${sortedCaps.join(':')}`;
  return crypto.createHash('sha256').update(input).digest('hex').slice(0, HASH_LENGTH);
}

// ---------------------------------------------------------------------------
// Output rendering
// ---------------------------------------------------------------------------

// Shell-safe value. Bare when it is a "simple" token (so grep PROFILE_X=val and
// `eval`/source both work); single-quoted otherwise. Empty string emits as ''.
function shquote(value) {
  const s = String(value);
  if (s.length > 0 && /^[A-Za-z0-9_./:-]+$/.test(s)) {
    return s;
  }
  return `'${s.replace(/'/g, `'\\''`)}'`;
}

function renderEnvBlock(merged, hash, assembledDockerfile) {
  const sortedCaps = merged.capabilities.slice().sort();
  const lines = [];
  // PROFILE_IMAGE_TAG carries ONLY the suffix (profile-<hash>); the bash caller
  // (Task 005) prepends "ai-sandbox:". PROFILE_COMPOSITION_HASH is the bare hash.
  lines.push(`PROFILE_MODE=${shquote(merged.mode || '')}`);
  lines.push(`PROFILE_CAPABILITIES=${shquote(sortedCaps.join(' '))}`);
  lines.push(`PROFILE_LOCAL=${shquote(merged.local ? 'true' : 'false')}`);
  lines.push(`PROFILE_COMPOSITION_HASH=${shquote(hash)}`);
  lines.push(`PROFILE_IMAGE_TAG=${shquote(`profile-${hash}`)}`);
  lines.push(`PROFILE_SETUP_SCRIPT=${shquote(merged.setup_script_abs || '')}`);
  lines.push(`PROFILE_ASSEMBLED_DOCKERFILE=${shquote(assembledDockerfile)}`);
  return lines.join('\n');
}

function renderPathsBlock(merged) {
  // One "<absolute-src>\t<dst>" line per copy op, grouped into skills/hooks/agents
  // sub-sections each with its own sentinel.
  const lines = [];
  const sections = [
    [SENTINEL.skillsBegin, merged.skills],
    [SENTINEL.hooksBegin, merged.hooks],
    [SENTINEL.agentsBegin, merged.agents],
  ];
  for (const [sentinel, entries] of sections) {
    lines.push(sentinel);
    for (const e of entries) {
      lines.push(`${e.src}\t${e.dst}`);
    }
  }
  return lines.join('\n');
}

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

// ---------------------------------------------------------------------------
// Main
// ---------------------------------------------------------------------------
function main() {
  const opts = parseArgs(process.argv.slice(2));

  let names = opts.names;
  if (names.length === 0) {
    names = resolveDefaultProfiles();
  }

  // Resolve + dedup profile names (order-preserved) for the hash input.
  const orderedNames = [];
  for (const n of names) {
    if (!orderedNames.includes(n)) orderedNames.push(n);
  }

  const profiles = orderedNames.map(loadProfile);
  const merged = compose(profiles);

  // CLI --mode override wins over (and is consistent with) any profile mode.
  if (opts.mode !== null) {
    merged.mode = opts.mode;
  }

  validateScalarPaths(profiles);
  validateAndDetectLocal(merged);
  validateCapabilities(merged);
  validateRequiredEnv(merged);

  // Resolve the absolute setup_script path for the env block.
  if (merged.setup_script && merged.setup_script_profile) {
    const owner = profiles.find((p) => p.name === merged.setup_script_profile);
    merged.setup_script_abs = path.resolve(owner.dir, merged.setup_script);
  } else {
    merged.setup_script_abs = '';
  }

  const hash = computeHash(orderedNames, merged.capabilities);

  // Assembled-Dockerfile cache path. Create the dir; do NOT assemble here.
  const cacheDir = path.join(xdgCacheHome(), 'ai-sandbox');
  fs.mkdirSync(cacheDir, { recursive: true });
  const assembledDockerfile = path.join(cacheDir, `Dockerfile.${hash}`);

  const out = process.stdout;

  if (opts.output === 'env') {
    out.write(`${renderEnvBlock(merged, hash, assembledDockerfile)}\n`);
    return;
  }
  if (opts.output === 'paths') {
    out.write(`${renderPathsBlock(merged)}\n`);
    return;
  }
  if (opts.output === 'json') {
    out.write(`${renderJsonBlob(merged)}\n`);
    return;
  }

  // Full output: three sentinel-delimited blocks in order.
  out.write(`${SENTINEL.envBegin}\n`);
  out.write(`${renderEnvBlock(merged, hash, assembledDockerfile)}\n`);
  out.write(`${SENTINEL.envEnd}\n`);

  out.write(`${SENTINEL.pathsBegin}\n`);
  out.write(`${renderPathsBlock(merged)}\n`);
  out.write(`${SENTINEL.pathsEnd}\n`);

  out.write(`${SENTINEL.jsonBegin}\n`);
  out.write(`${renderJsonBlob(merged)}\n`);
  out.write(`${SENTINEL.jsonEnd}\n`);
}

main();
