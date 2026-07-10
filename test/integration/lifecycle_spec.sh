# shellcheck shell=bash
# shellcheck disable=SC2034 # ShellSpec's "The variable X should ..." reads locals via framework assertions, not direct references

Describe 'Docker lifecycle' integration
  Include "$PWD/bin/ai-sandbox.sh"
  # Ensure clean state before and after the suite
  cleanup_containers() {
    ./bin/ai-sandbox.sh clean 2> /dev/null # shellspec thinks it's an error if there is stderr output
  }
  BeforeAll 'cleanup_containers'
  AfterAll 'cleanup_containers'

  Describe 'cleanup_stale_container()'
    # The anonymous/default instance's container is named "ai-sandbox-" (a
    # trailing hyphen, from container_name: ai-sandbox-${SANDBOX_NAME} with an
    # empty SANDBOX_NAME) under the current per-instance naming scheme -- see
    # src/utils.sh's sandbox_container_name(). A bare "ai-sandbox" (no
    # trailing hyphen) predates that scheme and is never matched by
    # cleanup_stale_container()/`clean`.
    create_stale_container() {
      docker create --name "ai-sandbox-" ubuntu:latest >/dev/null 2>&1 || true
    }
    Before 'create_stale_container'

    container_gone() {
      ! docker inspect "ai-sandbox-" >/dev/null 2>&1
    }

    It 'removes a stale (created but not started) container'
      # `clean` doesn't print a per-container confirmation message today, so
      # assert the observable side effect (the stale container is actually
      # gone) rather than matching on output text.
      ./bin/ai-sandbox.sh clean >/dev/null 2>&1
      clean_status=$?
      When call container_gone
      The status should be success
      The variable clean_status should eq 0
    End
  End

  Describe 'start from clean state'
    Before 'cleanup_containers'

    start_fresh() {
      ./bin/ai-sandbox.sh start >/dev/null 2>&1
    }
    Before 'start_fresh'

    It 'container is running'
      When call ./bin/ai-sandbox.sh --quiet detail
      The output should include 'running'
    End
  End

  Describe 'idempotent start'
    ensure_running() {
      ./bin/ai-sandbox.sh start --quiet 2>&1
    }
    Before 'ensure_running'

    It 'succeeds when container is already running'
      When call ensure_running
      The output should include 'Running'
      The status should be success
    End

    It 'container is still running after second start'
      When call ./bin/ai-sandbox.sh --quiet detail
      The output should include 'running'
    End
  End

  Describe 'stop'
    It 'removes the container with compose down'
      When call ./bin/ai-sandbox.sh --quiet --yes stop
      # docker compose's own progress output names the container per
      # container_name: ai-sandbox-${SANDBOX_NAME} (trailing hyphen for the
      # empty/anonymous SANDBOX_NAME here) -- see src/utils.sh's
      # sandbox_container_name().
      The stderr should include "Container ai-sandbox- Stopped"
      The status should be success
    End

    It 'container is gone after down'
      When call ./bin/ai-sandbox.sh --quiet detail
      The output should include 'Container: stopped'
    End
  End
End
