# Profiles

This directory contains the bundled standard profiles shipped with ai-sandbox. A profile is a YAML file that defines a reproducible ai-sandbox environment — which packages to install, which capabilities to enable, and which container mode (`mirror` vs. `static`) to use.

## Available profiles

| Name | Description |
|------|-------------|
| `base` | The fully-featured default runtime. Compose with a mode profile for a complete environment. |
| `docker` | Adds Docker CLI and socket-proxy sidecar access. |
| `chromium` | Adds Chromium browser and X11 forwarding. |
| `mirror` | Selects host-identity mirroring (SSH keys, git config, `~/.claude`, `~/.config`). |
| `static` | Selects self-contained mode with no host identity mirroring; suitable for CI/CD. |

## Usage

Pass one or more `--profile` flags to `ai-sandbox start`. Profiles are merged left to right:

```sh
ai-sandbox start --profile base --profile mirror
ai-sandbox start --profile base --profile mirror --profile docker
```

The default composition when no `--profile` flags are given is `[base, mirror]`, which reproduces pre-profile behavior.

## Full schema reference

See [docs/ai-sandbox-profiles-spec.md](../docs/ai-sandbox-profiles-spec.md) for the complete YAML schema, composition rules, storage and discovery order, and all available fields.
