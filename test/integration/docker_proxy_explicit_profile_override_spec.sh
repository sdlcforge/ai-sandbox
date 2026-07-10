# shellcheck shell=bash
# shellcheck disable=SC2016 # we want unexpanded shell expressions sent into the container

Describe 'Explicit capability-removing --profile on start actually takes effect (regression: scope proxy-label fallback to teardown/preserve commands only, phase-01/004)' integration
  # Regression coverage for task doc requirement 3 item 1
  # (plan/phase-01-fix-orphaned-sidecar-teardown/004-scope-proxy-label-fallback.md).
  #
  # Task 003's EFFECTIVE_PROXY label fallback (src/index.sh, guarded by
  # is_docker_proxy_label_true(), src/utils.sh) was scoped too broadly per the
  # third phase-1 gate review: it fired for *every* per-instance CMD,
  # including start/enter, which meant an explicit, user-confirmed --profile
  # change removing the `docker` capability was silently reverted -- the
  # persisted ai.sandbox.docker-proxy label from `create` time forced
  # EFFECTIVE_PROXY back to true, re-granting network access to the
  # docker-socket-proxy sidecar (a documented container-escape vector, see
  # docker/docker-compose.proxy.yaml's own security note) against the user's
  # explicit intent, with no warning. should_force_proxy_label_fallback()
  # (src/utils.sh) now scopes the fallback to stop/delete/clean/fix-ssh only,
  # so an explicit `start --profile <non-docker>` against a docker-capable
  # instance actually drops the capability as requested instead of silently
  # keeping it.
  #
  # Uses `start` rather than `enter`: `enter` additionally calls
  # start_shell(), which execs an interactive zsh inside the container -- not
  # safe to drive from a non-tty test harness. `start` exercises the exact
  # same EFFECTIVE_PROXY / COMPOSE_FILES assembly path without attaching a
  # shell.
  #
  # A live-Docker integration test (rather than a mocked-docker unit-level
  # `When run script` test, task 002/003's usual pattern for this file) was
  # chosen for this specific regression: CMD=start (unlike delete/stop/clean,
  # which task 002/003's own dispatch tests cover) also triggers
  # resolve_and_download_tools() (src/tool-versions.sh) before command
  # dispatch, which shells out to several real upstream version-check
  # endpoints via `curl` under `set -euo pipefail`. Mocking that codepath
  # convincingly (every tool's curl-then-cache-fallback pair, each embedded in
  # its own `||`-guarded pipeline) would add far more incidental test
  # complexity than it removes, and create a real risk of masking a genuine
  # `errexit`/`pipefail` interaction bug behind an over-permissive mock. This
  # file instead follows this suite's existing live-Docker precedent (e.g.
  # docker_proxy_teardown_spec.sh, docker_proxy_dropped_profile_spec.sh),
  # which already builds and starts real docker-capable instances.
  #
  # Assertion strategy: rather than trying to inspect the actual `docker
  # compose ... up -d` invocation's file-list argument (not observable from
  # outside the process for a real container recreate), this inspects the
  # *result* the fallback would otherwise have silently overridden: the
  # recreated container's own persisted ai.sandbox.docker-proxy label (set
  # directly from EFFECTIVE_PROXY by docker/docker-compose.yaml) and its
  # DOCKER_HOST env var (only present when docker-compose.proxy.yaml's
  # ai-sandbox service overlay was actually included).

  INSTANCE_NAME="docker-td-explicit-override"

  create_docker_td_explicit_override() {
    ./bin/ai-sandbox.sh instances create "${INSTANCE_NAME}" --profile docker --quiet \
      2> "./.ai-sandbox.${INSTANCE_NAME}.log" || {
      cat "./.ai-sandbox.${INSTANCE_NAME}.log" >&2
      echo "Docker-capable instance '${INSTANCE_NAME}' failed to be created" >&2
      return 1
    }
  }
  cleanup_docker_td_explicit_override() {
    ./bin/ai-sandbox.sh "${INSTANCE_NAME}" delete --quiet 2>/dev/null || true
    docker rm -f ai-sandbox-docker-proxy >/dev/null 2>&1 || true
    docker network rm "ai-sandbox-${INSTANCE_NAME}_docker-proxy" >/dev/null 2>&1 || true
    docker network rm "ai-sandbox-${INSTANCE_NAME}_default" >/dev/null 2>&1 || true
  }
  BeforeAll 'create_docker_td_explicit_override'
  AfterAll 'cleanup_docker_td_explicit_override'

  start_with_explicit_non_docker_profile() {
    # AI_SANDBOX_SKIP_PLUGIN_CHECK=1: `start` in mirror mode runs
    # check_host_plugin_conflicts() (src/plugin-conflicts.sh), which would
    # otherwise fail this test on any host with a live claude/plugin-worker
    # process -- an environmental precondition unrelated to what this test
    # verifies. --yes auto-confirms the recreate prompt running_config_matches()
    # (src/utils.sh) triggers here (the resolved composition hash changes from
    # `docker` to `base`). stderr is redirected to a log file (same pattern as
    # the BeforeAll helper above) rather than left for ShellSpec to check,
    # since `docker compose up -d` expectedly logs a harmless "Found orphan
    # containers ([ai-sandbox-docker-proxy])" warning here -- compose doesn't
    # remove a service dropped from this invocation's file list without
    # --remove-orphans, which this codebase deliberately doesn't pass (an
    # unrelated, pre-existing orphan-cleanup gap, not in this task's scope).
    # That warning is incidental log noise, not a test assertion target; the
    # two Its below assert the actual outcome directly (the label + DOCKER_HOST
    # on the recreated container).
    AI_SANDBOX_SKIP_PLUGIN_CHECK=1 ./bin/ai-sandbox.sh "${INSTANCE_NAME}" start --profile base --yes --quiet \
      > "./.ai-sandbox.${INSTANCE_NAME}.start.log" 2>&1 || {
      cat "./.ai-sandbox.${INSTANCE_NAME}.start.log" >&2
      return 1
    }
  }

  It 'succeeds when starting with an explicit non-docker --profile against a docker-capable instance'
    When call start_with_explicit_non_docker_profile
    The status should be success
  End

  It 'drops the persisted docker-proxy label on the recreated container (explicit profile change takes effect, not silently reverted by the label fallback)'
    When call docker inspect -f '{{index .Config.Labels "ai.sandbox.docker-proxy"}}' "ai-sandbox-${INSTANCE_NAME}"
    The output should equal 'false'
    The status should be success
  End

  It 'no longer resolves DOCKER_HOST inside the recreated container (docker capability actually removed, sidecar access not re-granted)'
    When call ./bin/ai-sandbox.sh --quiet "${INSTANCE_NAME}" user-exec zsh -c 'echo $DOCKER_HOST'
    The output should not include 'tcp://docker-socket-proxy:2375'
    The status should be success
  End
End
