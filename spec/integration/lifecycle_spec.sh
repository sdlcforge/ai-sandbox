# shellcheck shell=bash

Describe 'Docker lifecycle' integration
  Include "$PWD/bin/ai-sandbox.sh"
  # Ensure clean state before and after the suite
  cleanup_containers() {
    ./bin/ai-sandbox.sh clean 2> /dev/null # shellspec thinks it's an error if there is stderr output
  }
  BeforeAll 'cleanup_containers'
  AfterAll 'cleanup_containers'

  Describe 'cleanup_stale_container()'
    create_stale_container() {
      docker create --name ai-sandbox ubuntu:latest >/dev/null 2>&1 || true
    }
    Before 'create_stale_container'

    It 'removes a stale (created but not started) container'
      When call ./bin/ai-sandbox.sh clean
      The output should include "deleted 'ai-sandbox'"
      The status should be success
    End
  End

  Describe 'start from clean state'
    Before 'cleanup_containers'

    start_fresh() {
      ./bin/ai-sandbox.sh start >/dev/null 2>&1
    }
    Before 'start_fresh'

    It 'container is running'
      When call ./bin/ai-sandbox.sh --quiet status
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
      When call ./bin/ai-sandbox.sh --quiet status
      The output should include 'running'
    End
  End

  Describe 'stop'
    It 'removes the container with compose down'
      When call ./bin/ai-sandbox.sh --quiet stop 2>&1
      The stderr should include "Container ai-sandbox  Stopped"
      The status should be success
    End

    It 'container is gone after down'
      When call ./bin/ai-sandbox.sh --quiet status
      The output should eq 'nonexistant'
    End
  End
End
