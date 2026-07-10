# shellcheck shell=bash
# shellcheck disable=SC2016 # we want unexpanded shell expressions sent into the container

Describe 'Docker-capable instance teardown (regression: orphaned sidecar bug)' integration
  # Regression coverage for the bug where every per-instance command other
  # than start/enter (delete, clean, stop, fix-ssh) ran without restoring the
  # instance's persisted `docker` capability when no --profile flag was
  # re-passed on the follow-up invocation -- silently dropping EFFECTIVE_PROXY
  # from that invocation's compose-file assembly and orphaning (or failing to
  # tear down / failing to preserve) the docker-socket-proxy sidecar container
  # and its `docker-proxy` network. Crucially, none of the commands below
  # re-pass --profile docker -- unlike this directory's sibling
  # docker_proxy_spec.sh, whose `stop_with_proxy` helper currently masks this
  # exact bug for `stop` by re-specifying --profile docker on every call.
  #
  # Empirically confirmed during development of this test (via a manual
  # `instances create <name> --profile docker` + `docker ps -a`/
  # `docker network ls` inspection): the sidecar container's compose-assigned
  # name is a fixed literal (`container_name: ai-sandbox-docker-proxy` in
  # docker/docker-compose.proxy.yaml), not scoped per compose project --
  # so at most one docker-capable instance can exist at a time across the
  # whole suite. Compose still labels the container with the owning project
  # (`com.docker.compose.project=ai-sandbox-<name>`), so the project-label
  # filters below correctly scope assertions to just the instance under test.
  # The `docker-proxy` *network*, by contrast, is project-scoped
  # (`ai-sandbox-<name>_docker-proxy`), matching every other compose-managed
  # network in this codebase.
  #
  # Each Describe below therefore fully deletes its instance (and force-cleans
  # the singleton sidecar container name / project-scoped network as a
  # fallback in case the assertion under test fails and leaves something
  # behind) before the next Describe creates its own instance, so no two
  # scenarios' docker-capable instances are ever alive at the same time.

  Describe 'delete orphans nothing'
    create_docker_td_delete() {
      ./bin/ai-sandbox.sh instances create docker-td-delete --profile docker --quiet \
        2> ./.ai-sandbox.docker-td-delete.log || {
        cat ./.ai-sandbox.docker-td-delete.log >&2
        echo "Docker-capable instance 'docker-td-delete' failed to be created" >&2
        return 1
      }
    }
    cleanup_docker_td_delete() {
      ./bin/ai-sandbox.sh docker-td-delete delete --quiet 2>/dev/null || true
      docker rm -f ai-sandbox-docker-proxy >/dev/null 2>&1 || true
      docker network rm ai-sandbox-docker-td-delete_docker-proxy >/dev/null 2>&1 || true
      docker network rm ai-sandbox-docker-td-delete_default >/dev/null 2>&1 || true
    }
    BeforeAll 'create_docker_td_delete'
    AfterAll 'cleanup_docker_td_delete'

    delete_docker_td_delete() {
      ./bin/ai-sandbox.sh docker-td-delete delete --quiet >/dev/null 2>&1
    }

    It 'succeeds when deleting with no --profile flag'
      When call delete_docker_td_delete
      The status should be success
    End

    It 'leaves no container (main or sidecar) for the project (regression: sidecar previously orphaned)'
      When call test -z "$(docker ps -a --filter 'label=com.docker.compose.project=ai-sandbox-docker-td-delete' --format '{{.Names}}')"
      The status should be success
    End

    It 'leaves no docker-proxy network for the project (regression: previously orphaned)'
      When call test -z "$(docker network ls --filter 'label=com.docker.compose.project=ai-sandbox-docker-td-delete' --filter 'name=docker-proxy' --format '{{.Name}}')"
      The status should be success
    End
  End

  Describe 'stop actually stops the sidecar'
    create_docker_td_stop() {
      ./bin/ai-sandbox.sh instances create docker-td-stop --profile docker --quiet \
        2> ./.ai-sandbox.docker-td-stop.log || {
        cat ./.ai-sandbox.docker-td-stop.log >&2
        echo "Docker-capable instance 'docker-td-stop' failed to be created" >&2
        return 1
      }
    }
    cleanup_docker_td_stop() {
      ./bin/ai-sandbox.sh docker-td-stop delete --quiet 2>/dev/null || true
      docker rm -f ai-sandbox-docker-proxy >/dev/null 2>&1 || true
      docker network rm ai-sandbox-docker-td-stop_docker-proxy >/dev/null 2>&1 || true
      docker network rm ai-sandbox-docker-td-stop_default >/dev/null 2>&1 || true
    }
    BeforeAll 'create_docker_td_stop'
    AfterAll 'cleanup_docker_td_stop'

    stop_docker_td_stop() {
      ./bin/ai-sandbox.sh docker-td-stop stop --quiet >/dev/null 2>&1
    }

    It 'succeeds when stopping with no --profile flag'
      When call stop_docker_td_stop
      The status should be success
    End

    It 'leaves the sidecar container stopped, not running (regression: previously left running/orphaned)'
      When call docker ps -a --filter 'name=ai-sandbox-docker-proxy' --format '{{.State}}'
      The output should not include 'running'
      The output should be present
    End
  End

  Describe 'fix-ssh preserves Docker capability'
    create_docker_td_fixssh() {
      ./bin/ai-sandbox.sh instances create docker-td-fixssh --profile docker --quiet \
        2> ./.ai-sandbox.docker-td-fixssh.log || {
        cat ./.ai-sandbox.docker-td-fixssh.log >&2
        echo "Docker-capable instance 'docker-td-fixssh' failed to be created" >&2
        return 1
      }
    }
    cleanup_docker_td_fixssh() {
      ./bin/ai-sandbox.sh docker-td-fixssh delete --quiet 2>/dev/null || true
      docker rm -f ai-sandbox-docker-proxy >/dev/null 2>&1 || true
      docker network rm ai-sandbox-docker-td-fixssh_docker-proxy >/dev/null 2>&1 || true
      docker network rm ai-sandbox-docker-td-fixssh_default >/dev/null 2>&1 || true
    }
    BeforeAll 'create_docker_td_fixssh'
    AfterAll 'cleanup_docker_td_fixssh'

    fixssh_docker_td_fixssh() {
      ./bin/ai-sandbox.sh docker-td-fixssh fix-ssh --quiet >/dev/null 2>&1
    }

    It 'succeeds when running fix-ssh with no --profile flag'
      When call fixssh_docker_td_fixssh
      The status should be success
    End

    It 'still resolves DOCKER_HOST to the socket proxy after the recreate (regression: previously silently lost)'
      # 'should include', not 'should equal': a preflight "Checking docker is
      # running... confirmed." line leaks onto stdout regardless of --quiet
      # here -- a separate, already-tracked pre-existing qecho()/QUIET
      # inversion bug (out of scope for this task; see the
      # 2026-07-10-fix-quiet-stdout-leak-and-stat branch), not something this
      # fix touches.
      When call ./bin/ai-sandbox.sh --quiet docker-td-fixssh user-exec zsh -c 'echo $DOCKER_HOST'
      The output should include 'tcp://docker-socket-proxy:2375'
      The status should be success
    End
  End

  Describe 'clean orphans nothing'
    # Runs last: do_clean_images() (invoked by `clean`) sweeps every
    # ai-sandbox:* image from the local daemon, which would force an
    # unnecessary rebuild for any scenario above that ran afterward.
    create_docker_td_clean() {
      ./bin/ai-sandbox.sh instances create docker-td-clean --profile docker --quiet \
        2> ./.ai-sandbox.docker-td-clean.log || {
        cat ./.ai-sandbox.docker-td-clean.log >&2
        echo "Docker-capable instance 'docker-td-clean' failed to be created" >&2
        return 1
      }
    }
    cleanup_docker_td_clean() {
      ./bin/ai-sandbox.sh docker-td-clean delete --quiet 2>/dev/null || true
      docker rm -f ai-sandbox-docker-proxy >/dev/null 2>&1 || true
      docker network rm ai-sandbox-docker-td-clean_docker-proxy >/dev/null 2>&1 || true
      docker network rm ai-sandbox-docker-td-clean_default >/dev/null 2>&1 || true
    }
    BeforeAll 'create_docker_td_clean'
    AfterAll 'cleanup_docker_td_clean'

    clean_docker_td_clean() {
      ./bin/ai-sandbox.sh docker-td-clean clean --quiet >/dev/null 2>&1
    }

    It 'succeeds when cleaning with no --profile flag'
      When call clean_docker_td_clean
      The status should be success
    End

    It 'leaves no container (main or sidecar) for the project (regression: sidecar previously orphaned)'
      When call test -z "$(docker ps -a --filter 'label=com.docker.compose.project=ai-sandbox-docker-td-clean' --format '{{.Names}}')"
      The status should be success
    End

    It 'leaves no docker-proxy network for the project (regression: previously orphaned)'
      When call test -z "$(docker network ls --filter 'label=com.docker.compose.project=ai-sandbox-docker-td-clean' --filter 'name=docker-proxy' --format '{{.Name}}')"
      The status should be success
    End
  End
End
