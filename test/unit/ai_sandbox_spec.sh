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

  Describe 'ensure_image()'
    setup() {
      export TOOL_CACHE_DIR="$(mktemp -d)"
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
          compose)
            shift
            # skip -f flags
            while [ "$1" = "-f" ]; do shift; shift; done
            if [ "$1" = "images" ]; then
              echo ""  # empty = no image
            elif [ "$1" = "build" ]; then
              built=true
            fi
            ;;
        esac
      }
      COMPOSE_FILES="-f docker-compose.yaml"
      SSH_AUTH_SOCK="/tmp/ssh"
      When call ensure_image
      The output should include 'Image not found'
      The variable built should eq true
    End

    It 'does nothing when image exists'
      docker() {
        case "$1" in
          compose)
            shift
            while [ "$1" = "-f" ]; do shift; shift; done
            if [ "$1" = "images" ]; then
              echo "sha256:abc123"
            fi
            ;;
        esac
      }
      is_build_stale() { return 1; }
      COMPOSE_FILES="-f docker-compose.yaml"
      When call ensure_image
      The output should eq ''
    End
  End

  Describe 'parse_options()'
    It 'leaves NO_DOCKER false by default'
      When call parse_options
      The variable NO_DOCKER should eq false
    End

    It 'sets NO_DOCKER when --no-docker is passed'
      When call parse_options --no-docker
      The variable NO_DOCKER should eq true
    End

    It 'sets NO_DOCKER when -D is passed'
      When call parse_options -D
      The variable NO_DOCKER should eq true
    End
  End

  Describe 'image_label()'
    It 'returns empty string when docker inspect fails'
      docker() { return 1; }
      When call image_label ai.sandbox.docker-enabled
      The output should eq ''
      The status should be success
    End

    It 'returns the label value when docker inspect succeeds'
      docker() { echo "false"; return 0; }
      When call image_label ai.sandbox.docker-enabled
      The output should eq 'false'
    End
  End

  Describe 'build_config_changed()'
    It 'returns unchanged (1) when image has no labels at all'
      docker() { return 1; }
      NO_CHROMIUM=false
      NO_DOCKER=false
      When call build_config_changed
      The status should be failure
    End

    It 'returns changed (0) when NO_DOCKER=true but image has docker-enabled=true'
      docker() {
        case "$*" in
          *ai.sandbox.docker-enabled*) echo "true" ;;
          *ai.sandbox.chromium-enabled*) echo "true" ;;
        esac
      }
      NO_CHROMIUM=false
      NO_DOCKER=true
      When call build_config_changed
      The status should be success
    End

    It 'returns changed (0) when NO_CHROMIUM=true but image has chromium-enabled=true'
      docker() {
        case "$*" in
          *ai.sandbox.docker-enabled*) echo "true" ;;
          *ai.sandbox.chromium-enabled*) echo "true" ;;
        esac
      }
      NO_CHROMIUM=true
      NO_DOCKER=false
      When call build_config_changed
      The status should be success
    End

    It 'returns unchanged (1) when both labels match the flags'
      docker() {
        case "$*" in
          *ai.sandbox.docker-enabled*) echo "false" ;;
          *ai.sandbox.chromium-enabled*) echo "false" ;;
        esac
      }
      NO_CHROMIUM=true
      NO_DOCKER=true
      When call build_config_changed
      The status should be failure
    End
  End

  Describe 'is_build_stale()'
    setup() {
      export TOOL_CACHE_DIR="$(mktemp -d)"
      export PROJECT_ROOT="$(mktemp -d)"
      mkdir -p "${PROJECT_ROOT}/docker"
    }
    cleanup() {
      rm -rf "$TOOL_CACHE_DIR" "$PROJECT_ROOT"
    }
    Before 'setup'
    After 'cleanup'

    It 'returns stale when marker is missing'
      NO_CHROMIUM=false
      NO_DOCKER=false
      docker() { return 1; }
      When call is_build_stale
      The status should be success
    End

    It 'returns fresh when marker is present, no files newer, and labels match'
      touch "${TOOL_CACHE_DIR}/.last-built"
      # Give the marker a clearly-older mtime.
      touch -t 202001010000 "${TOOL_CACHE_DIR}/.last-built"
      NO_CHROMIUM=false
      NO_DOCKER=false
      docker() {
        case "$*" in
          *ai.sandbox.docker-enabled*) echo "true" ;;
          *ai.sandbox.chromium-enabled*) echo "true" ;;
        esac
      }
      When call is_build_stale
      The status should be failure
    End

    It 'returns stale when labels disagree with flags even if files are unchanged'
      touch "${TOOL_CACHE_DIR}/.last-built"
      touch -t 202001010000 "${TOOL_CACHE_DIR}/.last-built"
      NO_CHROMIUM=false
      NO_DOCKER=true
      docker() {
        case "$*" in
          *ai.sandbox.docker-enabled*) echo "true" ;;
          *ai.sandbox.chromium-enabled*) echo "false" ;;
        esac
      }
      When call is_build_stale
      The status should be success
    End
  End

  Describe 'cleanup_stale_container()'
    It 'returns 0 when no container exists'
      docker() {
        if [ "$1" = "inspect" ]; then return 1; fi
      }
      When call cleanup_stale_container
      The status should be success
    End

    It 'is a no-op when container is running'
      docker() {
        if [ "$1" = "inspect" ]; then echo "running"; return 0; fi
      }
      COMPOSE_FILES="-f docker-compose.yaml"
      When call cleanup_stale_container
      The output should eq ''
      The status should be success
    End

    It 'calls compose down when container is exited'
      downed=false
      docker() {
        case "$1" in
          inspect) echo "exited"; return 0 ;;
          compose)
            shift
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
      removed=false
      docker() {
        case "$1" in
          inspect) echo "exited"; return 0 ;;
          compose)
            shift
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
End
