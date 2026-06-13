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

    It 'rejects reserved names as sandbox names'
      When run parse_options status
      The status should be failure
      The stderr should include 'reserved'
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
End
