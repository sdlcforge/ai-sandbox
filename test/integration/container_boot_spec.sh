# shellcheck shell=bash
#
# Regression coverage for the "stray CLAUDE.md breaks container boot"
# incident: a stub `CLAUDE.md` file (stamped into a directory by an editor
# plugin, e.g. claude-mem) that lands inside docker/rootfs/etc/cont-init.d/,
# docker/rootfs/etc/cont-finish.d/, or docker/rootfs/usr/local/bin/ is
# invisible to `git status` (repo-wide .gitignore'd) but is NOT invisible to
# `docker build` -- docker/Dockerfile.base's `COPY rootfs/ /` plus its blind
# `chmod +x /etc/cont-init.d/* /etc/cont-finish.d/* ...` glob happily pick it
# up. s6-overlay's legacy-cont-init runner then tries to execute it as a boot
# stage; it has no shebang and isn't valid shell, so it exits nonzero. Because
# Dockerfile.base also bakes `ENV S6_BEHAVIOUR_IF_STAGE2_FAILS=2` (see
# firewall_fail_closed_spec.sh's rationale), ANY cont-init.d stage failure is
# now fatal to the whole boot -- so this single stray file halts the entire
# container. docker/.dockerignore (added alongside this spec) keeps such
# stray files out of the build context in the first place.
#
# This spec is a standalone, explicit assertion -- independent of any other
# integration spec file's container lifecycle -- that a fresh default
# (no-capability) boot via the normal launcher path reaches, and stays in, a
# running state. It forces its own clean slate before booting and tears its
# own container down afterward so it neither depends on nor leaks state
# relative to container_spec.sh / lifecycle_spec.sh, which exercise the same
# default instance name for their own purposes.
Describe 'Container boot (default, no-capability composition)' integration
  container_name='ai-sandbox-'

  ensure_clean_slate() {
    ./bin/ai-sandbox.sh clean >/dev/null 2>&1 || true
  }

  boot_fresh_container() {
    # AI_SANDBOX_SKIP_PLUGIN_CHECK=1: `start`'s host-plugin-conflict
    # preflight (src/plugin-conflicts.sh) would otherwise fail this test on
    # any host with a live claude/plugin-worker process -- an environmental
    # precondition unrelated to what this test verifies. Same rationale as
    # docker_proxy_start_drift_spec.sh's identical bypass.
    AI_SANDBOX_SKIP_PLUGIN_CHECK=1 ./bin/ai-sandbox.sh start --quiet \
      2> ./.ai-sandbox.container-boot-test.startup.log
  }

  teardown_container() {
    AI_SANDBOX_SKIP_PLUGIN_CHECK=1 ./bin/ai-sandbox.sh clean >/dev/null 2>&1 || true
  }

  BeforeAll 'ensure_clean_slate'
  BeforeAll 'boot_fresh_container'
  AfterAll 'teardown_container'

  # Poll (bounded) until the container's own boot log reports the
  # legacy-cont-init stage's terminal success marker, or until the container
  # stops running (whichever comes first -- no point polling a dead
  # container for a log line it will never emit). Mirrors the bounded-poll
  # style already used by firewall_fail_closed_spec.sh's
  # wait_until_stopped().
  wait_for_full_boot() {
    local name="$1" max_secs="${2:-45}" elapsed=0
    while [ "${elapsed}" -lt "${max_secs}" ]; do
      if docker logs "${name}" 2>&1 | grep -q 'legacy-services successfully started'; then
        return 0
      fi
      if [ "$(docker inspect -f '{{.State.Running}}' "${name}" 2>/dev/null)" != 'true' ]; then
        return 1
      fi
      sleep 1
      elapsed=$((elapsed + 1))
    done
    return 1
  }

  container_running() {
    [ "$(docker inspect -f '{{.State.Running}}' "$1" 2>/dev/null)" = 'true' ]
  }

  It 'reaches a fully-booted, running state on a fresh default boot (not halted by a bad cont-init.d stage)'
    When call wait_for_full_boot "${container_name}" 45
    The status should be success
  End

  It 'stays running afterward (no post-boot crash/halt)'
    When call container_running "${container_name}"
    The status should be success
  End
End
