# shellcheck shell=bash
# shellcheck disable=SC2016 # single-quoted paths expand inside the container shell

Describe 'Clean-slate credential injection' integration
  # Uses a named sandbox ("credtest") to avoid colliding with the default
  # sandbox started by container_spec.sh when both run in the same session.
  start_clean_container() {
    ./bin/ai-sandbox.sh --clean credtest start --quiet \
      2> ./.ai-sandbox.credtest.log || {
      cat ./.ai-sandbox.credtest.log >&2
      echo "Clean-slate container 'credtest' failed to become ready" >&2
      return 1
    }
  }
  stop_clean_container() {
    ./bin/ai-sandbox.sh credtest stop --quiet 2>/dev/null || true
  }

  BeforeAll 'start_clean_container'
  AfterAll 'stop_clean_container'

  Describe '.claude directory in the container'
    It 'is owned by the container user (not root)'
      When call ./bin/ai-sandbox.sh --quiet credtest user-exec \
        sh -c 'stat -c "%U" ~/.claude'
      The output should eq "${USER}"
      The status should be success
    End
  End

  Describe '.credentials.json in the container'
    It 'exists at the expected path'
      When call ./bin/ai-sandbox.sh --quiet credtest user-exec \
        sh -c 'test -f ~/.claude/.credentials.json'
      The status should be success
    End

    It 'contains valid claudeAiOauth JSON'
      When call ./bin/ai-sandbox.sh --quiet credtest user-exec \
        sh -c 'jq -e .claudeAiOauth ~/.claude/.credentials.json >/dev/null && echo valid'
      The output should eq 'valid'
      The status should be success
    End

    It 'has mode 0600'
      When call ./bin/ai-sandbox.sh --quiet credtest user-exec \
        sh -c 'stat -c "%a" ~/.claude/.credentials.json'
      The output should eq '600'
      The status should be success
    End

    It 'is owned by the container user'
      When call ./bin/ai-sandbox.sh --quiet credtest user-exec \
        sh -c 'stat -c "%U" ~/.claude/.credentials.json'
      The output should eq "${USER}"
      The status should be success
    End
  End
End
