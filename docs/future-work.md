# Future Work

Deferred features and known gaps, recorded while the context is fresh so the
next person to pick them up isn't starting from zero.

## Symmetric host↔VM claude mutual exclusion via lockfile

### Problem

The pre-flight guard in `src/index.sh` (calling `check_host_plugin_conflicts`
from `src/utils.sh`) only prevents the container from starting when host-side
claude or plugin workers are already running. It does **not** prevent the user
from launching host-side claude while the ai-sandbox container is already
running. In that case, both sides can race on shared SQLite state (e.g.,
`~/.claude-mem`) and corrupt it.

### Current mitigation

A documented invariant — "don't run claude on both sides simultaneously" —
published in `README.md` under "Plugin support → Concurrency invariant".
Relies on user discipline.

### Proposed solution

At container start, write a lockfile at `~/.claude/.ai-sandbox.lock`
containing the container's name/PID and a timestamp. Clean it up on
container stop and on `trap EXIT` in the start script.

Provide a small host-side `claude` wrapper (e.g. shadowing the native binary
at `~/.local/bin/claude`, or as a `claude-safe` command on `PATH` ahead of
the real one) that refuses to start if the lockfile is held and its recorded
container is still running. On host-side `claude` startup:

1. Check for `~/.claude/.ai-sandbox.lock`.
2. If present, verify the referenced container is actually running
   (`docker inspect`) — stale locks (e.g. after a machine crash) should not
   block the user forever.
3. If the container is live, print the reverse of the pre-flight error
   message (naming the container, suggesting `ai-sandbox stop`) and exit
   nonzero.
4. Otherwise proceed; optionally clean the stale lock.

This makes the exclusion symmetric without requiring port coordination or
IPC. Defer until the documented invariant proves insufficient in practice.

## Architecture mismatch in plugin binaries

### Problem

The current design assumes plugin hooks execute via scripts (JS, Python,
bash) inside `~/.claude/plugins/cache/<marketplace>/<plugin>/<version>/`,
which are portable across macOS host and Linux container. If a future plugin
ships a natively compiled hook binary (e.g. a Go or Rust executable), its
Mach-O build on the macOS host would fail to execute inside the Linux VM
with `exec format error` — the same class of bug that originally motivated
dropping the `~/.local` bind mount.

### Proposed solution

Have the pre-flight walk each plugin's `installPath` from
`installed_plugins.json`, run `file(1)` against executables found there, and
warn when Mach-O content is detected under a plugin that claims to run
cross-platform. The long-term fix would require a per-plugin install
strategy in `~/.config/ai-sandbox/volume-maps` (or an adjacent
`plugin-catalog.yml`) where the user can declare "run this command inside
the container to install the Linux build of plugin X."

Not urgent — no known claude plugins ship native binaries today.
