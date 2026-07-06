# shellcheck shell=bash
# shellcheck disable=SC2034,SC2155,SC2317,SC2329 # ShellSpec DSL invokes functions indirectly and checks variables via framework assertions
#                                         ^ 'docker()' doesn't think 'docker()' calls are called

Describe 'ai-sandbox.sh'
  Include "$PWD/bin/ai-sandbox.sh"

  Describe 'check_docker()'
    It 'succeeds and prints confirmed when docker is running'
      docker() { if [ "$1" = "info" ]; then return 0; fi; }
      When call check_docker
      The output should include 'confirmed.'
      The status should be success
    End

    It 'fails and prints message arg when docker is not running'
      docker() { if [ "$1" = "info" ]; then return 1; fi; }
      When call check_docker "starting..."
      The output should include 'starting...'
      The status should be failure
    End

    It 'fails and prints default message when docker is not running and no arg'
      docker() { if [ "$1" = "info" ]; then return 1; fi; }
      When call check_docker ""
      The output should include 'NOT running.'
      The status should be failure
    End
  End

  Describe 'download_tool()'
    setup() {
      export TOOL_CACHE_DIR="$(mktemp -d)"
    }
    cleanup() {
      rm -rf "$TOOL_CACHE_DIR"
    }
    Before 'setup'
    After 'cleanup'

    It 'downloads when file does not exist'
      curl() { touch "$6"; return 0; }
      When call download_tool "https://example.com/tool.tar.gz" "tool.tar.gz"
      The output should include 'Downloading tool.tar.gz'
      The status should be success
    End

    It 'skips when file already exists'
      touch "${TOOL_CACHE_DIR}/tool.tar.gz"
      When call download_tool "https://example.com/tool.tar.gz" "tool.tar.gz"
      The output should include 'already exists'
      The status should be success
    End
  End

  Describe 'profile_image_suffix()'
    It 'returns profile-<hash> when PROFILE_COMPOSITION_HASH is set'
      PROFILE_COMPOSITION_HASH=a1b2c3d4
      When call profile_image_suffix
      The output should eq 'profile-a1b2c3d4'
    End

    It 'returns profile-default when PROFILE_COMPOSITION_HASH is unset'
      unset PROFILE_COMPOSITION_HASH
      When call profile_image_suffix
      The output should eq 'profile-default'
    End

    It 'returns profile-default when PROFILE_COMPOSITION_HASH is empty'
      PROFILE_COMPOSITION_HASH=
      When call profile_image_suffix
      The output should eq 'profile-default'
    End
  End

  Describe 'variant_image_tag()'
    It 'returns ai-sandbox:profile-<hash> when PROFILE_COMPOSITION_HASH is set'
      PROFILE_COMPOSITION_HASH=a1b2c3d4
      When call variant_image_tag
      The output should eq 'ai-sandbox:profile-a1b2c3d4'
    End

    It 'returns ai-sandbox:profile-default when PROFILE_COMPOSITION_HASH is unset'
      unset PROFILE_COMPOSITION_HASH
      When call variant_image_tag
      The output should eq 'ai-sandbox:profile-default'
    End
  End

  Describe 'profile_has_capability()'
    It 'returns success when the capability is present'
      PROFILE_CAPABILITIES="docker chromium"
      When call profile_has_capability docker
      The status should be success
    End

    It 'returns failure when the capability is absent'
      PROFILE_CAPABILITIES="chromium"
      When call profile_has_capability docker
      The status should be failure
    End

    It 'matches whole tokens, not substrings'
      PROFILE_CAPABILITIES="dockerized"
      When call profile_has_capability docker
      The status should be failure
    End

    It 'returns failure when no capabilities are set'
      PROFILE_CAPABILITIES=""
      When call profile_has_capability docker
      The status should be failure
    End
  End

  Describe 'ensure_image()'
    setup() {
      export TOOL_CACHE_DIR="$(mktemp -d)"
      export AI_SANDBOX_IMAGE_TAG="ai-sandbox:profile-test"
      unset PROFILE_COMPOSITION_HASH
    }
    cleanup() {
      rm -rf "$TOOL_CACHE_DIR"
    }
    Before 'setup'
    After 'cleanup'

    It 'calls build when image not found'
      built=false
      docker() {
        case "$1" in
          image)
            # 'image inspect <tag>' → return failure (image missing)
            [ "$2" = "inspect" ] && return 1
            # 'image rm -f <tag>' → succeed silently
            [ "$2" = "rm" ] && return 0
            ;;
          compose)
            shift
            while [ "$1" = "-f" ]; do shift; shift; done
            [ "$1" = "build" ] && built=true
            ;;
        esac
      }
      COMPOSE_FILES="-f docker-compose.yaml"
      SSH_AUTH_SOCK="/tmp/ssh"
      When call ensure_image
      The output should include 'Image not found'
      The variable built should eq true
    End

    It 'does nothing when image exists and is fresh'
      docker() {
        case "$1" in
          image)
            [ "$2" = "inspect" ] && return 0
            ;;
        esac
      }
      is_build_stale() { return 1; }
      COMPOSE_FILES="-f docker-compose.yaml"
      When call ensure_image
      The output should eq ''
    End
  End

  Describe 'sandbox_container_name()'
    It 'returns ai-sandbox-<name> for the current SANDBOX_NAME'
      SANDBOX_NAME=mybox
      When call sandbox_container_name
      The output should eq 'ai-sandbox-mybox'
    End

    It 'returns ai-sandbox- when SANDBOX_NAME is empty'
      SANDBOX_NAME=
      When call sandbox_container_name
      The output should eq 'ai-sandbox-'
    End
  End

  Describe 'restore_saved_config()'
    # Helper: base64-encode a config-input JSON payload exactly as
    # src/index.sh's assembly block does, for use as the mocked
    # `ai.sandbox.config` label value below.
    encode_config() {
      printf '%s' "$1" | base64 | tr -d '\n'
    }

    It 'restores all seven config-input dimensions from a mocked ai.sandbox.config label (full round trip)'
      # Direct regression test for the design note's restore-side requirement:
      # a sandbox created with a full set of config-changing flags records the
      # complete input record in the single ai.sandbox.config label; a bare
      # `enter` must reconstruct every one of the seven dimensions from it.
      SANDBOX_NAME="test"
      CONFIG_FLAGS_PROVIDED=false
      PROFILES=()
      MODE_OVERRIDE=""
      NO_ISOLATE_CONFIG=false
      CLEAN_SLATE=false
      CLI_MARKETPLACES=()
      CLI_PLUGINS=()
      CLI_ENABLE_ALL=false
      config_b64="$(encode_config '{"version":1,"profiles":["base","docker"],"mode":"static","no_isolate_config":true,"clean_slate":true,"marketplaces":["https://registry.example.com/plugins"],"plugins":["claude-mem"],"enable_all_plugins":true}')"
      docker() {
        if [ "$1" = "inspect" ]; then
          if [[ "$*" == *"ai.sandbox.config"* ]]; then
            echo "${config_b64}"
          fi
          return 0
        fi
      }
      When call restore_saved_config
      The variable "PROFILES[*]" should eq 'base docker'
      The variable MODE_OVERRIDE should eq static
      The variable NO_ISOLATE_CONFIG should eq true
      The variable CLEAN_SLATE should eq true
      The variable "CLI_MARKETPLACES[*]" should eq 'https://registry.example.com/plugins'
      The variable "CLI_PLUGINS[*]" should eq 'claude-mem'
      The variable CLI_ENABLE_ALL should eq true
    End

    It 'restores NO_ISOLATE_CONFIG=true specifically (regression: previously silently dropped, causing a false-positive recreate prompt)'
      SANDBOX_NAME="test"
      CONFIG_FLAGS_PROVIDED=false
      PROFILES=()
      MODE_OVERRIDE=""
      NO_ISOLATE_CONFIG=false
      CLEAN_SLATE=false
      CLI_MARKETPLACES=()
      CLI_PLUGINS=()
      CLI_ENABLE_ALL=false
      config_b64="$(encode_config '{"version":1,"profiles":[],"mode":"","no_isolate_config":true,"clean_slate":false,"marketplaces":[],"plugins":[],"enable_all_plugins":false}')"
      docker() {
        if [ "$1" = "inspect" ]; then
          if [[ "$*" == *"ai.sandbox.config"* ]]; then
            echo "${config_b64}"
          fi
          return 0
        fi
      }
      When call restore_saved_config
      The variable NO_ISOLATE_CONFIG should eq true
      The variable CLEAN_SLATE should eq false
    End

    It 'restores CLI_MARKETPLACES, CLI_PLUGINS, and CLI_ENABLE_ALL (regression: followup AL7i -- previously silently dropped)'
      SANDBOX_NAME="test"
      CONFIG_FLAGS_PROVIDED=false
      PROFILES=()
      MODE_OVERRIDE=""
      NO_ISOLATE_CONFIG=false
      CLEAN_SLATE=false
      CLI_MARKETPLACES=()
      CLI_PLUGINS=()
      CLI_ENABLE_ALL=false
      config_b64="$(encode_config '{"version":1,"profiles":[],"mode":"","no_isolate_config":false,"clean_slate":false,"marketplaces":["https://registry.example.com/plugins","file:///opt/local-marketplace"],"plugins":["claude-mem","other-plugin"],"enable_all_plugins":true}')"
      docker() {
        if [ "$1" = "inspect" ]; then
          if [[ "$*" == *"ai.sandbox.config"* ]]; then
            echo "${config_b64}"
          fi
          return 0
        fi
      }
      When call restore_saved_config
      The variable "CLI_MARKETPLACES[*]" should eq 'https://registry.example.com/plugins file:///opt/local-marketplace'
      The variable "CLI_PLUGINS[*]" should eq 'claude-mem other-plugin'
      The variable CLI_ENABLE_ALL should eq true
    End

    It 'exits cleanly and leaves defaults untouched when the ai.sandbox.config label is absent/empty'
      # No fallback is implemented (explicit product decision, design note Sec
      # 2.5/2.6): a container missing the label -- including any created
      # before this change -- simply restores nothing. This is a lighter
      # assertion than a fallback-restore test, since no fallback exists.
      SANDBOX_NAME="test"
      CONFIG_FLAGS_PROVIDED=false
      PROFILES=(sentinel)
      MODE_OVERRIDE="sentinel-mode"
      NO_ISOLATE_CONFIG=sentinel-no-isolate
      CLEAN_SLATE=sentinel-clean
      CLI_MARKETPLACES=(sentinel-marketplace)
      CLI_PLUGINS=(sentinel-plugin)
      CLI_ENABLE_ALL=sentinel-enable-all
      docker() {
        # ai.sandbox.config label absent -- docker inspect prints an empty line.
        if [ "$1" = "inspect" ]; then return 0; fi
      }
      When call restore_saved_config
      The status should be success
      The variable "PROFILES[*]" should eq 'sentinel'
      The variable MODE_OVERRIDE should eq sentinel-mode
      The variable NO_ISOLATE_CONFIG should eq sentinel-no-isolate
      The variable CLEAN_SLATE should eq sentinel-clean
      The variable "CLI_MARKETPLACES[*]" should eq 'sentinel-marketplace'
      The variable "CLI_PLUGINS[*]" should eq 'sentinel-plugin'
      The variable CLI_ENABLE_ALL should eq sentinel-enable-all
    End

    It 'does not restore anything when CONFIG_FLAGS_PROVIDED=true (explicit flags this run always win)'
      SANDBOX_NAME="test"
      CONFIG_FLAGS_PROVIDED=true
      PROFILES=(sentinel)
      MODE_OVERRIDE="sentinel-mode"
      NO_ISOLATE_CONFIG=sentinel-no-isolate
      CLEAN_SLATE=sentinel-clean
      CLI_MARKETPLACES=(sentinel-marketplace)
      CLI_PLUGINS=(sentinel-plugin)
      CLI_ENABLE_ALL=sentinel-enable-all
      called=false
      docker() { called=true; }
      When call restore_saved_config
      The variable "PROFILES[*]" should eq 'sentinel'
      The variable MODE_OVERRIDE should eq sentinel-mode
      The variable NO_ISOLATE_CONFIG should eq sentinel-no-isolate
      The variable CLEAN_SLATE should eq sentinel-clean
      The variable "CLI_MARKETPLACES[*]" should eq 'sentinel-marketplace'
      The variable "CLI_PLUGINS[*]" should eq 'sentinel-plugin'
      The variable CLI_ENABLE_ALL should eq sentinel-enable-all
      The variable called should eq false
    End

    It 'does not restore anything when no container exists'
      SANDBOX_NAME="test"
      CONFIG_FLAGS_PROVIDED=false
      PROFILES=(sentinel)
      MODE_OVERRIDE="sentinel-mode"
      CLEAN_SLATE=sentinel-clean
      docker() {
        if [ "$1" = "inspect" ]; then return 1; fi
      }
      When call restore_saved_config
      The variable "PROFILES[*]" should eq 'sentinel'
      The variable MODE_OVERRIDE should eq sentinel-mode
      The variable CLEAN_SLATE should eq sentinel-clean
    End
  End

  Describe 'running_config_matches()'
    It 'returns 2 when no container is running'
      SANDBOX_NAME="test"
      docker() {
        if [ "$1" = "inspect" ]; then return 1; fi
      }
      When call running_config_matches
      The status should eq 2
    End

    It 'returns success when every compared field matches (regression: false-positive recreate prompt fixed)'
      # Second symptom's regression case: the sandbox was created with
      # `--clean --mode static`, recording ai.sandbox.mode=static and
      # ai.sandbox.clean-slate=true. EFFECTIVE_MODE=static and
      # AI_SANDBOX_CLEAN_SLATE=true are what restore_saved_config() + the
      # unchanged EFFECTIVE_MODE computation now produce after the fix, so no
      # recreate-confirmation prompt should fire.
      SANDBOX_NAME="test"
      AI_SANDBOX_IMAGE_TAG="ai-sandbox:profile-abc"
      PROFILE_COMPOSITION_HASH="abc"
      EFFECTIVE_MODE=static
      NO_ISOLATE_CONFIG=false
      EFFECTIVE_PROXY=false
      AI_SANDBOX_CLEAN_SLATE=true
      docker() {
        if [ "$1" = "inspect" ]; then
          if [[ "$*" == *".State.Status"* ]]; then
            echo "running"
          elif [[ "$*" == *".Config.Image"* ]]; then
            echo "ai-sandbox:profile-abc"
          elif [[ "$*" == *"profile-hash"* ]]; then
            echo "abc"
          elif [[ "$*" == *"ai.sandbox.mode"* ]]; then
            echo "static"
          elif [[ "$*" == *"no-isolate-config"* ]]; then
            echo "false"
          elif [[ "$*" == *"docker-proxy"* ]]; then
            echo "false"
          elif [[ "$*" == *"clean-slate"* ]]; then
            echo "true"
          fi
          return 0
        fi
      }
      When call running_config_matches
      The status should eq 0
    End

    It 'returns failure when the mode label disagrees with EFFECTIVE_MODE (the pre-fix bug symptom)'
      # Characterizes exactly why the restore fix in this task matters: before
      # the fix, a bare `enter` recomputed EFFECTIVE_MODE=mirror (because
      # MODE_OVERRIDE was never restored) while the container's recorded label
      # was ai.sandbox.mode=static, producing this mismatch and the
      # false-positive recreate-confirmation prompt. running_config_matches()
      # itself is unchanged by this task -- only its inputs are fixed upstream.
      SANDBOX_NAME="test"
      AI_SANDBOX_IMAGE_TAG="ai-sandbox:profile-abc"
      PROFILE_COMPOSITION_HASH="abc"
      EFFECTIVE_MODE=mirror
      NO_ISOLATE_CONFIG=false
      EFFECTIVE_PROXY=false
      AI_SANDBOX_CLEAN_SLATE=false
      docker() {
        if [ "$1" = "inspect" ]; then
          if [[ "$*" == *".State.Status"* ]]; then
            echo "running"
          elif [[ "$*" == *".Config.Image"* ]]; then
            echo "ai-sandbox:profile-abc"
          elif [[ "$*" == *"profile-hash"* ]]; then
            echo "abc"
          elif [[ "$*" == *"ai.sandbox.mode"* ]]; then
            echo "static"
          elif [[ "$*" == *"no-isolate-config"* ]]; then
            echo "false"
          elif [[ "$*" == *"docker-proxy"* ]]; then
            echo "false"
          elif [[ "$*" == *"clean-slate"* ]]; then
            echo "false"
          fi
          return 0
        fi
      }
      When call running_config_matches
      The status should eq 1
    End

    It 'returns success when marketplaces/plugins/enable-all-plugins labels match the current effective values'
      SANDBOX_NAME="test"
      AI_SANDBOX_IMAGE_TAG="ai-sandbox:profile-abc"
      PROFILE_COMPOSITION_HASH="abc"
      EFFECTIVE_MODE=mirror
      NO_ISOLATE_CONFIG=false
      EFFECTIVE_PROXY=false
      AI_SANDBOX_CLEAN_SLATE=false
      AI_SANDBOX_MARKETPLACES="https://example.com/registry"
      AI_SANDBOX_PLUGINS="claude-mem"
      AI_SANDBOX_ENABLE_ALL_PLUGINS=true
      docker() {
        if [ "$1" = "inspect" ]; then
          if [[ "$*" == *".State.Status"* ]]; then
            echo "running"
          elif [[ "$*" == *".Config.Image"* ]]; then
            echo "ai-sandbox:profile-abc"
          elif [[ "$*" == *"profile-hash"* ]]; then
            echo "abc"
          elif [[ "$*" == *"ai.sandbox.mode"* ]]; then
            echo "mirror"
          elif [[ "$*" == *"no-isolate-config"* ]]; then
            echo "false"
          elif [[ "$*" == *"docker-proxy"* ]]; then
            echo "false"
          elif [[ "$*" == *"clean-slate"* ]]; then
            echo "false"
          elif [[ "$*" == *"ai.sandbox.marketplaces"* ]]; then
            echo "https://example.com/registry"
          elif [[ "$*" == *"ai.sandbox.plugins"* ]]; then
            echo "claude-mem"
          elif [[ "$*" == *"enable-all-plugins"* ]]; then
            echo "true"
          fi
          return 0
        fi
      }
      When call running_config_matches
      The status should eq 0
    End

    It 'returns failure when the marketplaces label disagrees with AI_SANDBOX_MARKETPLACES'
      SANDBOX_NAME="test"
      AI_SANDBOX_IMAGE_TAG="ai-sandbox:profile-abc"
      PROFILE_COMPOSITION_HASH="abc"
      EFFECTIVE_MODE=mirror
      NO_ISOLATE_CONFIG=false
      EFFECTIVE_PROXY=false
      AI_SANDBOX_CLEAN_SLATE=false
      AI_SANDBOX_MARKETPLACES="https://example.com/new-registry"
      AI_SANDBOX_PLUGINS=""
      AI_SANDBOX_ENABLE_ALL_PLUGINS=false
      docker() {
        if [ "$1" = "inspect" ]; then
          if [[ "$*" == *".State.Status"* ]]; then
            echo "running"
          elif [[ "$*" == *".Config.Image"* ]]; then
            echo "ai-sandbox:profile-abc"
          elif [[ "$*" == *"profile-hash"* ]]; then
            echo "abc"
          elif [[ "$*" == *"ai.sandbox.mode"* ]]; then
            echo "mirror"
          elif [[ "$*" == *"no-isolate-config"* ]]; then
            echo "false"
          elif [[ "$*" == *"docker-proxy"* ]]; then
            echo "false"
          elif [[ "$*" == *"clean-slate"* ]]; then
            echo "false"
          elif [[ "$*" == *"ai.sandbox.marketplaces"* ]]; then
            echo ""
          elif [[ "$*" == *"ai.sandbox.plugins"* ]]; then
            echo ""
          elif [[ "$*" == *"enable-all-plugins"* ]]; then
            echo "false"
          fi
          return 0
        fi
      }
      When call running_config_matches
      The status should eq 1
    End

    It 'returns failure when the plugins label disagrees with AI_SANDBOX_PLUGINS'
      SANDBOX_NAME="test"
      AI_SANDBOX_IMAGE_TAG="ai-sandbox:profile-abc"
      PROFILE_COMPOSITION_HASH="abc"
      EFFECTIVE_MODE=mirror
      NO_ISOLATE_CONFIG=false
      EFFECTIVE_PROXY=false
      AI_SANDBOX_CLEAN_SLATE=false
      AI_SANDBOX_MARKETPLACES=""
      AI_SANDBOX_PLUGINS="claude-mem"
      AI_SANDBOX_ENABLE_ALL_PLUGINS=false
      docker() {
        if [ "$1" = "inspect" ]; then
          if [[ "$*" == *".State.Status"* ]]; then
            echo "running"
          elif [[ "$*" == *".Config.Image"* ]]; then
            echo "ai-sandbox:profile-abc"
          elif [[ "$*" == *"profile-hash"* ]]; then
            echo "abc"
          elif [[ "$*" == *"ai.sandbox.mode"* ]]; then
            echo "mirror"
          elif [[ "$*" == *"no-isolate-config"* ]]; then
            echo "false"
          elif [[ "$*" == *"docker-proxy"* ]]; then
            echo "false"
          elif [[ "$*" == *"clean-slate"* ]]; then
            echo "false"
          elif [[ "$*" == *"ai.sandbox.marketplaces"* ]]; then
            echo ""
          elif [[ "$*" == *"ai.sandbox.plugins"* ]]; then
            echo ""
          elif [[ "$*" == *"enable-all-plugins"* ]]; then
            echo "false"
          fi
          return 0
        fi
      }
      When call running_config_matches
      The status should eq 1
    End

    It 'returns failure when the enable-all-plugins label disagrees with AI_SANDBOX_ENABLE_ALL_PLUGINS'
      SANDBOX_NAME="test"
      AI_SANDBOX_IMAGE_TAG="ai-sandbox:profile-abc"
      PROFILE_COMPOSITION_HASH="abc"
      EFFECTIVE_MODE=mirror
      NO_ISOLATE_CONFIG=false
      EFFECTIVE_PROXY=false
      AI_SANDBOX_CLEAN_SLATE=false
      AI_SANDBOX_MARKETPLACES=""
      AI_SANDBOX_PLUGINS=""
      AI_SANDBOX_ENABLE_ALL_PLUGINS=true
      docker() {
        if [ "$1" = "inspect" ]; then
          if [[ "$*" == *".State.Status"* ]]; then
            echo "running"
          elif [[ "$*" == *".Config.Image"* ]]; then
            echo "ai-sandbox:profile-abc"
          elif [[ "$*" == *"profile-hash"* ]]; then
            echo "abc"
          elif [[ "$*" == *"ai.sandbox.mode"* ]]; then
            echo "mirror"
          elif [[ "$*" == *"no-isolate-config"* ]]; then
            echo "false"
          elif [[ "$*" == *"docker-proxy"* ]]; then
            echo "false"
          elif [[ "$*" == *"clean-slate"* ]]; then
            echo "false"
          elif [[ "$*" == *"ai.sandbox.marketplaces"* ]]; then
            echo ""
          elif [[ "$*" == *"ai.sandbox.plugins"* ]]; then
            echo ""
          elif [[ "$*" == *"enable-all-plugins"* ]]; then
            echo "false"
          fi
          return 0
        fi
      }
      When call running_config_matches
      The status should eq 1
    End

    It 'returns success for a legacy container missing the marketplaces/plugins/enable-all-plugins labels when the current invocation is also empty/default (no false-positive recreate)'
      SANDBOX_NAME="test"
      AI_SANDBOX_IMAGE_TAG="ai-sandbox:profile-abc"
      PROFILE_COMPOSITION_HASH="abc"
      EFFECTIVE_MODE=mirror
      NO_ISOLATE_CONFIG=false
      EFFECTIVE_PROXY=false
      AI_SANDBOX_CLEAN_SLATE=false
      AI_SANDBOX_MARKETPLACES=""
      AI_SANDBOX_PLUGINS=""
      AI_SANDBOX_ENABLE_ALL_PLUGINS=false
      docker() {
        if [ "$1" = "inspect" ]; then
          if [[ "$*" == *".State.Status"* ]]; then
            echo "running"
          elif [[ "$*" == *".Config.Image"* ]]; then
            echo "ai-sandbox:profile-abc"
          elif [[ "$*" == *"profile-hash"* ]]; then
            echo "abc"
          elif [[ "$*" == *"ai.sandbox.mode"* ]]; then
            echo "mirror"
          elif [[ "$*" == *"no-isolate-config"* ]]; then
            echo "false"
          elif [[ "$*" == *"docker-proxy"* ]]; then
            echo "false"
          elif [[ "$*" == *"clean-slate"* ]]; then
            echo "false"
          fi
          # No branches for marketplaces/plugins/enable-all-plugins labels:
          # simulates a container created before these labels existed, where
          # `docker inspect` prints an empty string for the missing key.
          return 0
        fi
      }
      When call running_config_matches
      The status should eq 0
    End
  End

  Describe 'parse_options()'
    It 'defaults CMD to list on bare invocation'
      When call parse_options
      The variable CMD should eq list
      The variable SANDBOX_NAME should eq ''
    End

    It 'routes list to CMD with empty SANDBOX_NAME'
      When call parse_options list
      The variable CMD should eq list
      The variable SANDBOX_NAME should eq ''
    End

    It 'routes first arg to SANDBOX_NAME when not a global command'
      When call parse_options mybox stop
      The variable SANDBOX_NAME should eq mybox
      The variable CMD should eq stop
    End

    It 'sets CMD to enter when sandbox name given with no command'
      When call parse_options mybox
      The variable SANDBOX_NAME should eq mybox
      The variable CMD should eq enter
    End

    It 'routes create to CMD with sandbox name in SANDBOX_NAME'
      When call parse_options create mybox --profile base
      The variable CMD should eq create
      The variable SANDBOX_NAME should eq mybox
      The variable "PROFILES[*]" should eq base
    End

    It 'accumulates repeated --profile flags in order'
      When call parse_options create mybox --profile base --profile docker
      The variable "PROFILES[*]" should eq 'base docker'
      The variable CONFIG_FLAGS_PROVIDED should eq true
    End

    It 'sets ENTER_AFTER_CREATE from --enter on create'
      When call parse_options create mybox --enter
      The variable ENTER_AFTER_CREATE should eq true
    End

    It 'sets MODE_OVERRIDE from --mode'
      When call parse_options create mybox --mode static
      The variable MODE_OVERRIDE should eq static
      The variable CONFIG_FLAGS_PROVIDED should eq true
    End

    It 'rejects an invalid --mode value'
      When run parse_options create mybox --mode bogus
      The status should be failure
      The stderr should include "must be 'mirror' or 'static'"
    End

    It 'routes a bare per-instance command to CMD with empty SANDBOX_NAME'
      When call parse_options clean
      The variable CMD should eq clean
      The variable SANDBOX_NAME should eq ''
    End

    It 'routes status as a per-instance command on the default sandbox'
      When call parse_options status
      The variable CMD should eq status
      The variable SANDBOX_NAME should eq ''
    End

    It 'still routes <name> <cmd> correctly for per-instance commands'
      When call parse_options mybox clean
      The variable SANDBOX_NAME should eq mybox
      The variable CMD should eq clean
    End

    It 'defaults CMD to enter when sandbox name is followed by flags with no command word'
      When call parse_options mybox --add-marketplace file:///two --enable-plugin flow --clean
      The variable SANDBOX_NAME should eq mybox
      The variable CMD should eq enter
      The variable "CLI_MARKETPLACES[*]" should eq 'file:///two'
      The variable "CLI_PLUGINS[*]" should eq flow
      The variable CLEAN_SLATE should eq true
    End


    It 'errors and points to --profile docker when --docker is passed'
      When run parse_options create mybox --docker
      The status should be failure
      The stderr should include '--profile docker'
    End

    It 'errors and points to --profile docker when --no-docker is passed'
      When run parse_options create mybox --no-docker
      The status should be failure
      The stderr should include '--profile docker'
    End

    It 'errors and points to --profile chromium when --no-chromium is passed'
      When run parse_options create mybox --no-chromium
      The status should be failure
      The stderr should include '--profile chromium'
    End

    It 'leaves NO_ISOLATE_CONFIG false by default (isolation on)'
      When call parse_options
      The variable NO_ISOLATE_CONFIG should eq false
    End

    It 'sets NO_ISOLATE_CONFIG when --no-isolate-config is passed'
      When call parse_options create mybox --no-isolate-config
      The variable NO_ISOLATE_CONFIG should eq true
    End

    It 'accepts --add-marketplace with https:// ref'
      When call parse_options create mybox --add-marketplace https://registry.example.com
      The variable "CLI_MARKETPLACES[*]" should eq 'https://registry.example.com'
      The variable CONFIG_FLAGS_PROVIDED should eq true
    End

    It 'accepts --add-marketplace with file:// ref'
      When call parse_options create mybox --add-marketplace file:///home/user/plugin
      The variable "CLI_MARKETPLACES[*]" should eq 'file:///home/user/plugin'
    End

    It 'rejects --add-marketplace with invalid scheme'
      When run parse_options create mybox --add-marketplace ftp://bad.example.com
      The status should be failure
      The stderr should include 'https:// or file://'
    End

    It 'errors when --add-marketplace is given no ref'
      When run parse_options create mybox --add-marketplace
      The status should be failure
      The stderr should include '--add-marketplace requires'
    End

    It 'accumulates repeated --add-marketplace refs in order'
      When call parse_options create mybox \
        --add-marketplace https://one.example.com \
        --add-marketplace file:///two
      The variable "CLI_MARKETPLACES[*]" should eq 'https://one.example.com file:///two'
    End

    It 'accepts --enable-plugin and sets CLI_PLUGINS'
      When call parse_options create mybox --enable-plugin flow
      The variable "CLI_PLUGINS[*]" should eq flow
      The variable CONFIG_FLAGS_PROVIDED should eq true
    End

    It 'accumulates repeated --enable-plugin names'
      When call parse_options create mybox --enable-plugin flow --enable-plugin claude-mem
      The variable "CLI_PLUGINS[*]" should eq 'flow claude-mem'
    End

    It 'sets CLI_ENABLE_ALL from --enable-all'
      When call parse_options create mybox --enable-all
      The variable CLI_ENABLE_ALL should eq true
      The variable CONFIG_FLAGS_PROVIDED should eq true
    End

    It 'errors when --enable-plugin is given no name'
      When run parse_options create mybox --enable-plugin
      The status should be failure
      The stderr should include '--enable-plugin requires'
    End

    It 'CLI_ENABLE_ALL defaults to false when --enable-all is absent'
      When call parse_options create mybox
      The variable CLI_ENABLE_ALL should eq false
    End

    It '--clean sets CLEAN_SLATE to true'
      When call parse_options create mybox --clean
      The variable CLEAN_SLATE should eq true
    End

    It '--clean sets CONFIG_FLAGS_PROVIDED to true'
      When call parse_options create mybox --clean
      The variable CONFIG_FLAGS_PROVIDED should eq true
    End

    It 'CLEAN_SLATE defaults to false when --clean is absent'
      When call parse_options create mybox
      The variable CLEAN_SLATE should eq false
    End

    It '--clean can be combined with --add-marketplace and --enable-all'
      When call parse_options create mybox --clean \
        --add-marketplace file:///path/to/mp --enable-all
      The variable CLEAN_SLATE should eq true
      The variable "CLI_MARKETPLACES[*]" should eq 'file:///path/to/mp'
      The variable CLI_ENABLE_ALL should eq true
    End

    It 'rejects an invalid sandbox name given via the bare per-instance form'
      When run parse_options flow.rook
      The status should be failure
      The stderr should include 'invalid'
      The stderr should include "flow.rook"
    End

    It 'rejects an invalid sandbox name given via the create form'
      When run parse_options create flow.rook
      The status should be failure
      The stderr should include 'invalid'
    End

    It 'rejects an uppercase sandbox name'
      When run parse_options FlowRook
      The status should be failure
      The stderr should include 'invalid'
    End

    It 'accepts a valid sandbox name with hyphens, underscores, and digits'
      When call parse_options flow-rook_2
      The variable SANDBOX_NAME should eq 'flow-rook_2'
      The variable CMD should eq enter
    End
  End

  Describe 'generate_volume_override() clean-slate mode' unit
    setup() {
      export TMPDIR_VO="$(mktemp -d)"
      export HOME="${TMPDIR_VO}"
      export OUT="${TMPDIR_VO}/compose-override.yaml"
      unset AI_SANDBOX_MARKETPLACES
      unset AI_SANDBOX_CLEAN_SLATE
    }
    cleanup() {
      rm -rf "${TMPDIR_VO}"
    }
    Before 'setup'
    After 'cleanup'

    It 'skips plugin dir mounts when AI_SANDBOX_CLEAN_SLATE=true'
      mkdir -p "${HOME}/.myplugin"
      mkdir -p "${HOME}/.claude/plugins"
      printf '{"plugins":{"myplugin@test":{}}}' \
        > "${HOME}/.claude/plugins/installed_plugins.json"
      export AI_SANDBOX_CLEAN_SLATE=true
      When call generate_volume_override "${OUT}"
      The contents of file "${OUT}" should not include '.myplugin'
      The status should be success
    End

    It 'still mounts file:// marketplace paths when AI_SANDBOX_CLEAN_SLATE=true'
      export AI_SANDBOX_CLEAN_SLATE=true
      export AI_SANDBOX_MARKETPLACES="file:///srv/marketplace"
      When call generate_volume_override "${OUT}"
      The contents of file "${OUT}" should include '/srv/marketplace:/srv/marketplace:ro'
      The status should be success
    End

    It 'mounts plugin dirs when AI_SANDBOX_CLEAN_SLATE is false (default behavior)'
      mkdir -p "${HOME}/.myplugin"
      mkdir -p "${HOME}/.claude/plugins"
      printf '{"plugins":{"myplugin@test":{}}}' \
        > "${HOME}/.claude/plugins/installed_plugins.json"
      export AI_SANDBOX_CLEAN_SLATE=false
      When call generate_volume_override "${OUT}"
      The contents of file "${OUT}" should include '.myplugin'
      The status should be success
    End

    It 'produces empty volumes list when clean and no marketplaces'
      export AI_SANDBOX_CLEAN_SLATE=true
      When call generate_volume_override "${OUT}"
      The contents of file "${OUT}" should include 'volumes: []'
      The status should be success
    End
  End

  Describe 'generate_volume_override() file:// marketplace mounts' unit
    setup() {
      export TMPDIR_MP="$(mktemp -d)"
      export HOME="${TMPDIR_MP}"
      export OUT="${TMPDIR_MP}/compose-override.yaml"
      unset AI_SANDBOX_CLEAN_SLATE
    }
    cleanup() {
      rm -rf "${TMPDIR_MP}"
    }
    Before 'setup'
    After 'cleanup'

    It 'adds a read-only bind mount for a file:// marketplace entry'
      export AI_SANDBOX_MARKETPLACES="file:///srv/my-marketplace"
      When call generate_volume_override "${OUT}"
      The contents of file "${OUT}" should include '/srv/my-marketplace:/srv/my-marketplace:ro'
      The status should be success
    End

    It 'does not add a mount for https:// marketplace entries'
      export AI_SANDBOX_MARKETPLACES="https://registry.example.com"
      When call generate_volume_override "${OUT}"
      The contents of file "${OUT}" should not include 'registry.example.com'
      The status should be success
    End

    It 'handles multiple entries when pipe-separated'
      export AI_SANDBOX_MARKETPLACES="file:///srv/mp1|https://remote.example.com|file:///srv/mp2"
      When call generate_volume_override "${OUT}"
      The contents of file "${OUT}" should include '/srv/mp1:/srv/mp1:ro'
      The contents of file "${OUT}" should include '/srv/mp2:/srv/mp2:ro'
      The contents of file "${OUT}" should not include 'remote.example.com'
      The status should be success
    End

    It 'mounts the parent directory when marketplace path is a .json file at the project root'
      mkdir -p "${HOME}/project"
      touch "${HOME}/project/marketplace.json"
      export AI_SANDBOX_MARKETPLACES="file://${HOME}/project/marketplace.json"
      When call generate_volume_override "${OUT}"
      The contents of file "${OUT}" should include "${HOME}/project:${HOME}/project:ro"
      The contents of file "${OUT}" should not include 'marketplace.json'
      The status should be success
    End

    It 'mounts the project root when marketplace.json is inside .claude-plugin/'
      mkdir -p "${HOME}/project/.claude-plugin"
      touch "${HOME}/project/.claude-plugin/marketplace.json"
      export AI_SANDBOX_MARKETPLACES="file://${HOME}/project/.claude-plugin/marketplace.json"
      When call generate_volume_override "${OUT}"
      The contents of file "${OUT}" should include "${HOME}/project:${HOME}/project:ro"
      The contents of file "${OUT}" should not include '.claude-plugin'
      The status should be success
    End

    It 'mounts the directory as-is when marketplace path is not a file'
      export AI_SANDBOX_MARKETPLACES="file:///srv/my-dir-marketplace"
      When call generate_volume_override "${OUT}"
      The contents of file "${OUT}" should include '/srv/my-dir-marketplace:/srv/my-dir-marketplace:ro'
      The status should be success
    End
  End

  Describe 'is_build_stale()'
    setup() {
      export PROJECT_ROOT="$(mktemp -d)"
      mkdir -p "${PROJECT_ROOT}/docker"
      export AI_SANDBOX_IMAGE_TAG="ai-sandbox:profile-test"
      unset PROFILE_COMPOSITION_HASH
      unset PROFILE_INPUT_FILES
      unset PROFILE_ASSEMBLED_DOCKERFILE
    }
    cleanup() {
      rm -rf "$PROJECT_ROOT"
    }
    Before 'setup'
    After 'cleanup'

    It 'returns stale when image does not exist'
      docker() {
        case "$1 $2" in
          "image inspect") return 1 ;;
        esac
      }
      When call is_build_stale
      The status should be success
    End

    It 'returns fresh when image is newer than all docker/ files'
      # Create an old source file, then claim the image was built "now".
      touch -t 202001010000 "${PROJECT_ROOT}/docker/Dockerfile"
      # RFC3339 timestamp well in the future of the source file.
      docker() {
        case "$1 $2" in
          "image inspect") echo "2099-01-01T00:00:00Z" ;;
        esac
      }
      When call is_build_stale
      The status should be failure
    End

    It 'returns stale when a docker/ file is newer than the image'
      touch "${PROJECT_ROOT}/docker/Dockerfile"
      # Image "created" back in 2000 → source file is newer.
      docker() {
        case "$1 $2" in
          "image inspect") echo "2000-01-01T00:00:00Z" ;;
        esac
      }
      When call is_build_stale
      The status should be success
    End

    It 'returns stale when profile hash in image label differs from current'
      touch -t 202001010000 "${PROJECT_ROOT}/docker/Dockerfile"
      PROFILE_COMPOSITION_HASH=newHash8
      docker() {
        case "$1 $2" in
          "image inspect")
            # First call: .Created timestamp; second call: label value.
            # Both cases are caught by "image inspect" — the label call returns
            # a different (stale) hash to trigger the staleness check.
            if [[ "$*" == *"profile-hash"* ]]; then
              echo "oldHash8"
            else
              echo "2099-01-01T00:00:00Z"
            fi
            ;;
        esac
      }
      When call is_build_stale
      The status should be success
    End

    It 'returns fresh when profile hash matches and no files changed'
      touch -t 202001010000 "${PROJECT_ROOT}/docker/Dockerfile"
      PROFILE_COMPOSITION_HASH=a1b2c3d4
      docker() {
        case "$1 $2" in
          "image inspect")
            if [[ "$*" == *"profile-hash"* ]]; then
              echo "a1b2c3d4"
            else
              echo "2099-01-01T00:00:00Z"
            fi
            ;;
        esac
      }
      When call is_build_stale
      The status should be failure
    End

    It 'returns stale when a PROFILE_INPUT_FILES entry is newer than the image'
      input_file="${PROJECT_ROOT}/profile-input.yaml"
      touch "${input_file}"
      PROFILE_INPUT_FILES="${input_file}"
      docker() {
        case "$1 $2" in
          "image inspect") echo "2000-01-01T00:00:00Z" ;;
        esac
      }
      When call is_build_stale
      The status should be success
    End
  End

  Describe '_ssh_mount_is_fresh()'
    setup() { SANDBOX_NAME="test"; export SSH_AUTH_SOCK="/tmp/agent.sock"; }
    Before 'setup'

    It 'returns 0 when the label matches the current SSH_AUTH_SOCK'
      docker() {
        if [ "$1" = "inspect" ]; then echo "/tmp/agent.sock"; return 0; fi
      }
      When call _ssh_mount_is_fresh
      The status should eq 0
    End

    It 'returns 1 when the label disagrees with SSH_AUTH_SOCK'
      export SSH_AUTH_SOCK="/tmp/new.sock"
      docker() {
        if [ "$1" = "inspect" ]; then echo "/tmp/old.sock"; return 0; fi
      }
      When call _ssh_mount_is_fresh
      The status should eq 1
    End

    It 'returns 2 when docker inspect fails (no container)'
      docker() {
        if [ "$1" = "inspect" ]; then return 1; fi
      }
      When call _ssh_mount_is_fresh
      The status should eq 2
    End

    It 'returns 2 when the label is empty'
      docker() {
        if [ "$1" = "inspect" ]; then echo ""; return 0; fi
      }
      When call _ssh_mount_is_fresh
      The status should eq 2
    End
  End

  Describe 'warn_if_ssh_mount_stale()'
    setup() { SANDBOX_NAME="test"; }
    Before 'setup'

    It 'warns to stderr when the mount is stale'
      export SSH_AUTH_SOCK="/tmp/new.sock"
      docker() {
        if [ "$1" = "inspect" ]; then echo "/tmp/old.sock"; return 0; fi
      }
      When call warn_if_ssh_mount_stale
      The stderr should include 'SSH_AUTH_SOCK has changed'
      The stderr should include 'fix-ssh'
      The status should be success
    End

    It 'is silent when the mount is fresh'
      export SSH_AUTH_SOCK="/tmp/agent.sock"
      docker() {
        if [ "$1" = "inspect" ]; then echo "/tmp/agent.sock"; return 0; fi
      }
      When call warn_if_ssh_mount_stale
      The output should eq ''
      The stderr should eq ''
    End

    It 'is silent when no container exists'
      export SSH_AUTH_SOCK="/tmp/agent.sock"
      docker() {
        if [ "$1" = "inspect" ]; then return 1; fi
      }
      When call warn_if_ssh_mount_stale
      The output should eq ''
      The stderr should eq ''
    End
  End

  Describe 'new_profile()'
    setup() {
      export TMPDIR_CP="$(mktemp -d)"
      export HOME="${TMPDIR_CP}"
    }
    cleanup() {
      rm -rf "${TMPDIR_CP}"
    }
    Before 'setup'
    After 'cleanup'

    It 'writes the profile file and prints success'
      output_file="${TMPDIR_CP}/test-profile.yaml"
      When call new_profile --name t --output "${output_file}"
      The output should include 'Created profile:'
      The path "${output_file}" should be exist
      The status should be success
    End

    It 'errors when --name is missing'
      When run new_profile --output /tmp/nope.yaml
      The status should be failure
      The stderr should include '--name is required'
    End

    It 'errors when --name contains a path separator'
      When run new_profile --name bad/name --output /tmp/nope.yaml
      The status should be failure
      The stderr should include '/'
    End
  End

  Describe 'cleanup_stale_container()'
    It 'returns 0 when no container exists'
      SANDBOX_NAME="test"
      docker() {
        if [ "$1" = "inspect" ]; then return 1; fi
      }
      When call cleanup_stale_container
      The status should be success
    End

    It 'is a no-op when container is running'
      SANDBOX_NAME="test"
      docker() {
        if [ "$1" = "inspect" ]; then echo "running"; return 0; fi
      }
      COMPOSE_FILES="-f docker-compose.yaml"
      When call cleanup_stale_container
      The output should eq ''
      The status should be success
    End

    It 'is a no-op when container is exited (stopped via compose stop)'
      SANDBOX_NAME="test"
      docker() {
        if [ "$1" = "inspect" ]; then echo "exited"; return 0; fi
      }
      COMPOSE_FILES="-f docker-compose.yaml"
      When call cleanup_stale_container
      The output should eq ''
      The status should be success
    End

    It 'is a no-op when container is paused'
      SANDBOX_NAME="test"
      docker() {
        if [ "$1" = "inspect" ]; then echo "paused"; return 0; fi
      }
      COMPOSE_FILES="-f docker-compose.yaml"
      When call cleanup_stale_container
      The output should eq ''
      The status should be success
    End

    It 'calls compose down when container is in dead state'
      SANDBOX_NAME="test"
      downed=false
      docker() {
        case "$1" in
          inspect) echo "dead"; return 0 ;;
          compose)
            shift
            # skip -p <project> flag added by cleanup_stale_container
            if [ "$1" = "-p" ]; then shift; shift; fi
            while [ "$1" = "-f" ]; do shift; shift; done
            if [ "$1" = "down" ]; then downed=true; fi
            ;;
        esac
      }
      COMPOSE_FILES="-f docker-compose.yaml"
      When call cleanup_stale_container
      The output should include 'Cleaning up stale container'
      The variable downed should eq true
    End

    It 'falls back to docker rm -f when compose down fails'
      SANDBOX_NAME="test"
      removed=false
      docker() {
        case "$1" in
          inspect) echo "dead"; return 0 ;;
          compose)
            shift
            # skip -p <project> flag added by cleanup_stale_container
            if [ "$1" = "-p" ]; then shift; shift; fi
            while [ "$1" = "-f" ]; do shift; shift; done
            if [ "$1" = "down" ]; then return 1; fi
            ;;
          rm) export removed=true ;;
        esac
      }
      export COMPOSE_FILES="-f docker-compose.yaml"
      When call cleanup_stale_container
      The output should include 'Cleaning up stale container'
      The variable removed should eq true
    End
  End

  Describe 'list_instances()'
    It 'emits rows for managed containers'
      docker() {
        if [ "$1" = "ps" ]; then
          printf 'foo\trunning\tbase,docker\n'
          printf 'bar\texited\tbase\n'
          return 0
        fi
      }
      When call list_instances
      The output should include 'foo'
      The output should include 'bar'
      The status should be success
    End

    It 'emits nothing when no managed containers exist'
      docker() { return 0; }
      When call list_instances
      The output should eq ''
      The status should be success
    End
  End

  Describe 'ensure_clean_slate_credentials()'
    # Silence informational output — qecho is defined in the rollup but we
    # override it here to keep test output clean.
    qecho() { :; }

    KEYCHAIN_CREDS='{"claudeAiOauth":{"accessToken":"keychain-tok","refreshToken":"keychain-ref","expiresAt":9999999999000}}'
    FILE_CREDS='{"claudeAiOauth":{"accessToken":"file-tok","refreshToken":"file-ref","expiresAt":9999999999000}}'

    setup() {
      CREDS_HOME="$(mktemp -d)"
      mkdir -p "${CREDS_HOME}/.claude"
      ORIG_HOME="${HOME}"
      HOME="${CREDS_HOME}"
      unset AI_SANDBOX_CREDENTIALS_JSON_B64
    }
    cleanup() {
      rm -rf "${CREDS_HOME}"
      HOME="${ORIG_HOME}"
      unset AI_SANDBOX_CREDENTIALS_JSON_B64
    }
    Before 'setup'
    After 'cleanup'

    # Helper: call ensure_clean_slate_credentials and decode the access token from
    # the exported env var to prove which credential source was used.
    decode_access_token() {
      ensure_clean_slate_credentials
      printf '%s' "${AI_SANDBOX_CREDENTIALS_JSON_B64}" | base64 -d \
        | jq -r '.claudeAiOauth.accessToken'
    }

    Describe 'on macOS'
      uname() { printf 'Darwin\n'; }

      Describe 'when Keychain has valid credentials'
        setup_keychain() {
          _hex_creds=$(printf '%s' "${KEYCHAIN_CREDS}" | xxd -p | tr -d '\n')
          # shellcheck disable=SC2317 # called indirectly by ensure_clean_slate_credentials
          security() { printf '%s' "${_hex_creds}"; return 0; }
        }
        Before 'setup_keychain'

        It 'exports AI_SANDBOX_CREDENTIALS_JSON_B64'
          When call ensure_clean_slate_credentials
          The status should be success
          The variable AI_SANDBOX_CREDENTIALS_JSON_B64 should be present
        End

        It 'uses Keychain credentials even when a credentials file also exists'
          printf '%s' "${FILE_CREDS}" > "${HOME}/.claude/.credentials.json"
          When call decode_access_token
          The output should eq 'keychain-tok'
          The status should be success
        End
      End

      Describe 'when Keychain is unavailable but credentials file exists (fallback)'
        setup_file_fallback() {
          # shellcheck disable=SC2317
          security() { return 1; }
          printf '%s' "${FILE_CREDS}" > "${HOME}/.claude/.credentials.json"
        }
        Before 'setup_file_fallback'

        It 'exports AI_SANDBOX_CREDENTIALS_JSON_B64 from the file'
          When call ensure_clean_slate_credentials
          The status should be success
          The variable AI_SANDBOX_CREDENTIALS_JSON_B64 should be present
        End

        It 'uses the file credentials'
          When call decode_access_token
          The output should eq 'file-tok'
          The status should be success
        End
      End

      Describe 'when neither Keychain nor credentials file is available'
        setup_none() {
          # shellcheck disable=SC2317
          security() { return 1; }
        }
        Before 'setup_none'

        It 'returns success with a warning on stderr'
          When call ensure_clean_slate_credentials
          The status should be success
          The stderr should include 'warn:'
        End

        It 'does not export AI_SANDBOX_CREDENTIALS_JSON_B64'
          When call ensure_clean_slate_credentials
          The stderr should include 'warn:'
          The variable AI_SANDBOX_CREDENTIALS_JSON_B64 should be undefined
        End
      End
    End

    Describe 'on Linux'
      uname() { printf 'Linux\n'; }

      It 'exports AI_SANDBOX_CREDENTIALS_JSON_B64 from the credentials file'
        printf '%s' "${FILE_CREDS}" > "${HOME}/.claude/.credentials.json"
        When call ensure_clean_slate_credentials
        The status should be success
        The variable AI_SANDBOX_CREDENTIALS_JSON_B64 should be present
      End

      It 'emits a warning when the credentials file is missing'
        When call ensure_clean_slate_credentials
        The status should be success
        The stderr should include 'warn:'
      End

      It 'does not export AI_SANDBOX_CREDENTIALS_JSON_B64 when file is missing'
        When call ensure_clean_slate_credentials
        The stderr should include 'warn:'
        The variable AI_SANDBOX_CREDENTIALS_JSON_B64 should be undefined
      End
    End
  End
End
