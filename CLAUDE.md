# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project overview

`ai-sandbox` is a macOS-first bash CLI that wraps `docker compose` to run Claude Code (and other agents) in an isolated Ubuntu container. The container mirrors the host's identity (SSH keys, git config, `~/.claude`, `~/.config`) and enforces an iptables-based allow-list to GitHub and Anthropic APIs.

## Architecture

Read [`docs/architecture.md`](docs/architecture.md) for the full picture. The short version:

- Sources live in `src/`; `@liquid-labs/bash-rollup` bundles them into `bin/ai-sandbox.sh`. **Never edit the rollup output directly.**
- `src/index.sh` is the entry point and drives a sequence of explicit phases (parse options → preflights → flag validation → compose-file assembly → dispatch). Each module owns one phase.
- Each unique build-flag combo produces its own `ai-sandbox:<variant>` image; `is_build_stale` uses the image's own `docker inspect .Created` timestamp — no marker file.
- `__SOURCED__=1` guard in `index.sh` lets tests include the rolled-up script as a library.
- Makefiles under `make/` are **generated** by `@sdlcforge/gen-make`; each fragment carries a "Do not edit manually" header.

## Build, lint, test

```bash
make build          # roll src/ into bin/ai-sandbox.sh
make lint           # shellcheck across src/, docker/, test/
make test           # unit + integration
make test.unit
make test.integration   # gated by `status --test-check`
make qa             # lint + tests

shellspec test/unit/ai_sandbox_spec.sh             # one spec file
shellspec test/unit/ai_sandbox_spec.sh -e 'pattern' # one example
```

`package.json` scripts proxy to `make` targets — note the typo `test.intgeration`; use the Makefile target directly.

`make test.integration` runs `./bin/ai-sandbox.sh status --test-check` first. If host-side claude or plugin-worker processes are detected, it prints `Preflight checks failed; test not run.` and exits. Clear with `ai-sandbox kill-local-ai` or set `AI_SANDBOX_SKIP_PLUGIN_CHECK=1` to bypass.

## Conventions

- Edit `src/` modules, not `bin/ai-sandbox.sh`. Run `make build` after edits.
- Shellcheck must pass. When disabling a check, include an inline reason comment.
- `qecho` respects `QUIET` — use it for informational output, plain `echo`/`printf` for errors and output that must always show.
- `status` defaults to verbose (`QUIET=0`) but goes silent under `--json` or `--test-check`.
- Plugin-name matching in `plugin-conflicts.sh` is deliberately strict (path component / argv token, not substring) to avoid false positives like env vars such as `CURSOR_WORKSPACE_LABEL=github-toolkit` matching a `github` plugin. Preserve this when extending the check.
