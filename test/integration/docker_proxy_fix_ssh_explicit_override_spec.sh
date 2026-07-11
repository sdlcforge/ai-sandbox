# shellcheck shell=bash
# shellcheck disable=SC2016 # we want unexpanded shell expressions sent into the container

Describe 'Explicit capability-removing --profile on fix-ssh actually takes effect (regression: gate label fallback on explicit invocation, phase-01/005)' integration
  # Regression coverage for task doc requirement 3
  # (plan/phase-01-fix-orphaned-sidecar-teardown/005-gate-label-fallback-on-explicit-invocation.md).
  #
  # Task 004 scoped src/index.sh's EFFECTIVE_PROXY label fallback
  # (should_force_proxy_label_fallback(), src/utils.sh) to CMD in
  # {stop, delete, clean, fix-ssh} unconditionally -- correct for
  # stop/delete/clean (no legitimate "explicit invocation" story for a
  # teardown/preserve command), but wrong for fix-ssh: --profile is not
  # CMD-restricted in src/options.sh's flag parser, so `fix-ssh --profile
  # <non-docker>` is a real, reachable invocation shape, and fix_ssh()
  # force-recreates the ai-sandbox service (`docker compose ... up -d
  # --force-recreate --no-deps ai-sandbox`) -- the same recreate mechanism
  # start/enter use, whose explicit --profile override task 004 already
  # honors (see docker_proxy_explicit_profile_override_spec.sh). Task 004's
  # unconditional-true for fix-ssh meant the label fallback silently
  # overrode this explicit choice -- the same least-privilege violation
  # round 3 found for start/enter, narrowed to fix-ssh. This task widens
  # should_force_proxy_label_fallback() to also consult CONFIG_FLAGS_PROVIDED,
  # so an explicit `fix-ssh --profile <non-docker>` (CONFIG_FLAGS_PROVIDED=
  # true) now actually drops the capability instead of being silently
  # reverted, while a bare `fix-ssh` (CONFIG_FLAGS_PROVIDED=false, see
  # docker_proxy_teardown_spec.sh's "fix-ssh preserves Docker capability"
  # Describe, task 001/003) still preserves it.
  #
  # Assertion strategy mirrors docker_proxy_explicit_profile_override_spec.sh
  # (task 004): inspects the *result* the fallback would otherwise have
  # silently overridden -- the recreated container's own persisted
  # ai.sandbox.docker-proxy label and its DOCKER_HOST env var -- rather than
  # the internal `docker compose ... up -d` file-list argument, which isn't
  # observable from outside the process for a real recreate.

  INSTANCE_NAME="docker-td-fixsshoverride"

  create_docker_td_fixsshoverride() {
    ./bin/ai-sandbox.sh instances create "${INSTANCE_NAME}" --profile docker --quiet \
      2> "./.ai-sandbox.${INSTANCE_NAME}.log" || {
      cat "./.ai-sandbox.${INSTANCE_NAME}.log" >&2
      echo "Docker-capable instance '${INSTANCE_NAME}' failed to be created" >&2
      return 1
    }
  }
  cleanup_docker_td_fixsshoverride() {
    ./bin/ai-sandbox.sh "${INSTANCE_NAME}" delete --quiet 2>/dev/null || true
    docker rm -f ai-sandbox-docker-proxy >/dev/null 2>&1 || true
    docker network rm "ai-sandbox-${INSTANCE_NAME}_docker-proxy" >/dev/null 2>&1 || true
    docker network rm "ai-sandbox-${INSTANCE_NAME}_default" >/dev/null 2>&1 || true
  }
  BeforeAll 'create_docker_td_fixsshoverride'
  AfterAll 'cleanup_docker_td_fixsshoverride'

  fix_ssh_with_explicit_non_docker_profile() {
    # AI_SANDBOX_SKIP_PLUGIN_CHECK=1: fix-ssh in mirror mode runs the same
    # host-plugin-conflict preflight start/enter/up do (src/index.sh), which
    # would otherwise fail this test on any host with a live claude/
    # plugin-worker process -- unrelated to what this test verifies.
    AI_SANDBOX_SKIP_PLUGIN_CHECK=1 ./bin/ai-sandbox.sh "${INSTANCE_NAME}" fix-ssh --profile base --quiet \
      > "./.ai-sandbox.${INSTANCE_NAME}.fixssh.log" 2>&1 || {
      cat "./.ai-sandbox.${INSTANCE_NAME}.fixssh.log" >&2
      return 1
    }
  }

  It 'succeeds when running fix-ssh with an explicit non-docker --profile against a docker-capable instance'
    When call fix_ssh_with_explicit_non_docker_profile
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
