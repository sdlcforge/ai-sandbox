# shellcheck shell=bash

Describe 'Dropped custom docker-granting profile does not orphan the sidecar (regression: capability loss on profile drop, phase-01/003)' integration
  # Regression coverage for task doc requirement 2
  # (plan/phase-01-fix-orphaned-sidecar-teardown/003-fix-capability-loss-on-profile-drop.md).
  #
  # task 002 (phase-01/002) fixed a hard-failure regression: when a restored
  # profile name no longer resolves, restore_saved_config() (src/utils.sh)
  # drops it with a warning instead of letting bin/profile-installer.js
  # hard-die() and abort teardown commands. That fix has its own edge case:
  # if the *specific* profile dropped is the one providing the `docker`
  # capability, EFFECTIVE_PROXY silently becomes false for the invocation and
  # COMPOSE_FILES omits docker-compose.proxy.yaml -- orphaning (delete/clean)
  # or failing to actually stop (stop) the docker-socket-proxy sidecar. This
  # task fixes that by falling back to the container's persisted
  # ai.sandbox.docker-proxy label (is_docker_proxy_label_true(), src/utils.sh)
  # when the current invocation's profile resolution would otherwise say the
  # capability is absent.
  #
  # Uses a throwaway project-local custom profile (not the bundled `docker`
  # profile) so that deleting the profile file simulates a profile becoming
  # unresolvable between `create` time and a later teardown command -- the
  # exact scenario the task doc's Requirement 2 asks for. The sidecar
  # container name is a fixed literal (`ai-sandbox-docker-proxy`, not scoped
  # per compose project -- see docker_proxy_teardown_spec.sh's header
  # comment), so at most one docker-capable instance may exist at a time; the
  # single Describe block below fully tears down before any other
  # docker-capable integration Describe block in this suite runs.

  CUSTOM_PROFILE_NAME="td-capdrop-docker"
  CUSTOM_PROFILE_PATH="./profiles/${CUSTOM_PROFILE_NAME}.yaml"

  create_docker_capdrop() {
    cat > "${CUSTOM_PROFILE_PATH}" <<'PROFILE_YAML'
metadata:
  name: td-capdrop-docker
  description: "Throwaway project-local profile for phase-01/003's capability-loss-on-profile-drop regression test"
capabilities: [docker]
PROFILE_YAML
    ./bin/ai-sandbox.sh instances create docker-td-capdrop --profile "${CUSTOM_PROFILE_NAME}" --quiet \
      2> ./.ai-sandbox.docker-td-capdrop.log || {
      cat ./.ai-sandbox.docker-td-capdrop.log >&2
      echo "Docker-capable instance 'docker-td-capdrop' failed to be created" >&2
      return 1
    }
    # Simulate the profile becoming unresolvable between `create` and the
    # later teardown command under test.
    rm -f "${CUSTOM_PROFILE_PATH}"
  }
  cleanup_docker_capdrop() {
    rm -f "${CUSTOM_PROFILE_PATH}"
    ./bin/ai-sandbox.sh docker-td-capdrop delete --quiet 2>/dev/null || true
    docker rm -f ai-sandbox-docker-proxy >/dev/null 2>&1 || true
    docker network rm ai-sandbox-docker-td-capdrop_docker-proxy >/dev/null 2>&1 || true
    docker network rm ai-sandbox-docker-td-capdrop_default >/dev/null 2>&1 || true
  }
  BeforeAll 'create_docker_capdrop'
  AfterAll 'cleanup_docker_capdrop'

  delete_docker_td_capdrop() {
    ./bin/ai-sandbox.sh docker-td-capdrop delete --quiet
  }

  It 'succeeds (no hard-abort, task 002) when deleting with no --profile flag against the now-unresolvable profile'
    When call delete_docker_td_capdrop
    The status should be success
    The stderr should include "dropping restored profile '${CUSTOM_PROFILE_NAME}'"
    The output should include "deleted"
  End

  It 'leaves no container (main or sidecar) for the project (regression: this task -- capability loss on profile drop previously orphaned the sidecar)'
    When call test -z "$(docker ps -a --filter 'label=com.docker.compose.project=ai-sandbox-docker-td-capdrop' --format '{{.Names}}')"
    The status should be success
  End

  It 'leaves no docker-proxy network for the project (regression: previously orphaned)'
    When call test -z "$(docker network ls --filter 'label=com.docker.compose.project=ai-sandbox-docker-td-capdrop' --filter 'name=docker-proxy' --format '{{.Name}}')"
    The status should be success
  End
End
