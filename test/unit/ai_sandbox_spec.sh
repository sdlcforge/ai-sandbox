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

  Describe 'variant_key()'
    It 'returns full when no flags are set'
      NO_CHROMIUM=false
      NO_DOCKER=false
      When call variant_key
      The output should eq 'full'
    End

    It 'returns no-chromium when only --no-chromium is set'
      NO_CHROMIUM=true
      NO_DOCKER=false
      When call variant_key
      The output should eq 'no-chromium'
    End

    It 'returns no-docker when only --no-docker is set'
      NO_CHROMIUM=false
      NO_DOCKER=true
      When call variant_key
      The output should eq 'no-docker'
    End

    It 'returns no-chromium-no-docker when both flags are set'
      NO_CHROMIUM=true
      NO_DOCKER=true
      When call variant_key
      The output should eq 'no-chromium-no-docker'
    End
  End

  Describe 'ensure_image()'
    setup() {
      export TOOL_CACHE_DIR="$(mktemp -d)"
      NO_CHROMIUM=false
      NO_DOCKER=false
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

  Describe 'is_build_stale()'
    setup() {
      export PROJECT_ROOT="$(mktemp -d)"
      mkdir -p "${PROJECT_ROOT}/docker"
      NO_CHROMIUM=false
      NO_DOCKER=false
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
