# shellcheck shell=bash

Describe 'Named-instance enter' integration
  # Uses a named sandbox ("enter-test") to avoid colliding with the default
  # sandbox started by container_spec.sh or the "credtest" instance started
  # by clean_container_spec.sh when both run in the same session.
  create_instance() {
    ./bin/ai-sandbox.sh create enter-test --mode static --clean --quiet \
      2> ./.ai-sandbox.enter-test.log || {
      cat ./.ai-sandbox.enter-test.log >&2
      echo "Named instance 'enter-test' failed to be created" >&2
      return 1
    }
  }
  # `delete` is an explicit dispatch branch in src/index.sh (unlike a bare
  # passthrough `down`), so it is not affected by the separate pre-existing
  # ARGS[@] unbound-variable bug in the passthrough/user-exec/root-exec
  # branches under macOS system bash 3.2's `set -u`.
  delete_instance() {
    ./bin/ai-sandbox.sh enter-test delete --quiet 2>/dev/null || true
  }

  BeforeAll 'create_instance'
  AfterAll 'delete_instance'

  Describe 'enter after create'
    # `</dev/null` is required: ShellSpec's executor reads test code from a
    # pipe on stdin, and `enter` execs an interactive shell (`bash -c
    # "...exec zsh"`) that inherits and would otherwise consume that pipe,
    # truncating subsequent tests and the FINISHED event. Same reasoning as
    # container_spec.sh's "detects drift after a container-side write" test.
    # The `2>&1` must live inside the function body (not appended to the
    # `When call` line) so ShellSpec's own stdout capture actually receives
    # the merged stream, matching lifecycle_spec.sh's `ensure_running`
    # convention.
    enter_instance() {
      ./bin/ai-sandbox.sh enter-test enter </dev/null 2>&1
    }

    It 'succeeds cleanly on the first enter'
      When call enter_instance
      The status should be success
      The output should not include 'Build inputs changed'
      The output should not include 'is not running'
    End

    It 'succeeds cleanly on the immediately-following second enter'
      # This is the actual repro shape from the original bug report: the
      # spurious rebuild and the wrong-compose-project-scope failure only
      # manifested on the *second* enter invocation, right after `create`
      # had just built the image.
      When call enter_instance
      The status should be success
      The output should not include 'Build inputs changed'
      The output should not include 'is not running'
    End

    It 'leaves the container running'
      When call ./bin/ai-sandbox.sh --quiet enter-test status
      The output should include 'running'
    End
  End
End
