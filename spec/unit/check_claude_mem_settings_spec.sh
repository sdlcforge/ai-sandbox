# shellcheck shell=bash
# shellcheck disable=SC2155 # export+assign in test setup; masking return value is harmless here

Describe 'check-claude-mem-settings.sh'
  setup() {
    export ORIG_HOME="$HOME"
    export HOME="$(mktemp -d)"
  }
  cleanup() {
    rm -rf "$HOME"
    export HOME="$ORIG_HOME"
  }
  Before 'setup'
  After 'cleanup'

  It 'exits 0 with message when settings file is missing'
    When call ./ai-sandbox.sh check-settings
    The output should include 'not found'
    The status should be success
  End

  It 'adds CLAUDE_MEM_WORKER_HOST when not set'
    mkdir -p "$HOME/.claude-mem"
    echo '{}' > "$HOME/.claude-mem/settings.json"
    When call ./ai-sandbox.sh check-settings
    The output should include 'Adding CLAUDE_MEM_WORKER_HOST'
    The status should be success
    The contents of file "$HOME/.claude-mem/settings.json" should include '0.0.0.0'
  End

  It 'is a no-op when already set to 0.0.0.0'
    mkdir -p "$HOME/.claude-mem"
    echo '{"CLAUDE_MEM_WORKER_HOST":"0.0.0.0"}' > "$HOME/.claude-mem/settings.json"
    When call ./ai-sandbox.sh check-settings
    The output should include 'already configured'
    The status should be success
  End

  It 'updates from 127.0.0.1 to 0.0.0.0'
    mkdir -p "$HOME/.claude-mem"
    echo '{"CLAUDE_MEM_WORKER_HOST":"127.0.0.1"}' > "$HOME/.claude-mem/settings.json"
    When call ./ai-sandbox.sh check-settings
    The output should include 'Updating'
    The status should be success
    The contents of file "$HOME/.claude-mem/settings.json" should include '0.0.0.0'
  End

  It 'warns and exits 1 for unexpected value'
    mkdir -p "$HOME/.claude-mem"
    echo '{"CLAUDE_MEM_WORKER_HOST":"10.0.0.1"}' > "$HOME/.claude-mem/settings.json"
    When call ./ai-sandbox.sh check-settings
    The output should include 'WARNING'
    The status should be failure
  End
End
