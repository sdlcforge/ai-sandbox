# shellcheck shell=bash
# shellcheck disable=SC2016 # we want unexpanded shell expressions sent into the container

Describe 'Bare start with profile drift still preserves the docker capability (regression: gate label fallback on explicit invocation, phase-01/005)' integration
  # Regression coverage for task doc requirement 2
  # (plan/phase-01-fix-orphaned-sidecar-teardown/005-gate-label-fallback-on-explicit-invocation.md).
  #
  # Task 004 scoped src/index.sh's EFFECTIVE_PROXY label fallback
  # (should_force_proxy_label_fallback(), src/utils.sh) to CMD in
  # {stop, delete, clean, fix-ssh} only, excluding start/enter/up
  # unconditionally so an explicit, confirmed --profile change could actually
  # drop the docker capability. The fourth phase-1 gate review found that
  # CMD-only gating wrong: a *bare* start/enter (CONFIG_FLAGS_PROVIDED=false,
  # no --profile this run) is a restore/resume, not an explicit override --
  # restore_saved_config() decides composition, not the user. If the
  # instance's docker-granting profile has since become unresolvable (the
  # same drift scenario task 003 fixed for teardown), restore_saved_config()
  # drops it (task 002's graceful-degradation warning) and
  # profile_has_capability docker resolves false for this invocation, but
  # task 004's should_force_proxy_label_fallback() excluded start/enter
  # unconditionally, so EFFECTIVE_PROXY was never corrected back to true even
  # though the persisted ai.sandbox.docker-proxy label says so -- silently
  # losing the capability again on the concrete not-currently-running-recreate
  # path (`is_container_running && ! running_config_matches` never fires when
  # nothing is running, so start proceeds straight to `docker compose ... up
  # -d` with no prompt, no warning, no fallback correction). This task widens
  # should_force_proxy_label_fallback() to also consult CONFIG_FLAGS_PROVIDED,
  # so a bare start/enter still gets the fallback while an explicit
  # start/enter/fix-ssh/up --profile still doesn't (see
  # docker_proxy_explicit_profile_override_spec.sh, task 004's own regression
  # test, which stays unaffected: its start --profile base scenario already
  # has CONFIG_FLAGS_PROVIDED=true).
  #
  # Uses a throwaway project-local custom profile (not the bundled `docker`
  # profile), mirroring docker_proxy_dropped_profile_spec.sh (task 003), so
  # that deleting the profile file simulates the profile becoming
  # unresolvable between `create` time and this later `start`. The instance
  # is explicitly stopped first (`stop`) so that the subsequent bare `start`
  # is a not-currently-running recreate -- the exact path where the
  # `is_container_running && ! running_config_matches` confirmation gate
  # never fires and (pre-fix) the capability was silently lost with no
  # prompt at all.
  #
  # The sidecar container name is a fixed literal (`ai-sandbox-docker-proxy`,
  # not scoped per compose project -- see docker_proxy_teardown_spec.sh's
  # header comment), so at most one docker-capable instance may exist at a
  # time; this Describe block fully tears down before/after itself.

  CUSTOM_PROFILE_NAME="td-startdrift-docker"
  CUSTOM_PROFILE_PATH="./profiles/${CUSTOM_PROFILE_NAME}.yaml"
  INSTANCE_NAME="docker-td-startdrift"

  create_docker_td_startdrift() {
    cat > "${CUSTOM_PROFILE_PATH}" <<'PROFILE_YAML'
metadata:
  name: td-startdrift-docker
  description: "Throwaway project-local profile for phase-01/005's bare-start-with-profile-drift regression test"
capabilities: [docker]
PROFILE_YAML
    ./bin/ai-sandbox.sh instances create "${INSTANCE_NAME}" --profile "${CUSTOM_PROFILE_NAME}" --quiet \
      2> "./.ai-sandbox.${INSTANCE_NAME}.log" || {
      cat "./.ai-sandbox.${INSTANCE_NAME}.log" >&2
      echo "Docker-capable instance '${INSTANCE_NAME}' failed to be created" >&2
      return 1
    }
    # Stop the container so the later bare `start` is a not-currently-running
    # recreate (the concrete path where the confirmation gate never fires).
    ./bin/ai-sandbox.sh "${INSTANCE_NAME}" stop --quiet \
      2>> "./.ai-sandbox.${INSTANCE_NAME}.log" || {
      cat "./.ai-sandbox.${INSTANCE_NAME}.log" >&2
      echo "Failed to stop '${INSTANCE_NAME}' ahead of the drift scenario" >&2
      return 1
    }
    # Simulate the profile becoming unresolvable between `create` and the
    # later bare `start` under test.
    rm -f "${CUSTOM_PROFILE_PATH}"
  }
  cleanup_docker_td_startdrift() {
    rm -f "${CUSTOM_PROFILE_PATH}"
    ./bin/ai-sandbox.sh "${INSTANCE_NAME}" delete --quiet 2>/dev/null || true
    docker rm -f ai-sandbox-docker-proxy >/dev/null 2>&1 || true
    docker network rm "ai-sandbox-${INSTANCE_NAME}_docker-proxy" >/dev/null 2>&1 || true
    docker network rm "ai-sandbox-${INSTANCE_NAME}_default" >/dev/null 2>&1 || true
  }
  BeforeAll 'create_docker_td_startdrift'
  AfterAll 'cleanup_docker_td_startdrift'

  start_docker_td_startdrift() {
    # AI_SANDBOX_SKIP_PLUGIN_CHECK=1: `start` in mirror mode runs
    # check_host_plugin_conflicts() (src/plugin-conflicts.sh), which would
    # otherwise fail this test on any host with a live claude/plugin-worker
    # process -- an environmental precondition unrelated to what this test
    # verifies. No --profile flag is passed here: CONFIG_FLAGS_PROVIDED must
    # be false for this to be the bare-restore/resume scenario under test.
    # Not redirecting stderr here (unlike the BeforeAll helper above): the
    # 'dropping restored profile' warning below is the assertion target, so
    # it must reach ShellSpec's own stderr capture rather than a log file.
    AI_SANDBOX_SKIP_PLUGIN_CHECK=1 ./bin/ai-sandbox.sh "${INSTANCE_NAME}" start --quiet
  }

  It 'succeeds (no hard-abort, task 002) when starting bare against the now-unresolvable profile'
    When call start_docker_td_startdrift
    The status should be success
    The stderr should include "dropping restored profile '${CUSTOM_PROFILE_NAME}'"
    # Not asserting further on stdout content: unrelated tool-cache/preflight
    # noise leaks onto stdout here regardless of --quiet -- the same
    # pre-existing qecho()/QUIET inversion bug docker_proxy_teardown_spec.sh's
    # "fix-ssh preserves Docker capability" Describe already calls out (see
    # the 2026-07-10-fix-quiet-stdout-leak-and-stat branch), not something
    # this task touches. `The output should be present` only satisfies
    # ShellSpec's own unasserted-stdout warning-as-failure gate.
    The output should be present
  End

  It 'still has the persisted docker-proxy label true on the recreated container (regression: capability must survive the drift)'
    When call docker inspect -f '{{index .Config.Labels "ai.sandbox.docker-proxy"}}' "ai-sandbox-${INSTANCE_NAME}"
    The output should equal 'true'
    The status should be success
  End

  It 'still resolves DOCKER_HOST inside the recreated container (regression: previously silently lost with no prompt at all)'
    When call ./bin/ai-sandbox.sh --quiet "${INSTANCE_NAME}" user-exec zsh -c 'echo $DOCKER_HOST'
    The output should include 'tcp://docker-socket-proxy:2375'
    The status should be success
  End
End
