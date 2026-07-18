# shellcheck shell=bash
# shellcheck disable=SC2034,SC2155,SC2317,SC2329 # ShellSpec DSL invokes functions indirectly

Describe 'plugin pre-flight (src/utils.sh)'
  Include "$PWD/bin/ai-sandbox.sh"

  setup() {
    export ORIG_HOME="$HOME"
    export HOME="$(mktemp -d)"
    mkdir -p "$HOME/.claude/plugins"
  }
  cleanup() {
    rm -rf "$HOME"
    export HOME="$ORIG_HOME"
  }
  Before 'setup'
  After 'cleanup'

  Describe 'list_installed_plugins()'
    It 'returns nothing when manifest is missing'
      When call list_installed_plugins
      The output should equal ''
      The status should be success
    End

    It 'extracts plugin names without @marketplace suffix'
      cat > "$HOME/.claude/plugins/installed_plugins.json" <<'JSON'
{"version":2,"plugins":{"claude-mem@thedotmack":[{}],"github@claude-plugins-official":[{}],"code-simplifier@claude-plugins-official":[{}]}}
JSON
      When call list_installed_plugins
      The output should include 'claude-mem'
      The output should include 'github'
      The output should include 'code-simplifier'
      The output should not include '@'
    End

    It 'deduplicates and sorts output'
      cat > "$HOME/.claude/plugins/installed_plugins.json" <<'JSON'
{"version":2,"plugins":{"zebra@a":[{}],"alpha@b":[{}]}}
JSON
      result=$(list_installed_plugins)
      When call echo "$result"
      The line 1 of output should equal 'alpha'
      The line 2 of output should equal 'zebra'
    End
  End

  Describe 'check_host_plugin_conflicts()'
    It 'bypasses when AI_SANDBOX_SKIP_PLUGIN_CHECK=1'
      export AI_SANDBOX_SKIP_PLUGIN_CHECK=1
      QUIET=0
      When call check_host_plugin_conflicts
      The status should be success
      The output should include 'Skipping'
    End

    It 'bypasses silently when AI_SANDBOX_SKIP_PLUGIN_CHECK=1 and QUIET=1'
      export AI_SANDBOX_SKIP_PLUGIN_CHECK=1
      QUIET=1
      When call check_host_plugin_conflicts
      The status should be success
      The output should eq ''
    End
  End

  Describe 'generate_volume_override()'
    It 'emits an empty volumes list when nothing matches'
      When call generate_volume_override "$HOME/override.yaml"
      The status should be success
      The contents of file "$HOME/override.yaml" should include 'services:'
      The contents of file "$HOME/override.yaml" should include 'ai-sandbox:'
      The contents of file "$HOME/override.yaml" should include 'volumes: []'
    End

    It 'mounts ~/.<plugin-name> dirs that exist on the host'
      cat > "$HOME/.claude/plugins/installed_plugins.json" <<'JSON'
{"version":2,"plugins":{"claude-mem@thedotmack":[{}],"github@claude-plugins-official":[{}]}}
JSON
      mkdir -p "$HOME/.claude-mem"
      # no ~/.github dir — should not be mounted
      When call generate_volume_override "$HOME/override.yaml"
      The status should be success
      The contents of file "$HOME/override.yaml" should include ".claude-mem:${HOME}/.claude-mem"
      The contents of file "$HOME/override.yaml" should not include '.github:'
    End

    It "expands env vars like HOME in user volume-maps entries"
      mkdir -p "$HOME/.config/ai-sandbox"
      cat > "$HOME/.config/ai-sandbox/volume-maps" <<'EOF'
# comment line should be ignored
$HOME/.extra-state

$HOME/.custom:/opt/custom
EOF
      When call generate_volume_override "$HOME/override.yaml"
      The status should be success
      The contents of file "$HOME/override.yaml" should include "${HOME}/.extra-state:${HOME}/.extra-state"
      The contents of file "$HOME/override.yaml" should include "${HOME}/.custom:/opt/custom"
      The contents of file "$HOME/override.yaml" should not include 'comment'
    End

    It 'omits the extra_hosts key entirely when CLI_ADD_HOST is unset (nounset-safe)'
      # Deliberately do not set CLI_ADD_HOST: exercises the same call shape
      # as every other test in this Describe block, which invoke
      # generate_volume_override() directly rather than through
      # parse_options() (src/options.sh) -- confirms the function tolerates
      # running under `set -u` without CLI_ADD_HOST ever being declared.
      When call generate_volume_override "$HOME/override.yaml"
      The status should be success
      The contents of file "$HOME/override.yaml" should not include 'extra_hosts'
    End

    It 'omits the extra_hosts key entirely when CLI_ADD_HOST is a declared-empty array'
      CLI_ADD_HOST=()
      When call generate_volume_override "$HOME/override.yaml"
      The status should be success
      The contents of file "$HOME/override.yaml" should not include 'extra_hosts'
    End

    It 'emits an extra_hosts entry for each CLI_ADD_HOST spec'
      CLI_ADD_HOST=("myhost:192.168.65.254" "other:10.1.2.3")
      When call generate_volume_override "$HOME/override.yaml"
      The status should be success
      The contents of file "$HOME/override.yaml" should include 'extra_hosts:'
      The contents of file "$HOME/override.yaml" should include '- myhost:192.168.65.254'
      The contents of file "$HOME/override.yaml" should include '- other:10.1.2.3'
    End
  End
End
