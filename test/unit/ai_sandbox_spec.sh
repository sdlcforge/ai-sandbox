# shellcheck shell=bash
# shellcheck disable=SC2034,SC2155,SC2317,SC2329 # ShellSpec DSL invokes functions indirectly and checks variables via framework assertions
#                                         ^ 'docker()' doesn't think 'docker()' calls are called

Describe 'ai-sandbox.sh'
  Include "$PWD/bin/ai-sandbox.sh"

  Describe 'check_docker()'
    It 'succeeds and prints confirmed when docker is running'
      QUIET=0
      docker() { if [ "$1" = "info" ]; then return 0; fi; }
      When call check_docker
      The output should include 'confirmed.'
      The status should be success
    End

    It 'fails and prints message arg when docker is not running'
      QUIET=0
      docker() { if [ "$1" = "info" ]; then return 1; fi; }
      When call check_docker "starting..."
      The output should include 'starting...'
      The status should be failure
    End

    It 'fails and prints default message when docker is not running and no arg'
      QUIET=0
      docker() { if [ "$1" = "info" ]; then return 1; fi; }
      When call check_docker ""
      The output should include 'NOT running.'
      The status should be failure
    End

    It 'prints nothing when QUIET=1 (quiet mode)'
      QUIET=1
      docker() { if [ "$1" = "info" ]; then return 0; fi; }
      When call check_docker
      The output should eq ''
      The status should be success
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
      QUIET=0
      # Use the last positional arg (rather than a fixed "$6") for the
      # destination path: QUIET=0 here routes download_tool() through its
      # "curl -f -SL ... -o <dest>" (5-arg) branch rather than the default
      # "curl --progress-bar ... -o <dest>" (6-arg) branch, so a fixed index
      # would be wrong for one of the two branches.
      curl() { touch "${!#}"; return 0; }
      When call download_tool "https://example.com/tool.tar.gz" "tool.tar.gz"
      The output should include 'Downloading tool.tar.gz'
      The status should be success
    End

    It 'skips when file already exists'
      QUIET=0
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

  Describe 'is_docker_proxy_label_true()'
    # Unit coverage for the authoritative-label fallback this task adds to
    # src/index.sh's EFFECTIVE_PROXY computation (phase-01/003). See the
    # 'command dispatch: dropped custom profile' Describe block below for the
    # end-to-end regression coverage of the actual EFFECTIVE_PROXY fallback
    # behavior this function backs.
    It 'returns success when the persisted label is "true"'
      SANDBOX_NAME="test"
      docker() {
        if [ "$1" = "inspect" ]; then echo "true"; return 0; fi
      }
      When call is_docker_proxy_label_true
      The status should be success
    End

    It 'returns failure when the persisted label is "false"'
      SANDBOX_NAME="test"
      docker() {
        if [ "$1" = "inspect" ]; then echo "false"; return 0; fi
      }
      When call is_docker_proxy_label_true
      The status should be failure
    End

    It 'returns failure when the label is absent (empty output, e.g. pre-label container)'
      SANDBOX_NAME="test"
      docker() {
        if [ "$1" = "inspect" ]; then echo ""; return 0; fi
      }
      When call is_docker_proxy_label_true
      The status should be failure
    End

    It 'returns failure when no container exists (inspect fails) -- naturally scopes the fallback off of create'
      SANDBOX_NAME="test"
      docker() {
        if [ "$1" = "inspect" ]; then return 1; fi
      }
      When call is_docker_proxy_label_true
      The status should be failure
    End
  End

  Describe 'netmask_to_prefix()'
    It 'converts a /24 netmask'
      When call netmask_to_prefix 255.255.255.0
      The output should eq '24'
      The status should be success
    End

    It 'converts a /16 netmask'
      When call netmask_to_prefix 255.255.0.0
      The output should eq '16'
      The status should be success
    End

    It 'converts a /8 netmask'
      When call netmask_to_prefix 255.0.0.0
      The output should eq '8'
      The status should be success
    End

    It 'converts a /32 netmask'
      When call netmask_to_prefix 255.255.255.255
      The output should eq '32'
      The status should be success
    End

    It 'fails on a netmask with the wrong octet count'
      When call netmask_to_prefix 255.255.255
      The status should be failure
      The output should eq ''
    End

    It 'fails on a netmask with a non-numeric octet'
      When call netmask_to_prefix 255.255.abc.0
      The status should be failure
      The output should eq ''
    End

    It 'fails on a netmask with an out-of-range octet'
      When call netmask_to_prefix 255.255.256.0
      The status should be failure
      The output should eq ''
    End

    It 'fails cleanly (no bash arithmetic error) on a leading-zero octet'
      # A leading-zero numeral (e.g. "008") would be parsed as octal by bash
      # arithmetic ($(( ))) and abort with "value too great for base" if not
      # rejected before reaching it -- see is_octet(). Assert both a clean
      # failure status and that no such error leaks to stderr.
      When call netmask_to_prefix 255.255.008.0
      The status should be failure
      The output should eq ''
      The stderr should eq ''
    End
  End

  Describe 'network_address()'
    It 'derives the network address for a /24 netmask'
      When call network_address 192.168.1.42 255.255.255.0
      The output should eq '192.168.1.0'
      The status should be success
    End

    It 'derives the network address for a /16 netmask'
      When call network_address 10.20.30.40 255.255.0.0
      The output should eq '10.20.0.0'
      The status should be success
    End

    It 'fails on a malformed IP address'
      When call network_address '1.2.3' 255.255.255.0
      The status should be failure
      The output should eq ''
    End

    It 'fails on a malformed netmask'
      When call network_address 192.168.1.42 'not-a-mask'
      The status should be failure
      The output should eq ''
    End

    It 'fails cleanly (no bash arithmetic error) on a leading-zero IP octet'
      When call network_address 192.168.008.42 255.255.255.0
      The status should be failure
      The output should eq ''
      The stderr should eq ''
    End
  End

  Describe 'compute_lan_cidr()'
    It 'returns the LAN CIDR when route/ipconfig detection succeeds'
      uname() { printf 'Darwin\n'; }
      route() { printf '  interface: en0\n'; }
      ipconfig() {
        case "$1" in
          getifaddr) printf '192.168.1.42\n' ;;
          getoption) printf '255.255.255.0\n' ;;
        esac
      }
      When call compute_lan_cidr
      The output should eq '192.168.1.0/24'
      The status should be success
    End

    It 'fails soft (empty output, warning, success status) when there is no default route'
      uname() { printf 'Darwin\n'; }
      route() { return 1; }
      ipconfig() { return 1; }
      When call compute_lan_cidr
      The output should eq ''
      The stderr should include "could not determine the host's default-route interface"
      The status should be success
    End

    It 'fails soft when ipconfig cannot resolve the interface (e.g. VPN-only interface)'
      uname() { printf 'Darwin\n'; }
      route() { printf '  interface: utun3\n'; }
      ipconfig() { return 1; }
      When call compute_lan_cidr
      The output should eq ''
      The stderr should include 'could not determine IP address/subnet mask'
      The status should be success
    End

    It 'fails soft on an unrecognized subnet mask'
      uname() { printf 'Darwin\n'; }
      route() { printf '  interface: en0\n'; }
      ipconfig() {
        case "$1" in
          getifaddr) printf '192.168.1.42\n' ;;
          getoption) printf 'not-a-mask\n' ;;
        esac
      }
      When call compute_lan_cidr
      The output should eq ''
      The stderr should include 'unrecognized subnet mask'
      The status should be success
    End

    It 'fails soft with a platform-specific warning on non-macOS hosts'
      uname() { printf 'Linux\n'; }
      When call compute_lan_cidr
      The output should eq ''
      The stderr should include 'macOS-only'
      The status should be success
    End
  End

  Describe 'ensure_image()'
    setup() {
      export TOOL_CACHE_DIR="$(mktemp -d)"
      export AI_SANDBOX_IMAGE_TAG="ai-sandbox:profile-test"
      export COMPOSE_PROJECT="ai-sandbox-flow-rook"
      unset PROFILE_COMPOSITION_HASH
    }
    cleanup() {
      rm -rf "$TOOL_CACHE_DIR"
    }
    Before 'setup'
    After 'cleanup'

    It 'calls build when image not found'
      QUIET=0
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
            # do_build() now emits '-p "${COMPOSE_PROJECT}"' before
            # ${COMPOSE_FILES} (regression: missing -p flag) -- skip it too.
            [ "$1" = "-p" ] && { shift; shift; }
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

  Describe 'do_build()'
    It 'scopes the build to the current compose project (regression: missing -p flag)'
      # Without -p "${COMPOSE_PROJECT}", build resolves against Compose's
      # default project-name derivation instead of the named instance's
      # actual project scope -- the same class of bug the start_shell()
      # regression test above already caught and fixed for exec.
      AI_SANDBOX_IMAGE_TAG="ai-sandbox:profile-test"
      COMPOSE_FILES="-f docker-compose.yaml"
      COMPOSE_PROJECT="ai-sandbox-flow-rook"
      SSH_AUTH_SOCK="/tmp/ssh"
      docker() {
        case "$1" in
          image) [ "$2" = "rm" ] && return 0 ;;
          compose) printf '%s\n' "$*" ;;
        esac
      }
      When call do_build
      The output should include 'compose -p ai-sandbox-flow-rook -f docker-compose.yaml build'
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

  Describe 'start_shell()'
    It 'scopes the exec to the current compose project (regression: missing -p flag)'
      # Without -p "${COMPOSE_PROJECT}", exec resolves against the wrong
      # default compose project scope for named instances and fails with
      # `service "ai-sandbox" is not running`.
      COMPOSE_FILES="-f docker-compose.yaml"
      COMPOSE_PROJECT="ai-sandbox-flow-rook"
      HOST_USER="testuser"
      START_DIR="/nonexistent"
      docker() { printf '%s\n' "$*"; }
      When call start_shell
      The output should include 'compose -p ai-sandbox-flow-rook -f docker-compose.yaml exec -u testuser ai-sandbox'
    End
  End

  Describe 'run_enter_shell_if_requested()'
    It 'propagates a start_shell failure when CMD is enter (regression: enter always exited 0)'
      CMD=enter
      # shellcheck disable=SC2317 # invoked indirectly by run_enter_shell_if_requested
      start_shell() { return 3; }
      When call run_enter_shell_if_requested
      The status should eq 3
    End

    It 'succeeds when start_shell succeeds and CMD is enter'
      CMD=enter
      # shellcheck disable=SC2317 # invoked indirectly by run_enter_shell_if_requested
      start_shell() { return 0; }
      When call run_enter_shell_if_requested
      The status should be success
    End

    It 'is a no-op success when CMD is start (start_shell not invoked)'
      CMD=start
      called=false
      # shellcheck disable=SC2317 # invoked indirectly by run_enter_shell_if_requested
      start_shell() { called=true; return 3; }
      When call run_enter_shell_if_requested
      The status should be success
      The variable called should eq false
    End
  End

  Describe 'should_restore_config()'
    # Regression coverage for the orphaned docker-socket-proxy sidecar bug:
    # src/index.sh's restore call site previously gated restore_saved_config()
    # to only CMD=start/enter, so every other per-instance command (delete,
    # clean, stop, build, fix-ssh, ...) ran with whatever --profile flags
    # (usually none) this invocation passed rather than the instance's
    # persisted composition -- silently dropping the docker capability (and
    # therefore the proxy sidecar/network) from that invocation's compose-file
    # assembly. should_restore_config() must return true for every CMD value
    # reachable at that call site except "create".
    It 'returns true for CMD=start'
      When call should_restore_config start
      The status should be success
    End

    It 'returns true for CMD=enter'
      When call should_restore_config enter
      The status should be success
    End

    It 'returns true for CMD=attach'
      When call should_restore_config attach
      The status should be success
    End

    It 'returns true for CMD=fix-ssh'
      When call should_restore_config fix-ssh
      The status should be success
    End

    It 'returns true for CMD=build'
      When call should_restore_config build
      The status should be success
    End

    It 'returns true for CMD=user-exec'
      When call should_restore_config user-exec
      The status should be success
    End

    It 'returns true for CMD=root-exec'
      When call should_restore_config root-exec
      The status should be success
    End

    It 'returns true for CMD=detail'
      When call should_restore_config detail
      The status should be success
    End

    It 'returns true for CMD=stop'
      When call should_restore_config stop
      The status should be success
    End

    It 'returns true for CMD=delete'
      When call should_restore_config delete
      The status should be success
    End

    It 'returns true for CMD=clean'
      When call should_restore_config clean
      The status should be success
    End

    It 'returns true for CMD=up'
      When call should_restore_config up
      The status should be success
    End

    It 'returns true for an arbitrary word forwarded to the docker-compose passthrough branch (e.g. CMD=logs)'
      When call should_restore_config logs
      The status should be success
    End

    It 'returns false for CMD=create (fresh state, nothing to restore)'
      When call should_restore_config create
      The status should be failure
    End
  End

  Describe 'should_force_proxy_label_fallback()'
    # Regression coverage for phase-01/004 (scoping task 003's EFFECTIVE_PROXY
    # label fallback down to only the teardown/preserve commands where the
    # orphaned-sidecar bug actually manifests) as refined by phase-01/005
    # (gating on CONFIG_FLAGS_PROVIDED in addition to CMD). The third phase-1
    # gate review found task 003's fallback applied unconditionally to every
    # per-instance CMD, including start/enter, which meant an explicit,
    # user-confirmed --profile change removing the docker capability was
    # silently reverted -- violating docs/architecture.md's "Matches"
    # subsection ("explicit invocation always wins" invariant). The fourth
    # phase-1 gate review then found task 004's CMD-only gating was itself
    # the wrong axis: whether an invocation is "explicit" is decided by
    # CONFIG_FLAGS_PROVIDED, not by which CMD was typed -- a bare start/enter
    # with no --profile this run (CONFIG_FLAGS_PROVIDED=false) is a
    # restore/resume, not an explicit override, and must still get the
    # fallback if the persisted profile has drifted; conversely an explicit
    # `fix-ssh --profile <non-docker>` (CONFIG_FLAGS_PROVIDED=true) must be
    # allowed to actually drop the capability.
    #
    # stop/delete/clean apply the fallback unconditionally, regardless of
    # CONFIG_FLAGS_PROVIDED. fix-ssh/start/enter/up apply it only when
    # CONFIG_FLAGS_PROVIDED is not "true". Every other CMD never applies it,
    # regardless of CONFIG_FLAGS_PROVIDED.
    It 'returns true for CMD=stop regardless of CONFIG_FLAGS_PROVIDED (unset)'
      When call should_force_proxy_label_fallback stop
      The status should be success
    End

    It 'returns true for CMD=stop with CONFIG_FLAGS_PROVIDED=true'
      When call should_force_proxy_label_fallback stop true
      The status should be success
    End

    It 'returns true for CMD=stop with CONFIG_FLAGS_PROVIDED=false'
      When call should_force_proxy_label_fallback stop false
      The status should be success
    End

    It 'returns true for CMD=delete regardless of CONFIG_FLAGS_PROVIDED (unset)'
      When call should_force_proxy_label_fallback delete
      The status should be success
    End

    It 'returns true for CMD=delete with CONFIG_FLAGS_PROVIDED=true'
      When call should_force_proxy_label_fallback delete true
      The status should be success
    End

    It 'returns true for CMD=clean regardless of CONFIG_FLAGS_PROVIDED (unset)'
      When call should_force_proxy_label_fallback clean
      The status should be success
    End

    It 'returns true for CMD=clean with CONFIG_FLAGS_PROVIDED=true'
      When call should_force_proxy_label_fallback clean true
      The status should be success
    End

    It 'returns true for CMD=fix-ssh when CONFIG_FLAGS_PROVIDED is unset (bare restore/resume)'
      When call should_force_proxy_label_fallback fix-ssh
      The status should be success
    End

    It 'returns true for CMD=fix-ssh with CONFIG_FLAGS_PROVIDED=false'
      When call should_force_proxy_label_fallback fix-ssh false
      The status should be success
    End

    It 'returns false for CMD=fix-ssh with CONFIG_FLAGS_PROVIDED=true (explicit --profile must take effect)'
      When call should_force_proxy_label_fallback fix-ssh true
      The status should be failure
    End

    It 'returns true for CMD=start when CONFIG_FLAGS_PROVIDED is unset (bare restore/resume, e.g. profile drift)'
      When call should_force_proxy_label_fallback start
      The status should be success
    End

    It 'returns true for CMD=start with CONFIG_FLAGS_PROVIDED=false'
      When call should_force_proxy_label_fallback start false
      The status should be success
    End

    It 'returns false for CMD=start with CONFIG_FLAGS_PROVIDED=true (explicit profile change must take effect)'
      When call should_force_proxy_label_fallback start true
      The status should be failure
    End

    It 'returns true for CMD=enter when CONFIG_FLAGS_PROVIDED is unset (bare restore/resume)'
      When call should_force_proxy_label_fallback enter
      The status should be success
    End

    It 'returns false for CMD=enter with CONFIG_FLAGS_PROVIDED=true (explicit profile change must take effect)'
      When call should_force_proxy_label_fallback enter true
      The status should be failure
    End

    It 'returns true for CMD=up when CONFIG_FLAGS_PROVIDED is unset (bare restore/resume)'
      When call should_force_proxy_label_fallback up
      The status should be success
    End

    It 'returns false for CMD=up with CONFIG_FLAGS_PROVIDED=true'
      When call should_force_proxy_label_fallback up true
      The status should be failure
    End

    It 'returns false for CMD=create (no prior container to read a label from) regardless of CONFIG_FLAGS_PROVIDED'
      When call should_force_proxy_label_fallback create
      The status should be failure
    End

    It 'returns false for CMD=create with CONFIG_FLAGS_PROVIDED=false'
      When call should_force_proxy_label_fallback create false
      The status should be failure
    End

    It 'returns false for CMD=detail (do_status() never consumes EFFECTIVE_PROXY) regardless of CONFIG_FLAGS_PROVIDED'
      When call should_force_proxy_label_fallback detail
      The status should be failure
    End

    It 'returns false for CMD=build regardless of CONFIG_FLAGS_PROVIDED'
      When call should_force_proxy_label_fallback build false
      The status should be failure
    End

    It 'returns false for CMD=user-exec regardless of CONFIG_FLAGS_PROVIDED'
      When call should_force_proxy_label_fallback user-exec
      The status should be failure
    End

    It 'returns false for CMD=root-exec regardless of CONFIG_FLAGS_PROVIDED'
      When call should_force_proxy_label_fallback root-exec
      The status should be failure
    End

    It 'returns false for CMD=attach regardless of CONFIG_FLAGS_PROVIDED'
      When call should_force_proxy_label_fallback attach
      The status should be failure
    End
  End

  Describe 'restore_saved_config()'
    # Helper: base64-encode a config-input JSON payload exactly as
    # src/index.sh's assembly block does, for use as the mocked
    # `ai.sandbox.config` label value below.
    encode_config() {
      printf '%s' "$1" | base64 | tr -d '\n'
    }

    It 'restores all eight config-input dimensions from a mocked ai.sandbox.config label (full round trip)'
      # Direct regression test for the design note's restore-side requirement:
      # a sandbox created with a full set of config-changing flags records the
      # complete input record in the single ai.sandbox.config label; a bare
      # `enter` must reconstruct every one of the eight dimensions from it
      # (allow_egress is the eighth, added alongside the original seven).
      SANDBOX_NAME="test"
      CONFIG_FLAGS_PROVIDED=false
      PROFILES=()
      MODE_OVERRIDE=""
      NO_ISOLATE_CONFIG=false
      CLEAN_SLATE=false
      CLI_MARKETPLACES=()
      CLI_PLUGINS=()
      CLI_ENABLE_ALL=false
      CLI_ALLOW_EGRESS=()
      config_b64="$(encode_config '{"version":1,"profiles":["base","docker"],"mode":"static","no_isolate_config":true,"clean_slate":true,"marketplaces":["https://registry.example.com/plugins"],"plugins":["claude-mem"],"enable_all_plugins":true,"allow_egress":["1.2.3.4:443"]}')"
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
      The variable "CLI_ALLOW_EGRESS[*]" should eq '1.2.3.4:443'
    End

    It 'restores CLI_ALLOW_EGRESS from a mocked ai.sandbox.config label'
      SANDBOX_NAME="test"
      CONFIG_FLAGS_PROVIDED=false
      PROFILES=()
      MODE_OVERRIDE=""
      NO_ISOLATE_CONFIG=false
      CLEAN_SLATE=false
      CLI_MARKETPLACES=()
      CLI_PLUGINS=()
      CLI_ENABLE_ALL=false
      CLI_ALLOW_EGRESS=()
      config_b64="$(encode_config '{"version":1,"allow_egress":["1.2.3.4:443","10.0.0.0/8:8080","api.example.com:443"]}')"
      docker() {
        if [ "$1" = "inspect" ]; then
          if [[ "$*" == *"ai.sandbox.config"* ]]; then
            echo "${config_b64}"
          fi
          return 0
        fi
      }
      When call restore_saved_config
      The variable "CLI_ALLOW_EGRESS[*]" should eq '1.2.3.4:443 10.0.0.0/8:8080 api.example.com:443'
    End

    It 'drops a restored --allow-egress spec that fails validation, keeping well-formed entries (mirrors --allow-egress parse-time validation)'
      # src/options.sh's --allow-egress parser rejects a spec that doesn't
      # validate (see the parse_options() --allow-egress tests above). A
      # restored value arrives via a persisted docker label rather than this
      # run's CLI args, so it must be independently re-validated rather than
      # trusted verbatim.
      SANDBOX_NAME="test"
      CONFIG_FLAGS_PROVIDED=false
      PROFILES=()
      MODE_OVERRIDE=""
      NO_ISOLATE_CONFIG=false
      CLEAN_SLATE=false
      CLI_MARKETPLACES=()
      CLI_PLUGINS=()
      CLI_ENABLE_ALL=false
      CLI_ALLOW_EGRESS=()
      config_b64="$(encode_config '{"version":1,"allow_egress":["1.2.3.4:70000","10.0.0.0/8:8080"]}')"
      docker() {
        if [ "$1" = "inspect" ]; then
          if [[ "$*" == *"ai.sandbox.config"* ]]; then
            echo "${config_b64}"
          fi
          return 0
        fi
      }
      When call restore_saved_config
      The variable "CLI_ALLOW_EGRESS[*]" should eq '10.0.0.0/8:8080'
      The stderr should include 'dropping restored --allow-egress spec'
      The stderr should include '1.2.3.4:70000'
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

    It 'restores STATIC_PLAYGROUND=true from a mocked ai.sandbox.config label carrying static_playground:true'
      SANDBOX_NAME="test"
      CONFIG_FLAGS_PROVIDED=false
      PROFILES=()
      MODE_OVERRIDE=""
      NO_ISOLATE_CONFIG=false
      CLEAN_SLATE=false
      CLI_MARKETPLACES=()
      CLI_PLUGINS=()
      CLI_ENABLE_ALL=false
      STATIC_PLAYGROUND=false
      config_b64="$(encode_config '{"version":1,"profiles":[],"mode":"","no_isolate_config":false,"clean_slate":false,"marketplaces":[],"plugins":[],"enable_all_plugins":false,"static_playground":true}')"
      docker() {
        if [ "$1" = "inspect" ]; then
          if [[ "$*" == *"ai.sandbox.config"* ]]; then
            echo "${config_b64}"
          fi
          return 0
        fi
      }
      When call restore_saved_config
      The variable STATIC_PLAYGROUND should eq true
    End

    It 'leaves STATIC_PLAYGROUND at its default false when the label omits the field (regression: additive-field no-op)'
      SANDBOX_NAME="test"
      CONFIG_FLAGS_PROVIDED=false
      PROFILES=()
      MODE_OVERRIDE=""
      NO_ISOLATE_CONFIG=false
      CLEAN_SLATE=false
      CLI_MARKETPLACES=()
      CLI_PLUGINS=()
      CLI_ENABLE_ALL=false
      STATIC_PLAYGROUND=false
      config_b64="$(encode_config '{"version":1,"profiles":[],"mode":"","no_isolate_config":false,"clean_slate":false,"marketplaces":[],"plugins":[],"enable_all_plugins":false}')"
      docker() {
        if [ "$1" = "inspect" ]; then
          if [[ "$*" == *"ai.sandbox.config"* ]]; then
            echo "${config_b64}"
          fi
          return 0
        fi
      }
      When call restore_saved_config
      The variable STATIC_PLAYGROUND should eq false
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

    It 'drops a restored marketplace ref with an invalid scheme, keeping well-formed entries (mirrors --add-marketplace scheme validation)'
      # src/options.sh's --add-marketplace parser rejects any ref that
      # doesn't start with https:// or file:// (see "rejects --add-marketplace
      # with invalid scheme" above). A restored value arrives via a persisted
      # docker label rather than this run's CLI args, so it must be
      # independently re-validated rather than trusted verbatim.
      SANDBOX_NAME="test"
      CONFIG_FLAGS_PROVIDED=false
      PROFILES=()
      MODE_OVERRIDE=""
      NO_ISOLATE_CONFIG=false
      CLEAN_SLATE=false
      CLI_MARKETPLACES=()
      CLI_PLUGINS=()
      CLI_ENABLE_ALL=false
      config_b64="$(encode_config '{"version":1,"marketplaces":["ftp://bad.example.com","https://good.example.com/plugins"]}')"
      docker() {
        if [ "$1" = "inspect" ]; then
          if [[ "$*" == *"ai.sandbox.config"* ]]; then
            echo "${config_b64}"
          fi
          return 0
        fi
      }
      When call restore_saved_config
      The variable "CLI_MARKETPLACES[*]" should eq 'https://good.example.com/plugins'
      The stderr should include 'invalid scheme'
      The stderr should include 'ftp://bad.example.com'
    End

    It 'drops a restored profile name that no longer resolves, keeping other valid restored profiles (regression: profile-restore hard-failure on teardown commands)'
      # Root cause: unlike the marketplace-scheme validation above, the
      # profile-name restore previously had no fallback -- a restored name
      # that no longer resolves (deleted/renamed profile, or a project-local
      # profile only resolvable relative to the create-time CWD) would be
      # restored verbatim into PROFILES, and bin/profile-installer.js's
      # loadProfile() call would then die() -> process.exit(1), which
      # src/index.sh's `PROFILE_INSTALLER_OUTPUT="$(node ...)" || exit $?`
      # propagates, hard-aborting the whole invocation -- including
      # delete/clean/stop, the exact commands a user needs when an instance
      # is broken -- before CMD dispatch is ever reached. profile_exists()
      # (src/profiles.sh) is pure bash (no docker involved), so it's
      # overridden directly here per this file's convention for mocking pure-
      # bash helpers (see "parse_options() -- per-name verb-gating" above).
      SANDBOX_NAME="test"
      CONFIG_FLAGS_PROVIDED=false
      PROFILES=()
      MODE_OVERRIDE=""
      NO_ISOLATE_CONFIG=false
      CLEAN_SLATE=false
      CLI_MARKETPLACES=()
      CLI_PLUGINS=()
      CLI_ENABLE_ALL=false
      config_b64="$(encode_config '{"version":1,"profiles":["base","ghost-profile"]}')"
      docker() {
        if [ "$1" = "inspect" ]; then
          if [[ "$*" == *"ai.sandbox.config"* ]]; then
            echo "${config_b64}"
          fi
          return 0
        fi
      }
      profile_exists() { [ "$1" = "base" ]; }
      When call restore_saved_config
      The status should be success
      The variable "PROFILES[*]" should eq 'base'
      The stderr should include 'ghost-profile'
      The stderr should include 'no longer found'
    End

    It 'falls back to default profile resolution (empty PROFILES) when every restored profile is unresolvable'
      SANDBOX_NAME="test"
      CONFIG_FLAGS_PROVIDED=false
      PROFILES=()
      MODE_OVERRIDE=""
      NO_ISOLATE_CONFIG=false
      CLEAN_SLATE=false
      CLI_MARKETPLACES=()
      CLI_PLUGINS=()
      CLI_ENABLE_ALL=false
      config_b64="$(encode_config '{"version":1,"profiles":["ghost-one","ghost-two"]}')"
      docker() {
        if [ "$1" = "inspect" ]; then
          if [[ "$*" == *"ai.sandbox.config"* ]]; then
            echo "${config_b64}"
          fi
          return 0
        fi
      }
      profile_exists() { return 1; }
      When call restore_saved_config
      The status should be success
      # bash's ${arr[*]+x} existence test (which the variable subject uses
      # under the hood) treats a zero-element array the same as an unset
      # variable, so "should be undefined" -- not "should eq ''" -- is the
      # correct assertion for "PROFILES was left as the empty array it
      # started as".
      The variable "PROFILES[*]" should be undefined
      The stderr should include 'ghost-one'
      The stderr should include 'ghost-two'
    End

    It 'treats an oversized ai.sandbox.config label as absent rather than decoding it (followup qVbA)'
      # Defense-in-depth size bound: an (implausible, since the label is only
      # writable by the host process at create time) oversized label must
      # degrade to the same "nothing to restore" behavior as an absent label,
      # not error or hang attempting to base64-decode/jq-parse it.
      SANDBOX_NAME="test"
      CONFIG_FLAGS_PROVIDED=false
      PROFILES=(sentinel)
      MODE_OVERRIDE="sentinel-mode"
      NO_ISOLATE_CONFIG=false
      CLEAN_SLATE=false
      CLI_MARKETPLACES=()
      CLI_PLUGINS=()
      CLI_ENABLE_ALL=false
      oversized_b64="$(head -c 20000 /dev/zero | tr '\0' 'A')"
      docker() {
        if [ "$1" = "inspect" ]; then
          if [[ "$*" == *"ai.sandbox.config"* ]]; then
            echo "${oversized_b64}"
          fi
          return 0
        fi
      }
      When call restore_saved_config
      The status should be success
      The variable "PROFILES[*]" should eq 'sentinel'
      The variable MODE_OVERRIDE should eq sentinel-mode
    End
  End

  Describe 'running_config_matches()'
    # Builds the single sep-joined line the consolidated `docker inspect`
    # call in running_config_matches() now expects (followup 4DzF: 9
    # separate single-field calls collapsed into 1 multi-field call, later
    # extended to 10 fields for allow-egress, then to 11 for
    # static-playground). Field order matches the function's own `read`:
    # image hash mode no_isolate proxy clean marketplaces plugins enable_all
    # allow_egress static_playground. Uses the same ASCII Unit Separator
    # (0x1F) as the implementation, not tab/pipe -- see the implementation
    # comment for why. Existing callers that still pass only 9 or 10
    # positional args are unaffected: printf leaves an unset trailing %s
    # empty, which read()s into an empty trailing field -- the same default
    # AI_SANDBOX_ALLOW_EGRESS/STATIC_PLAYGROUND has when a test doesn't set
    # it.
    mock_inspect_line() {
      printf '%s\x1f%s\x1f%s\x1f%s\x1f%s\x1f%s\x1f%s\x1f%s\x1f%s\x1f%s\x1f%s\n' "$@"
    }

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
          else
            mock_inspect_line "ai-sandbox:profile-abc" "abc" "static" "false" "false" "true" "" "" ""
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
          else
            mock_inspect_line "ai-sandbox:profile-abc" "abc" "static" "false" "false" "false" "" "" ""
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
          else
            mock_inspect_line "ai-sandbox:profile-abc" "abc" "mirror" "false" "false" "false" \
              "https://example.com/registry" "claude-mem" "true"
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
          else
            mock_inspect_line "ai-sandbox:profile-abc" "abc" "mirror" "false" "false" "false" "" "" "false"
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
          else
            mock_inspect_line "ai-sandbox:profile-abc" "abc" "mirror" "false" "false" "false" "" "" "false"
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
          else
            mock_inspect_line "ai-sandbox:profile-abc" "abc" "mirror" "false" "false" "false" "" "" "false"
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
          else
            # marketplaces/plugins/enable-all-plugins fields are empty:
            # simulates a container created before these labels existed,
            # where `docker inspect` prints an empty string for missing keys.
            mock_inspect_line "ai-sandbox:profile-abc" "abc" "mirror" "false" "false" "false" "" "" ""
          fi
          return 0
        fi
      }
      When call running_config_matches
      The status should eq 0
    End

    It 'returns success when the allow-egress label matches AI_SANDBOX_ALLOW_EGRESS'
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
      AI_SANDBOX_ALLOW_EGRESS="1.2.3.4:443|api.example.com:8080"
      docker() {
        if [ "$1" = "inspect" ]; then
          if [[ "$*" == *".State.Status"* ]]; then
            echo "running"
          else
            mock_inspect_line "ai-sandbox:profile-abc" "abc" "mirror" "false" "false" "false" \
              "" "" "false" "1.2.3.4:443|api.example.com:8080"
          fi
          return 0
        fi
      }
      When call running_config_matches
      The status should eq 0
    End

    It 'returns failure when the allow-egress label disagrees with AI_SANDBOX_ALLOW_EGRESS (e.g. enter --allow-egress NEW on a container created without it)'
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
      AI_SANDBOX_ALLOW_EGRESS="1.2.3.4:443"
      docker() {
        if [ "$1" = "inspect" ]; then
          if [[ "$*" == *".State.Status"* ]]; then
            echo "running"
          else
            mock_inspect_line "ai-sandbox:profile-abc" "abc" "mirror" "false" "false" "false" "" "" "false" ""
          fi
          return 0
        fi
      }
      When call running_config_matches
      The status should eq 1
    End

    It 'returns success when the static-playground label matches STATIC_PLAYGROUND'
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
      STATIC_PLAYGROUND=true
      docker() {
        if [ "$1" = "inspect" ]; then
          if [[ "$*" == *".State.Status"* ]]; then
            echo "running"
          else
            mock_inspect_line "ai-sandbox:profile-abc" "abc" "mirror" "false" "false" "false" "" "" "false" "" "true"
          fi
          return 0
        fi
      }
      When call running_config_matches
      The status should eq 0
    End

    It 'returns failure when the static-playground label disagrees with STATIC_PLAYGROUND (e.g. enter --static-playground on a container created without it)'
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
      STATIC_PLAYGROUND=true
      docker() {
        if [ "$1" = "inspect" ]; then
          if [[ "$*" == *".State.Status"* ]]; then
            echo "running"
          else
            mock_inspect_line "ai-sandbox:profile-abc" "abc" "mirror" "false" "false" "false" "" "" "false" "" "false"
          fi
          return 0
        fi
      }
      When call running_config_matches
      The status should eq 1
    End
  End

  Describe 'parse_options()'
    # Stub docker so resolve_name_kind() treats any queried name as an
    # existing instance (SANDBOX_NAME_KIND=instance), which allows every
    # PER_INSTANCE_COMMANDS word (plus the passthrough fallback) unrestricted
    # per Phase 3.5's verb-gating. Used below by tests that exercise a
    # per-name dispatch shape with a synthetic placeholder name and aren't
    # concerned with instance-vs-profile-vs-unknown resolution specifics
    # (that end-to-end coverage is phase-04 task 002's scope) -- see
    # plan/followups.yaml entry rUS7.
    stub_name_as_instance() {
      docker() {
        if [ "$1" = "ps" ]; then
          echo "ai-sandbox-stub"
        fi
        return 0
      }
    }

    It 'defaults CMD to enter on bare invocation'
      When call parse_options
      The variable CMD should eq enter
      The variable SANDBOX_NAME should eq ''
    End

    It 'defaults CMD to ls when bare "ls" is given'
      When call parse_options ls
      The variable CMD should eq ls
      The variable SANDBOX_NAME should eq ''
    End

    It 'routes the retired "list" word through as a literal instance-name attempt'
      stub_name_as_instance
      When call parse_options list
      The variable SANDBOX_NAME should eq list
      The variable CMD should eq enter
    End

    It 'routes "instances ls" to CMD=instances-ls with empty SANDBOX_NAME'
      When call parse_options instances ls
      The variable CMD should eq instances-ls
      The variable SANDBOX_NAME should eq ''
    End

    It 'routes first arg to SANDBOX_NAME when not a global command'
      stub_name_as_instance
      When call parse_options mybox stop
      The variable SANDBOX_NAME should eq mybox
      The variable CMD should eq stop
    End

    It 'sets CMD to enter when sandbox name given with no command'
      stub_name_as_instance
      When call parse_options mybox
      The variable SANDBOX_NAME should eq mybox
      The variable CMD should eq enter
    End

    It 'routes create to CMD with sandbox name in SANDBOX_NAME'
      When call parse_options instances create mybox --profile base
      The variable CMD should eq create
      The variable SANDBOX_NAME should eq mybox
      The variable "PROFILES[*]" should eq base
    End

    It 'accumulates repeated --profile flags in order'
      When call parse_options instances create mybox --profile base --profile docker
      The variable "PROFILES[*]" should eq 'base docker'
      The variable CONFIG_FLAGS_PROVIDED should eq true
    End

    It 'sets ENTER_AFTER_CREATE from --enter on create'
      When call parse_options instances create mybox --enter
      The variable ENTER_AFTER_CREATE should eq true
    End

    It 'sets MODE_OVERRIDE from --mode'
      When call parse_options instances create mybox --mode static
      The variable MODE_OVERRIDE should eq static
      The variable CONFIG_FLAGS_PROVIDED should eq true
    End

    It 'rejects an invalid --mode value'
      When run parse_options instances create mybox --mode bogus
      The status should be failure
      The stderr should include "must be 'mirror' or 'static'"
    End

    It 'routes a bare per-instance command to CMD with empty SANDBOX_NAME'
      When call parse_options clean
      The variable CMD should eq clean
      The variable SANDBOX_NAME should eq ''
    End

    It 'no longer routes bare "status" as a recognized per-instance command word (literal instance-name fallthrough)'
      # "status" was dropped from PER_INSTANCE_COMMANDS (replaced by "detail"
      # as the sole status-report verb) and deliberately excluded from
      # RESERVED_NAMES -- see
      # phase-01-dispatch-foundation/001-rewrite-dispatch-grammar.md item 1.
      # A bare "status" therefore falls through to the ordinary per-name
      # dispatch path, same as any other literal, unreserved word.
      stub_name_as_instance
      When call parse_options status
      The variable SANDBOX_NAME should eq status
      The variable CMD should eq enter
    End

    It 'still routes <name> <cmd> correctly for per-instance commands'
      stub_name_as_instance
      When call parse_options mybox clean
      The variable SANDBOX_NAME should eq mybox
      The variable CMD should eq clean
    End

    It 'defaults CMD to enter when sandbox name is followed by flags with no command word'
      stub_name_as_instance
      When call parse_options mybox --add-marketplace file:///two --enable-plugin flow --clean
      The variable SANDBOX_NAME should eq mybox
      The variable CMD should eq enter
      The variable "CLI_MARKETPLACES[*]" should eq 'file:///two'
      The variable "CLI_PLUGINS[*]" should eq flow
      The variable CLEAN_SLATE should eq true
    End

    It 'promotes a command word found after a leading flag+value pair to CMD'
      stub_name_as_instance
      When call parse_options myname --profile x start
      The variable SANDBOX_NAME should eq myname
      The variable CMD should eq start
      The variable "PROFILES[*]" should eq x
      The variable "ARGS[*]" should not include start
    End

    It 'promotes a command word found after a leading --mode flag+value pair to CMD'
      stub_name_as_instance
      When call parse_options myname --mode static stop
      The variable SANDBOX_NAME should eq myname
      The variable CMD should eq stop
      The variable MODE_OVERRIDE should eq static
      The variable "ARGS[*]" should not include stop
    End

    It 'promotes a command word found after a leading bare --clean flag to CMD'
      stub_name_as_instance
      When call parse_options myname --clean stop
      The variable SANDBOX_NAME should eq myname
      The variable CMD should eq stop
      The variable CLEAN_SLATE should eq true
      The variable "ARGS[*]" should not include stop
    End

    It 'does not promote a second command-like bare word after the first promotion'
      stub_name_as_instance
      When call parse_options myname --profile x start stop
      The variable SANDBOX_NAME should eq myname
      The variable CMD should eq start
      The variable "ARGS[*]" should eq stop
    End

    It 'still defaults CMD to enter for a bare sandbox name with no command word (regression)'
      stub_name_as_instance
      When call parse_options mybox
      The variable SANDBOX_NAME should eq mybox
      The variable CMD should eq enter
    End

    It 'still routes <name> <cmd> with no interleaving flags correctly (regression)'
      stub_name_as_instance
      When call parse_options mybox stop
      The variable SANDBOX_NAME should eq mybox
      The variable CMD should eq stop
    End

    It 'still routes <name> <cmd> --flag value with flags after the command word (regression)'
      stub_name_as_instance
      When call parse_options mybox stop --profile x
      The variable SANDBOX_NAME should eq mybox
      The variable CMD should eq stop
      The variable "PROFILES[*]" should eq x
    End

    It 'still defaults CMD to enter when sandbox name is followed by flags with no command word (regression)'
      stub_name_as_instance
      When call parse_options mybox --add-marketplace file:///two --enable-plugin flow --clean
      The variable SANDBOX_NAME should eq mybox
      The variable CMD should eq enter
      The variable "CLI_MARKETPLACES[*]" should eq 'file:///two'
      The variable "CLI_PLUGINS[*]" should eq flow
      The variable CLEAN_SLATE should eq true
    End

    It 'errors and points to --profile docker when --docker is passed'
      When run parse_options instances create mybox --docker
      The status should be failure
      The stderr should include '--profile docker'
    End

    It 'errors and points to --profile docker when --no-docker is passed'
      When run parse_options instances create mybox --no-docker
      The status should be failure
      The stderr should include '--profile docker'
    End

    It 'errors and points to --profile chromium when --no-chromium is passed'
      When run parse_options instances create mybox --no-chromium
      The status should be failure
      The stderr should include '--profile chromium'
    End

    It 'leaves NO_ISOLATE_CONFIG false by default (isolation on)'
      When call parse_options
      The variable NO_ISOLATE_CONFIG should eq false
    End

    It 'sets NO_ISOLATE_CONFIG when --no-isolate-config is passed'
      When call parse_options instances create mybox --no-isolate-config
      The variable NO_ISOLATE_CONFIG should eq true
    End

    It 'leaves STATIC_PLAYGROUND false by default (playground isolation off)'
      When call parse_options
      The variable STATIC_PLAYGROUND should eq false
    End

    It 'sets STATIC_PLAYGROUND when --static-playground is passed'
      When call parse_options instances create mybox --static-playground
      The variable STATIC_PLAYGROUND should eq true
      The variable CONFIG_FLAGS_PROVIDED should eq true
    End

    It 'accepts --add-marketplace with https:// ref'
      When call parse_options instances create mybox --add-marketplace https://registry.example.com
      The variable "CLI_MARKETPLACES[*]" should eq 'https://registry.example.com'
      The variable CONFIG_FLAGS_PROVIDED should eq true
    End

    It 'accepts --add-marketplace with file:// ref'
      When call parse_options instances create mybox --add-marketplace file:///home/user/plugin
      The variable "CLI_MARKETPLACES[*]" should eq 'file:///home/user/plugin'
    End

    It 'rejects --add-marketplace with invalid scheme'
      When run parse_options instances create mybox --add-marketplace ftp://bad.example.com
      The status should be failure
      The stderr should include 'https:// or file://'
    End

    It 'errors when --add-marketplace is given no ref'
      When run parse_options instances create mybox --add-marketplace
      The status should be failure
      The stderr should include '--add-marketplace requires'
    End

    It 'accumulates repeated --add-marketplace refs in order'
      When call parse_options instances create mybox \
        --add-marketplace https://one.example.com \
        --add-marketplace file:///two
      The variable "CLI_MARKETPLACES[*]" should eq 'https://one.example.com file:///two'
    End

    It 'accepts --allow-egress with an IPv4:port spec'
      When call parse_options instances create mybox --allow-egress 1.2.3.4:443
      The variable "CLI_ALLOW_EGRESS[*]" should eq '1.2.3.4:443'
      The variable CONFIG_FLAGS_PROVIDED should eq true
    End

    It 'accepts --allow-egress with an IPv4 CIDR:port spec'
      When call parse_options instances create mybox --allow-egress 10.0.0.0/8:8080
      The variable "CLI_ALLOW_EGRESS[*]" should eq '10.0.0.0/8:8080'
    End

    It 'accepts --allow-egress with a hostname:port spec'
      When call parse_options instances create mybox --allow-egress api.example.com:443
      The variable "CLI_ALLOW_EGRESS[*]" should eq 'api.example.com:443'
    End

    It 'errors when --allow-egress is given no spec'
      When run parse_options instances create mybox --allow-egress
      The status should be failure
      The stderr should include '--allow-egress requires'
    End

    It 'rejects --allow-egress with no colon'
      When run parse_options instances create mybox --allow-egress 1.2.3.4
      The status should be failure
      The stderr should include 'exactly one'
    End

    It 'rejects --allow-egress with more than one colon (e.g. an unbracketed IPv6 literal)'
      When run parse_options instances create mybox --allow-egress ::1:443
      The status should be failure
      The stderr should include 'exactly one'
    End

    It 'rejects --allow-egress with an out-of-range port'
      When run parse_options instances create mybox --allow-egress 1.2.3.4:70000
      The status should be failure
      The stderr should include 'port must be an integer 1-65535'
    End

    It 'rejects --allow-egress with a non-numeric port'
      When run parse_options instances create mybox --allow-egress 1.2.3.4:abc
      The status should be failure
      The stderr should include 'port must be an integer 1-65535'
    End

    It 'rejects --allow-egress with a malformed host part'
      When run parse_options instances create mybox --allow-egress 'bad host!:443'
      The status should be failure
      The stderr should include 'host part must be'
    End

    It 'rejects --allow-egress with an out-of-range IPv4 octet'
      When run parse_options instances create mybox --allow-egress 999.1.1.1:443
      The status should be failure
      The stderr should include 'host part must be'
    End

    It 'rejects --allow-egress with a trailing-dot IPv4 literal (bash read -a silently drops the resulting empty trailing field)'
      When run parse_options instances create mybox --allow-egress 1.2.3.4.:443
      The status should be failure
      The stderr should include 'host part must be'
    End

    It 'rejects --allow-egress with a trailing-dot IPv4 address in a CIDR'
      When run parse_options instances create mybox --allow-egress 1.2.3.4./24:443
      The status should be failure
      The stderr should include 'host part must be'
    End

    It 'accumulates repeated --allow-egress specs in order'
      When call parse_options instances create mybox \
        --allow-egress 1.2.3.4:443 \
        --allow-egress api.example.com:8080
      The variable "CLI_ALLOW_EGRESS[*]" should eq '1.2.3.4:443 api.example.com:8080'
    End

    It 'accepts --enable-plugin and sets CLI_PLUGINS'
      When call parse_options instances create mybox --enable-plugin flow
      The variable "CLI_PLUGINS[*]" should eq flow
      The variable CONFIG_FLAGS_PROVIDED should eq true
    End

    It 'accumulates repeated --enable-plugin names'
      When call parse_options instances create mybox --enable-plugin flow --enable-plugin claude-mem
      The variable "CLI_PLUGINS[*]" should eq 'flow claude-mem'
    End

    It 'sets CLI_ENABLE_ALL from --enable-all'
      When call parse_options instances create mybox --enable-all
      The variable CLI_ENABLE_ALL should eq true
      The variable CONFIG_FLAGS_PROVIDED should eq true
    End

    It 'errors when --enable-plugin is given no name'
      When run parse_options instances create mybox --enable-plugin
      The status should be failure
      The stderr should include '--enable-plugin requires'
    End

    It 'CLI_ENABLE_ALL defaults to false when --enable-all is absent'
      When call parse_options instances create mybox
      The variable CLI_ENABLE_ALL should eq false
    End

    It '--clean sets CLEAN_SLATE to true'
      When call parse_options instances create mybox --clean
      The variable CLEAN_SLATE should eq true
    End

    It '--clean sets CONFIG_FLAGS_PROVIDED to true'
      When call parse_options instances create mybox --clean
      The variable CONFIG_FLAGS_PROVIDED should eq true
    End

    It 'CLEAN_SLATE defaults to false when --clean is absent'
      When call parse_options instances create mybox
      The variable CLEAN_SLATE should eq false
    End

    It '--clean can be combined with --add-marketplace and --enable-all'
      When call parse_options instances create mybox --clean \
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
      When run parse_options instances create flow.rook
      The status should be failure
      The stderr should include 'invalid'
    End

    It 'rejects an uppercase sandbox name'
      When run parse_options FlowRook
      The status should be failure
      The stderr should include 'invalid'
    End

    It 'accepts a valid sandbox name with hyphens, underscores, and digits'
      stub_name_as_instance
      When call parse_options flow-rook_2
      The variable SANDBOX_NAME should eq 'flow-rook_2'
      The variable CMD should eq enter
    End

    # Regression coverage for the RESERVED_NAMES drift bug: RESERVED_NAMES is
    # derived from the live GLOBAL_COMMANDS/PER_INSTANCE_COMMANDS/NOUN_WORDS/
    # EXTRA_RESERVED_WORDS tables (compute_reserved_names()) rather than a
    # hand-maintained literal, so every word actually reachable as a command
    # is automatically reserved -- and, just as importantly, a word that was
    # retired or never added isn't incorrectly reserved. The invocation shape
    # is "instances create <name>" -- the sole surviving create path; bare
    # "create <name>" was retired (see the flag-parsing tests above, all of
    # which now invoke "instances create" as well).
    It 'rejects "instances create enter" because enter is a reserved name'
      When run parse_options instances create enter
      The status should be failure
      The stderr should include 'reserved name'
      The stderr should include 'enter'
    End

    It 'rejects "instances create start" because start is a reserved name'
      When run parse_options instances create start
      The status should be failure
      The stderr should include 'reserved name'
      The stderr should include 'start'
    End

    It 'rejects "instances create up" because up is a reserved name'
      When run parse_options instances create up
      The status should be failure
      The stderr should include 'reserved name'
      The stderr should include 'up'
    End

    It 'rejects "instances create ls" because ls is a reserved name'
      When run parse_options instances create ls
      The status should be failure
      The stderr should include 'reserved name'
      The stderr should include 'ls'
    End

    It 'rejects "instances create instances" because instances is a reserved name'
      When run parse_options instances create instances
      The status should be failure
      The stderr should include 'reserved name'
      The stderr should include 'instances'
    End

    It 'rejects "instances create profiles" because profiles is a reserved name'
      When run parse_options instances create profiles
      The status should be failure
      The stderr should include 'reserved name'
      The stderr should include 'profiles'
    End

    It 'rejects "instances create create" because create is a reserved name'
      When run parse_options instances create create
      The status should be failure
      The stderr should include 'reserved name'
      The stderr should include 'create'
    End

    It 'rejects "instances create detail" because detail is a reserved name'
      When run parse_options instances create detail
      The status should be failure
      The stderr should include 'reserved name'
      The stderr should include 'detail'
    End

    It 'no longer rejects "instances create status" -- status was deliberately excluded from RESERVED_NAMES'
      # Cross-checked against src/options.sh: GLOBAL_COMMANDS/
      # PER_INSTANCE_COMMANDS/NOUN_WORDS/EXTRA_RESERVED_WORDS none contain
      # "status" -- see phase-01-dispatch-foundation/001-rewrite-dispatch-
      # grammar.md item 1 for why. This is the other half of the drift-bug
      # regression: proving the derived set doesn't over-reserve either.
      When call parse_options instances create status
      The variable SANDBOX_NAME should eq status
      The variable CMD should eq create
    End

    It 'no longer rejects "instances create list" -- list was retired as a command word but never re-added to RESERVED_NAMES (only "ls" is reserved)'
      When call parse_options instances create list
      The variable SANDBOX_NAME should eq list
      The variable CMD should eq create
    End

    It 'still accepts a legitimate non-reserved name via instances create'
      When call parse_options instances create mybox
      The variable SANDBOX_NAME should eq mybox
      The variable CMD should eq create
    End

    It 'parses the bare "detail" word directly to CMD=detail (no normalization)'
      When call parse_options detail
      The variable CMD should eq detail
      The variable SANDBOX_NAME should eq ''
    End

    It 'parses "<name> detail" directly to CMD=detail (no normalization)'
      stub_name_as_instance
      When call parse_options myname detail
      The variable CMD should eq detail
      The variable SANDBOX_NAME should eq myname
    End

    It 'defaults QUIET=0 for CMD=detail'
      QUIET=
      When call parse_options detail
      The variable CMD should eq detail
      The variable QUIET should eq 0
    End

    It 'no longer routes bare "connect" as a recognized per-instance command word (falls through as CMD, same as any other bare word after a name)'
      # "connect" was dropped entirely (not aliased) -- it isn't in
      # PER_INSTANCE_COMMANDS. parse_options() doesn't gate the word
      # immediately following a resolved sandbox name against
      # PER_INSTANCE_COMMANDS at all; it simply assigns it to CMD (mirroring
      # the existing "<name> down" passthrough pattern exercised end-to-end
      # in the "command dispatch: exec/passthrough branches" Describe block
      # below) and leaves recognizing/rejecting it to src/index.sh's
      # dispatch chain.
      stub_name_as_instance
      When call parse_options mybox connect
      The variable SANDBOX_NAME should eq mybox
      The variable CMD should eq connect
    End

    It 'still produces CMD=attach for "<name> attach" (unchanged spelling)'
      stub_name_as_instance
      When call parse_options mybox attach
      The variable SANDBOX_NAME should eq mybox
      The variable CMD should eq attach
    End
  End

  Describe 'parse_options() — instances noun'
    # "instances ls" -> CMD=instances-ls (with empty SANDBOX_NAME) is already
    # covered by the 'routes "instances ls" to CMD=instances-ls...' It block
    # in the 'parse_options()' Describe block above (added by phase-04 task
    # 001). This block adds the previously-uncovered combined-flags
    # "instances create" shape per this task's Requirement 1 -- mirrors the
    # individual --profile/--mode flag-parsing tests above, but asserts both
    # flags threaded through together in a single end-to-end invocation.
    It 'parses "instances create <name> --profile <p> --mode <m>" end-to-end'
      When call parse_options instances create foo --profile base --mode static
      The variable CMD should eq create
      The variable SANDBOX_NAME should eq foo
      The variable "PROFILES[*]" should eq base
      The variable MODE_OVERRIDE should eq static
    End
  End

  Describe 'parse_options() — profiles noun'
    # profiles ls / profiles create <name> end-to-end parse behavior --
    # phase-01-dispatch-foundation/001 established the CMD-namespacing
    # pattern ("instances-ls"); phase-02-profiles-resource/001 applied the
    # same pattern to profiles ("profiles-ls"/"profiles-create") since bare
    # CMD="ls"/"create" are already contractually tied to
    # do_list()/do_create(). Profile deletion ("<name> delete") is NOT a
    # noun-level verb (see plan/notes/profiles-delete-ambiguity.md) -- it's
    # covered by the 'parse_options() — per-name verb-gating' Describe block
    # below instead.
    It 'routes "profiles ls" to CMD=profiles-ls with empty SANDBOX_NAME (profiles-only listing)'
      When call parse_options profiles ls
      The variable CMD should eq profiles-ls
      The variable SANDBOX_NAME should eq ''
    End

    It 'parses "profiles create <name> --mode <m>" end-to-end'
      When call parse_options profiles create bar --mode mirror
      The variable CMD should eq profiles-create
      The variable SANDBOX_NAME should eq bar
      The variable MODE_OVERRIDE should eq mirror
    End
  End

  Describe 'compute_reserved_names() — structural derivation'
    # Requirement 3 (drift-can't-happen-again guarantee): prove RESERVED_NAMES
    # is *derived from* the live command tables via compute_reserved_names()
    # at parse time, not a hand-maintained literal that happens to match
    # today's tables -- see plan/notes/current-dispatch-audit.md's "Confirmed
    # table contents" section for the original drift bug this replaces. The
    # 'rejects "instances create <word>"...' tests in the 'parse_options()'
    # Describe block above already re-assert today's known reserved words;
    # this block instead exercises the derivation mechanism itself.
    It 'echoes the union of its four input tables verbatim'
      When call compute_reserved_names 'a b' 'c d' 'e' 'f g'
      The output should eq 'a b c d e f g'
    End

    It 'parse_options() consumes whatever compute_reserved_names() returns -- injecting a synthetic word makes it reserved automatically, with no other change'
      # Overriding compute_reserved_names() itself (rather than adding
      # another known-word assertion) proves parse_options() actually calls
      # through the derivation function at parse time instead of inlining a
      # snapshot of its result -- i.e. a future addition to any underlying
      # table is automatically reserved without a second, hand-maintained edit.
      compute_reserved_names() { echo "$1 $2 $3 $4 totallynotreal"; }
      When run parse_options instances create totallynotreal
      The status should be failure
      The stderr should include 'reserved name'
      The stderr should include 'totallynotreal'
    End
  End

  Describe 'parse_options() — per-name verb-gating (resolve_name_kind())'
    # Mirrors the 'parse_options()' Describe block's stub_name_as_instance()
    # docker-mocking convention for the other two resolve_name_kind()
    # outcomes. profile_exists() is pure bash (no docker involved), so it's
    # overridden directly here per this file's convention for pure-bash
    # helpers (see the header comment on this file re: function mocking).
    stub_name_as_profile() {
      docker() { return 0; }
      profile_exists() { return 0; }
    }
    stub_name_as_unknown() {
      docker() { return 0; }
      profile_exists() { return 1; }
    }

    It 'allows CMD=detail for a name that resolves to a profile'
      stub_name_as_profile
      When call parse_options myprofile detail
      The variable CMD should eq detail
      The variable SANDBOX_NAME should eq myprofile
      The variable SANDBOX_NAME_KIND should eq profile
    End

    It 'allows CMD=delete for a name that resolves to a profile (the sole profile-deletion spelling; see plan/notes/profiles-delete-ambiguity.md)'
      stub_name_as_profile
      When call parse_options myprofile delete
      The variable CMD should eq delete
      The variable SANDBOX_NAME_KIND should eq profile
    End

    It 'rejects an instance-only verb (enter) against a name that resolves to a profile, with a distinct "is a profile, not an instance" error'
      stub_name_as_profile
      When run parse_options myprofile enter
      The status should be failure
      The stderr should include "is a profile, not an instance"
      The stderr should include 'myprofile'
    End

    It 'rejects a bare name (default CMD=enter) that resolves to a profile, since "enter" is not a profile-appropriate verb'
      stub_name_as_profile
      When run parse_options myprofile
      The status should be failure
      The stderr should include "is a profile, not an instance"
    End

    It 'rejects any verb against a name that resolves to neither an instance nor a profile ("unknown"), with a distinct error'
      stub_name_as_unknown
      When run parse_options ghostname detail
      The status should be failure
      The stderr should include 'is not a known instance or profile'
      The stderr should not include 'is a profile, not an instance'
      The stderr should not include 'reserved name'
    End

    It 'rejects a bare unresolvable name with no verb ("unknown"), same distinct error'
      stub_name_as_unknown
      When run parse_options ghostname
      The status should be failure
      The stderr should include 'is not a known instance or profile'
    End
  End

  Describe 'do_status() — Configuration: display (ai.sandbox.config label decode)'
    # Helper: base64-encode a config-input JSON payload exactly as
    # src/index.sh's assembly block does, mirroring the restore_saved_config()
    # tests' mocking style for the same label.
    encode_config() {
      printf '%s' "$1" | base64 | tr -d '\n'
    }

    setup() {
      SANDBOX_NAME="test"
      STATUS_JSON=false
      STATUS_TEST_CHECK=false
      AI_SANDBOX_SKIP_PLUGIN_CHECK=1
    }
    Before 'setup'

    It 'renders a Configuration: section as decoded YAML when the label is present (human output)'
      # Shadow `yq` with a deterministic stand-in for the kislyuk/yq `-y .`
      # invocation so this test doesn't depend on whichever `yq` (if any --
      # kislyuk vs. mikefarah are incompatible) happens to be on the
      # test-runner's PATH; it exercises the YAML-rendering branch of
      # _render_config_section() rather than the real binary.
      yq() {
        echo "version: 1"
        echo "mode: static"
        echo 'profiles:'
        echo '- base'
      }
      config_b64="$(encode_config '{"version":1,"mode":"static","profiles":["base"]}')"
      docker() {
        if [ "$1" = "inspect" ]; then
          if [[ "$*" == *"ai.sandbox.config"* ]]; then
            echo "${config_b64}"
          elif [[ "$*" == *"State.Status"* ]]; then
            echo "running"
          fi
          return 0
        fi
        return 0
      }
      When call do_status
      The output should include 'Configuration:'
      The output should include 'mode: static'
    End

    It 'omits the Configuration: section entirely when the label is absent (human output)'
      docker() {
        if [ "$1" = "inspect" ]; then
          # ai.sandbox.config label absent -- docker inspect prints an empty line.
          if [[ "$*" == *"State.Status"* ]]; then
            echo "running"
          fi
          return 0
        fi
        return 0
      }
      When call do_status
      The output should not include 'Configuration:'
    End

    It 'still renders Configuration: for a stopped container with a persisted label (docker inspect works on stopped containers)'
      # Shadow `yq` deterministically (see the analogous comment above) so
      # this test doesn't depend on the test-runner's PATH having a
      # kislyuk/yq-compatible `yq` installed.
      yq() {
        echo "version: 1"
        echo "mode: mirror"
      }
      config_b64="$(encode_config '{"version":1,"mode":"mirror"}')"
      docker() {
        if [ "$1" = "inspect" ]; then
          if [[ "$*" == *"ai.sandbox.config"* ]]; then
            echo "${config_b64}"
          elif [[ "$*" == *"State.Status"* ]]; then
            echo "exited"
          fi
          return 0
        fi
        return 0
      }
      When call do_status
      The output should include 'Container: stopped'
      The output should include 'Configuration:'
      The output should include 'mode: mirror'
    End

    It 'includes a config key with the decoded object in --json output when the label is present'
      STATUS_JSON=true
      config_b64="$(encode_config '{"version":1,"mode":"static"}')"
      docker() {
        if [ "$1" = "inspect" ]; then
          if [[ "$*" == *"ai.sandbox.config"* ]]; then
            echo "${config_b64}"
          elif [[ "$*" == *"State.Status"* ]]; then
            echo "running"
          fi
          return 0
        fi
        return 0
      }
      When call do_status
      The output should include '"config"'
      The output should include '"mode": "static"'
    End

    It 'includes config: null in --json output when the label is absent'
      STATUS_JSON=true
      docker() {
        if [ "$1" = "inspect" ]; then
          if [[ "$*" == *"State.Status"* ]]; then
            echo "running"
          fi
          return 0
        fi
        return 0
      }
      When call do_status
      The output should include '"config": null'
    End

    It 'falls back to pretty-printed JSON via jq when yq is unavailable or the wrong variant (human output)'
      # Shadow the `yq` command with a function that fails, simulating both
      # "not on PATH" and "wrong variant" (mikefarah/yq would similarly fail
      # or misbehave on the kislyuk-specific `-y .` invocation). `command -v`
      # resolves shell functions too, so this exercises the same
      # `command -v yq` gate the implementation uses.
      yq() { return 1; }
      config_b64="$(encode_config '{"version":1,"mode":"static"}')"
      docker() {
        if [ "$1" = "inspect" ]; then
          if [[ "$*" == *"ai.sandbox.config"* ]]; then
            echo "${config_b64}"
          elif [[ "$*" == *"State.Status"* ]]; then
            echo "running"
          fi
          return 0
        fi
        return 0
      }
      When call do_status
      The output should include 'Configuration:'
      The output should include '"mode": "static"'
    End

    It 'omits the Configuration: section for an oversized ai.sandbox.config label rather than erroring (followup qVbA)'
      oversized_b64="$(head -c 20000 /dev/zero | tr '\0' 'A')"
      docker() {
        if [ "$1" = "inspect" ]; then
          if [[ "$*" == *"ai.sandbox.config"* ]]; then
            echo "${oversized_b64}"
          elif [[ "$*" == *"State.Status"* ]]; then
            echo "running"
          fi
          return 0
        fi
        return 0
      }
      When call do_status
      The status should be success
      The output should not include 'Configuration:'
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

    It 'does not add a redundant read-only mount for a path already under HOME/playground'
      mkdir -p "${HOME}/playground/my-repo"
      export AI_SANDBOX_MARKETPLACES="file://${HOME}/playground/my-repo"
      When call generate_volume_override "${OUT}"
      The contents of file "${OUT}" should not include "${HOME}/playground/my-repo:${HOME}/playground/my-repo:ro"
      The status should be success
    End
  End

  Describe 'generate_volume_override() volume-maps skip-guard' unit
    # Task 003 fix: the ${HOME}/playground skip-guard previously only
    # covered the file:// marketplace block above -- the user_maps loop
    # (~/.config/ai-sandbox/volume-maps entries) had no such guard, so an
    # entry resolving under ${HOME}/playground would double-mount and, with
    # --static-playground active, get silently shadowed by the overlay mount
    # applied afterward. This exact case was previously untested even for
    # the marketplace path (see the design note); the marketplace half is
    # now covered by the "does not add a redundant read-only mount..."
    # example above, so this block adds the volume-maps half.
    setup() {
      export TMPDIR_VM="$(mktemp -d)"
      export HOME="${TMPDIR_VM}"
      export OUT="${TMPDIR_VM}/compose-override.yaml"
      mkdir -p "${HOME}/.config/ai-sandbox"
      unset AI_SANDBOX_MARKETPLACES
      unset AI_SANDBOX_CLEAN_SLATE
    }
    cleanup() {
      rm -rf "${TMPDIR_VM}"
    }
    Before 'setup'
    After 'cleanup'

    It 'does not add a mount for a volume-maps entry that resolves under HOME/playground'
      # shellcheck disable=SC2016 # literal $HOME written to the volume-maps
      # file on purpose -- generate_volume_override()'s own eval expands it
      # against the test's HOME at read time, mirroring real user input.
      printf '%s\n' '$HOME/playground/my-repo' > "${HOME}/.config/ai-sandbox/volume-maps"
      When call generate_volume_override "${OUT}"
      The contents of file "${OUT}" should not include "${HOME}/playground/my-repo:${HOME}/playground/my-repo"
      The status should be success
    End

    It 'adds a mount for a volume-maps entry outside HOME/playground'
      # shellcheck disable=SC2016 # literal $HOME written to the volume-maps
      # file on purpose -- generate_volume_override()'s own eval expands it
      # against the test's HOME at read time, mirroring real user input.
      printf '%s\n' '$HOME/other-dir' > "${HOME}/.config/ai-sandbox/volume-maps"
      When call generate_volume_override "${OUT}"
      The contents of file "${OUT}" should include "${HOME}/other-dir:${HOME}/other-dir"
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

  Describe 'assemble-dockerfile.sh (docker/scripts)'
    # Regression for the false-positive rebuild bug: assemble-dockerfile.sh
    # used to unconditionally overwrite OUTPUT_PATH on every run (`cat ... >
    # "${OUTPUT_PATH}"`), bumping its mtime even when the assembled content
    # was byte-identical to what was already on disk. is_build_stale()
    # treats an assembled Dockerfile newer than the image as a rebuild
    # trigger, so every command after the first falsely reported "Build
    # inputs changed" and rebuilt. Assert the script now leaves the output
    # file's inode untouched (i.e. skips the replace) on a second run with
    # unchanged inputs, and does replace it when inputs actually change.
    ASSEMBLE_SCRIPT="$PWD/docker/scripts/assemble-dockerfile.sh"

    # Prints the inode number of a single, already-known file path (not a
    # glob), so SC2012's "use find instead of ls" concern about
    # non-alphanumeric filename handling in a listing doesn't apply here.
    # shellcheck disable=SC2012 # single known path, not a directory listing
    file_inode() {
      ls -i "$1" | awk '{print $1}'
    }

    setup() {
      export OUT_DIR="$(mktemp -d)"
      export OUT_FILE="${OUT_DIR}/Dockerfile.test"
    }
    cleanup() {
      rm -rf "${OUT_DIR}"
    }
    Before 'setup'
    After 'cleanup'

    It 'leaves the output file inode unchanged on a second run with identical inputs'
      # First run happens outside `When` (only one Evaluation is allowed per
      # Example); the assertion below exercises the second, idempotent run.
      "${ASSEMBLE_SCRIPT}" "" "${OUT_FILE}" > /dev/null
      first_inode="$(file_inode "${OUT_FILE}")"
      export first_inode

      When run script "${ASSEMBLE_SCRIPT}" "" "${OUT_FILE}"
      The status should be success
      The output should include 'Assembled Dockerfile written to:'
      second_inode="$(file_inode "${OUT_FILE}")"
      The variable first_inode should eq "${second_inode}"
    End

    It 'still replaces the output file when inputs change (e.g. a different --hash)'
      "${ASSEMBLE_SCRIPT}" --hash aaaa1111 "" "${OUT_FILE}" > /dev/null

      When run script "${ASSEMBLE_SCRIPT}" --hash bbbb2222 "" "${OUT_FILE}"
      The status should be success
      The output should include 'Assembled Dockerfile written to:'
      The contents of file "${OUT_FILE}" should include 'bbbb2222'
      The contents of file "${OUT_FILE}" should not include 'aaaa1111'
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

  Describe 'fix_ssh()'
    It 'scopes the recreate to the current compose project (regression: missing -p flag)'
      # Without -p "${COMPOSE_PROJECT}", the recreate resolves against
      # Compose's default project-name derivation instead of the named
      # instance's actual project scope -- the same class of bug the
      # start_shell() regression test above already caught and fixed for exec.
      SANDBOX_NAME="test"
      COMPOSE_FILES="-f docker-compose.yaml"
      COMPOSE_PROJECT="ai-sandbox-flow-rook"
      SSH_AUTH_SOCK="/tmp/agent.sock"
      QUIET=1
      ssh_preflight() { return 0; }
      docker() {
        case "$1" in
          compose) printf '%s\n' "$*" ;;
        esac
      }
      When call fix_ssh
      The output should include 'compose -p ai-sandbox-flow-rook -f docker-compose.yaml up -d --force-recreate --no-deps ai-sandbox'
    End
  End

  Describe 'profiles_create()'
    # Renamed/rewritten from new_profile() (phase-02-profiles-resource task
    # 001, "Build Profiles Module"): the auto-discovery scaffolding logic is
    # unchanged in substance, but the name-input mechanism changed from the
    # --name flag to a positional <name> argument (symmetric with
    # `instances create <name>`). See src/profiles.sh.
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
      # Docker is stubbed unreachable so the instance-collision check
      # (instance_exists(), which shells out to `docker ps -a`) resolves
      # deterministically to "no such instance" without depending on a real
      # docker daemon being available/running.
      docker() { return 1; }
      When call profiles_create t --output "${output_file}"
      The output should include 'Created profile:'
      The path "${output_file}" should be exist
      The status should be success
    End

    It 'errors when the name is missing'
      When run profiles_create "" --output /tmp/nope.yaml
      The status should be failure
      The stderr should include 'a profile name is required'
    End

    It 'errors when the name contains a path separator'
      When run profiles_create bad/name --output /tmp/nope.yaml
      The status should be failure
      The stderr should include "no '/' allowed"
    End
  End

  Describe 'profiles_create() — name-collision checks'
    # Requirement 4: a create-collision check must reject a name colliding
    # with an existing instance, an existing profile, or a reserved word
    # (reserved-word coverage already lives in the 'parse_options()' Describe
    # block's "rejects ... because ... is a reserved name" tests -- not
    # duplicated here). This block covers profiles_create()'s own two
    # collision checks directly, including the profiles-create/existing-
    # instance cross-kind case.
    setup() {
      export TMPDIR_PC="$(mktemp -d)"
      export HOME="${TMPDIR_PC}"
    }
    cleanup() {
      rm -rf "${TMPDIR_PC}"
    }
    Before 'setup'
    After 'cleanup'

    It 'rejects "profiles create <name>" when <name> collides with an existing instance (cross-kind)'
      docker() { if [ "$1" = "ps" ]; then echo "ai-sandbox-existing"; fi; return 0; }
      When run profiles_create existing --output "${TMPDIR_PC}/nope.yaml"
      The status should be failure
      The stderr should include 'already exists as a sandbox instance'
    End

    It 'rejects "profiles create <name>" when <name> collides with an existing profile (same-kind)'
      docker() { return 1; }
      profile_exists() { return 0; }
      When run profiles_create existing --output "${TMPDIR_PC}/nope.yaml"
      The status should be failure
      The stderr should include 'already exists. Choose a different name'
    End
  End

  Describe 'do_create() — name-collision checks'
    # Symmetric coverage for the "instances create" side of Requirement 4:
    # do_create()'s own two collision checks (src/create.sh), including the
    # instances-create/existing-profile cross-kind case. Both examples return
    # before do_create() reaches ensure_image()/docker compose, so no real
    # image build or container is touched.
    It 'rejects "instances create <name>" when <name> collides with an existing instance (same-kind)'
      SANDBOX_NAME="existing"
      docker() { if [ "$1" = "ps" ]; then echo "ai-sandbox-existing"; fi; return 0; }
      When run do_create
      The status should be failure
      The stderr should include 'already exists'
      The stderr should include "ai-sandbox existing start"
    End

    It 'rejects "instances create <name>" when <name> collides with an existing profile (cross-kind)'
      SANDBOX_NAME="existing"
      docker() { return 1; }
      profile_exists() { return 0; }
      When run do_create
      The status should be failure
      The stderr should include 'already exists as a profile'
    End
  End

  Describe 'profiles_delete()'
    # Deletion is exclusively "ai-sandbox <name> delete" (resolved via
    # resolve_name_kind()'s per-name dispatch path, see the 'parse_options()
    # — per-name verb-gating' Describe block above for the CMD=delete
    # parse-level coverage), never a "profiles delete <name>" noun-level
    # command -- see plan/notes/profiles-delete-ambiguity.md. This block
    # covers profiles_delete() itself (src/profiles.sh), including the
    # bundled/read-only refusal from profiles-resource task 002 Requirement 3.
    setup() {
      export PD_WORK_DIR="$(mktemp -d)"
      export PD_ORIG_PWD="${PWD}"
      export XDG_CONFIG_HOME="${PD_WORK_DIR}/xdg-config"
      mkdir -p "${PD_WORK_DIR}/cwd"
      cd "${PD_WORK_DIR}/cwd" || exit
    }
    cleanup() {
      cd "${PD_ORIG_PWD}" || exit
      rm -rf "${PD_WORK_DIR}"
    }
    Before 'setup'
    After 'cleanup'

    It 'refuses to delete a bundled profile, naming the bundled path'
      # No project-local (isolated empty cwd) or user-global (isolated
      # XDG_CONFIG_HOME) "base.yaml" shadows the real bundled profile, so
      # this deterministically resolves to the bundled copy shipped in this
      # repo's own profiles/ directory.
      When run profiles_delete base
      The status should be failure
      The stderr should include 'bundled profile'
      The stderr should include 'cannot be deleted'
      The stderr should include 'profiles/base.yaml'
    End

    It 'deletes a user-global profile and confirms removal'
      mkdir -p "${XDG_CONFIG_HOME}/ai-sandbox/profiles"
      target="${XDG_CONFIG_HOME}/ai-sandbox/profiles/testdel.yaml"
      echo 'mode: mirror' > "${target}"
      When call profiles_delete testdel
      The output should include 'Deleted profile:'
      The path "${target}" should not be exist
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
      QUIET=0
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
      QUIET=0
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

  Describe 'command dispatch: exec/passthrough branches with empty ARGS (regression: unbound variable under set -u)'
    # The user-exec/root-exec/generic-passthrough branches live in src/index.sh's
    # top-level command-dispatch chain, which only runs when the script is
    # executed as a process -- `Include`-based sourcing (used by every other
    # example in this file) short-circuits at `${__SOURCED__:+return}` before
    # reaching it. So these run the real built bin/ai-sandbox.sh via `When run
    # script`, invoked by path (not `bash bin/ai-sandbox.sh`) so its own
    # `#!/bin/bash` shebang resolves to the system bash -- 3.2 on macOS, the
    # version whose `set -u` throws "unbound variable" on `"${ARGS[@]}"` when
    # ARGS has zero elements. `docker` is stubbed on PATH; every other tool
    # invoked along the way (node profile-installer.js, jq, assemble-dockerfile.sh,
    # git) is real and side-effect-free (no network, no containers).
    setup() {
      DISPATCH_WORK_DIR="$(mktemp -d)"
      export XDG_CACHE_HOME="${DISPATCH_WORK_DIR}/cache"
      DISPATCH_MOCK_BIN="${DISPATCH_WORK_DIR}/mockbin"
      mkdir -p "${DISPATCH_MOCK_BIN}"
      DISPATCH_DOCKER_LOG="${DISPATCH_WORK_DIR}/docker_calls.log"
      : > "${DISPATCH_DOCKER_LOG}"
      export DISPATCH_DOCKER_LOG
      cat > "${DISPATCH_MOCK_BIN}/docker" <<'MOCK_DOCKER'
#!/bin/bash
printf '%s\n' "$*" >> "${DISPATCH_DOCKER_LOG}"
case "$1" in
  info) exit 0 ;;
  inspect) exit 1 ;;
  # resolve_name_kind()'s instance_exists() check queries `docker ps -a
  # --filter name=^ai-sandbox-<name>$ --format {{.Names}}`; echo the
  # matching container name so "dispatchtest" resolves as SANDBOX_NAME_KIND=
  # instance and Phase 3.5's verb-gating doesn't reject it (see
  # plan/followups.yaml entry rUS7).
  ps) echo "ai-sandbox-dispatchtest"; exit 0 ;;
  *) exit 0 ;;
esac
MOCK_DOCKER
      chmod +x "${DISPATCH_MOCK_BIN}/docker"
      export PATH="${DISPATCH_MOCK_BIN}:${PATH}"
      export AI_SANDBOX_SKIP_PLUGIN_CHECK=1
    }
    cleanup() {
      rm -rf "${DISPATCH_WORK_DIR}"
    }
    Before 'setup'
    After 'cleanup'

    It 'dispatches the generic passthrough branch without an unbound-variable error when no extra ARGS are given (regression: bare "<name> down")'
      When run script "$PWD/bin/ai-sandbox.sh" dispatchtest down
      The status should be success
      The output should eq ''
      The stderr should not include 'unbound variable'
      The contents of file "${DISPATCH_DOCKER_LOG}" should include 'compose -p ai-sandbox-dispatchtest'
    End

    It 'dispatches user-exec without an unbound-variable error when no trailing command args are given'
      When run script "$PWD/bin/ai-sandbox.sh" dispatchtest user-exec
      The status should be success
      The output should eq ''
      The stderr should not include 'unbound variable'
      The contents of file "${DISPATCH_DOCKER_LOG}" should include 'exec -u'
    End

    It 'dispatches root-exec without an unbound-variable error when no trailing command args are given'
      When run script "$PWD/bin/ai-sandbox.sh" dispatchtest root-exec
      The status should be success
      The output should eq ''
      The stderr should not include 'unbound variable'
      The contents of file "${DISPATCH_DOCKER_LOG}" should include 'exec -u root ai-sandbox'
    End

    It 'still forwards trailing ARGS to user-exec unchanged (regression: the empty-array guard must not break the non-empty case)'
      When run script "$PWD/bin/ai-sandbox.sh" dispatchtest user-exec echo hi
      The status should be success
      The output should eq ''
      The contents of file "${DISPATCH_DOCKER_LOG}" should include 'exec -u'
      The contents of file "${DISPATCH_DOCKER_LOG}" should include 'ai-sandbox echo hi'
    End

    It 'still forwards trailing ARGS to root-exec unchanged (regression: the empty-array guard must not break the non-empty case)'
      When run script "$PWD/bin/ai-sandbox.sh" dispatchtest root-exec echo hi
      The status should be success
      The output should eq ''
      The contents of file "${DISPATCH_DOCKER_LOG}" should include 'exec -u root ai-sandbox echo hi'
    End
  End

  Describe 'command dispatch: teardown commands survive an unresolvable restored profile (regression: profile-restore hard-failure on teardown commands)'
    # End-to-end regression coverage for task doc requirement 1
    # (plan/phase-01-fix-orphaned-sidecar-teardown/002-fix-review-regressions.md):
    # the graceful-degradation fix lives in restore_saved_config()'s runtime
    # call to profile_exists()/PROFILE_JSON assembly, which only fully
    # exercises end to end when the real bin/profile-installer.js gets
    # invoked with the (now-filtered) PROFILES array -- so this runs the real
    # built script via `When run script`, same convention and rationale as
    # the "command dispatch: exec/passthrough branches" Describe block above.
    # `docker inspect ... ai.sandbox.config` is mocked to return a persisted
    # config recording a profile name ("ghost-profile") that does not exist
    # anywhere under this repo's real profiles/ tree -- simulating a profile
    # that was valid at `create` time but has since been deleted/renamed.
    # Without the fix, bin/profile-installer.js's loadProfile() would die()
    # on "ghost-profile" and src/index.sh's `|| exit $?` would abort before
    # CMD dispatch, so `delete` would never reach `docker compose ... down`.
    setup() {
      DISPATCH_WORK_DIR="$(mktemp -d)"
      export XDG_CACHE_HOME="${DISPATCH_WORK_DIR}/cache"
      DISPATCH_MOCK_BIN="${DISPATCH_WORK_DIR}/mockbin"
      mkdir -p "${DISPATCH_MOCK_BIN}"
      DISPATCH_DOCKER_LOG="${DISPATCH_WORK_DIR}/docker_calls.log"
      : > "${DISPATCH_DOCKER_LOG}"
      export DISPATCH_DOCKER_LOG
      # Persisted ai.sandbox.config label: profiles=["ghost-profile"], a name
      # that does not resolve to any file under ./profiles,
      # ${XDG_CONFIG_HOME:-$HOME/.config}/ai-sandbox/profiles, or this repo's
      # bundled profiles/ dir.
      config_json='{"version":1,"profiles":["ghost-profile"],"mode":"","no_isolate_config":false,"clean_slate":false,"marketplaces":[],"plugins":[],"enable_all_plugins":false}'
      config_b64="$(printf '%s' "${config_json}" | base64 | tr -d '\n')"
      export DISPATCH_CONFIG_B64="${config_b64}"
      cat > "${DISPATCH_MOCK_BIN}/docker" <<'MOCK_DOCKER'
#!/bin/bash
printf '%s\n' "$*" >> "${DISPATCH_DOCKER_LOG}"
case "$1" in
  info) exit 0 ;;
  ps) echo "ai-sandbox-dispatchtest"; exit 0 ;;
  inspect)
    if [[ "$*" == *"ai.sandbox.config"* ]]; then
      echo "${DISPATCH_CONFIG_B64}"
    elif [[ "$*" == *"State.Status"* ]]; then
      # Reported as exited (not running) so delete/stop/clean skip the
      # interactive confirm_stop_running() prompt.
      echo "exited"
    fi
    exit 0
    ;;
  *) exit 0 ;;
esac
MOCK_DOCKER
      chmod +x "${DISPATCH_MOCK_BIN}/docker"
      export PATH="${DISPATCH_MOCK_BIN}:${PATH}"
      export AI_SANDBOX_SKIP_PLUGIN_CHECK=1
    }
    cleanup() {
      rm -rf "${DISPATCH_WORK_DIR}"
    }
    Before 'setup'
    After 'cleanup'

    It 'lets delete (no --profile flag) succeed with a warning instead of hard-aborting on an unresolvable restored profile'
      When run script "$PWD/bin/ai-sandbox.sh" dispatchtest delete
      The status should be success
      The stderr should include "dropping restored profile 'ghost-profile'"
      The output should include "deleted"
      The contents of file "${DISPATCH_DOCKER_LOG}" should include 'compose -p ai-sandbox-dispatchtest'
      The contents of file "${DISPATCH_DOCKER_LOG}" should include ' down'
    End

    It 'lets stop (no --profile flag) succeed with a warning instead of hard-aborting on an unresolvable restored profile'
      When run script "$PWD/bin/ai-sandbox.sh" dispatchtest stop
      The status should be success
      The stderr should include "dropping restored profile 'ghost-profile'"
      The output should include "stopped"
      The contents of file "${DISPATCH_DOCKER_LOG}" should include 'compose -p ai-sandbox-dispatchtest'
      The contents of file "${DISPATCH_DOCKER_LOG}" should include ' stop'
    End

    It 'lets clean (no --profile flag) succeed with a warning instead of hard-aborting on an unresolvable restored profile'
      When run script "$PWD/bin/ai-sandbox.sh" dispatchtest clean
      The status should be success
      The output should include 'confirmed.'
      The stderr should include "dropping restored profile 'ghost-profile'"
      The contents of file "${DISPATCH_DOCKER_LOG}" should include 'compose -p ai-sandbox-dispatchtest'
      The contents of file "${DISPATCH_DOCKER_LOG}" should include ' down'
    End
  End

  Describe 'command dispatch: dropped custom profile that provided the docker capability does not orphan the sidecar (regression: EFFECTIVE_PROXY label fallback, phase-01/003)'
    # End-to-end regression coverage for task doc requirement 1
    # (plan/phase-01-fix-orphaned-sidecar-teardown/003-fix-capability-loss-on-profile-drop.md).
    # Same setup as the "teardown commands survive an unresolvable restored
    # profile" Describe block above (restore_saved_config() drops
    # "ghost-profile", falling back to the default [base, mirror]
    # composition, which has no docker capability), but here the container's
    # persisted ai.sandbox.docker-proxy label is also mocked as "true" --
    # recording that the instance *was* created with the docker capability
    # via that now-unresolvable profile. Without this task's fix,
    # EFFECTIVE_PROXY silently recomputes to false and COMPOSE_FILES omits
    # docker-compose.proxy.yaml, leaving the docker-socket-proxy sidecar
    # orphaned (delete/clean) or left running (stop) -- the same bug class
    # task 001 fixed, reintroduced in this narrower scenario.
    setup() {
      DISPATCH_WORK_DIR="$(mktemp -d)"
      export XDG_CACHE_HOME="${DISPATCH_WORK_DIR}/cache"
      DISPATCH_MOCK_BIN="${DISPATCH_WORK_DIR}/mockbin"
      mkdir -p "${DISPATCH_MOCK_BIN}"
      DISPATCH_DOCKER_LOG="${DISPATCH_WORK_DIR}/docker_calls.log"
      : > "${DISPATCH_DOCKER_LOG}"
      export DISPATCH_DOCKER_LOG
      # Persisted ai.sandbox.config label: profiles=["ghost-profile"], a name
      # that does not resolve to any file under ./profiles,
      # ${XDG_CONFIG_HOME:-$HOME/.config}/ai-sandbox/profiles, or this repo's
      # bundled profiles/ dir -- so it gets dropped, and PROFILES falls back
      # to the default [base, mirror] composition (no docker capability).
      config_json='{"version":1,"profiles":["ghost-profile"],"mode":"","no_isolate_config":false,"clean_slate":false,"marketplaces":[],"plugins":[],"enable_all_plugins":false}'
      config_b64="$(printf '%s' "${config_json}" | base64 | tr -d '\n')"
      export DISPATCH_CONFIG_B64="${config_b64}"
      cat > "${DISPATCH_MOCK_BIN}/docker" <<'MOCK_DOCKER'
#!/bin/bash
printf '%s\n' "$*" >> "${DISPATCH_DOCKER_LOG}"
case "$1" in
  info) exit 0 ;;
  ps) echo "ai-sandbox-dispatchtest"; exit 0 ;;
  inspect)
    if [[ "$*" == *"ai.sandbox.config"* ]]; then
      echo "${DISPATCH_CONFIG_B64}"
    elif [[ "$*" == *"docker-proxy"* ]]; then
      # Instance was created with the docker capability (via the
      # now-dropped "ghost-profile"); the label persists independent of
      # whether that profile still resolves.
      echo "true"
    elif [[ "$*" == *"State.Status"* ]]; then
      # Reported as exited (not running) so delete/stop/clean skip the
      # interactive confirm_stop_running() prompt.
      echo "exited"
    fi
    exit 0
    ;;
  *) exit 0 ;;
esac
MOCK_DOCKER
      chmod +x "${DISPATCH_MOCK_BIN}/docker"
      export PATH="${DISPATCH_MOCK_BIN}:${PATH}"
      export AI_SANDBOX_SKIP_PLUGIN_CHECK=1
    }
    cleanup() {
      rm -rf "${DISPATCH_WORK_DIR}"
    }
    Before 'setup'
    After 'cleanup'

    It 'includes docker-compose.proxy.yaml in the down call for delete (no --profile flag) despite the dropped profile'
      When run script "$PWD/bin/ai-sandbox.sh" dispatchtest delete
      The status should be success
      The stderr should include "dropping restored profile 'ghost-profile'"
      The output should include "deleted"
      The contents of file "${DISPATCH_DOCKER_LOG}" should include 'compose -p ai-sandbox-dispatchtest'
      The contents of file "${DISPATCH_DOCKER_LOG}" should include 'docker-compose.proxy.yaml'
      The contents of file "${DISPATCH_DOCKER_LOG}" should include ' down'
    End

    It 'includes docker-compose.proxy.yaml in the stop call for stop (no --profile flag) despite the dropped profile'
      When run script "$PWD/bin/ai-sandbox.sh" dispatchtest stop
      The status should be success
      The stderr should include "dropping restored profile 'ghost-profile'"
      The output should include "stopped"
      The contents of file "${DISPATCH_DOCKER_LOG}" should include 'compose -p ai-sandbox-dispatchtest'
      The contents of file "${DISPATCH_DOCKER_LOG}" should include 'docker-compose.proxy.yaml'
      The contents of file "${DISPATCH_DOCKER_LOG}" should include ' stop'
    End

    It 'includes docker-compose.proxy.yaml in the down call for clean (no --profile flag) despite the dropped profile'
      When run script "$PWD/bin/ai-sandbox.sh" dispatchtest clean
      The status should be success
      The output should include 'confirmed.'
      The stderr should include "dropping restored profile 'ghost-profile'"
      The contents of file "${DISPATCH_DOCKER_LOG}" should include 'compose -p ai-sandbox-dispatchtest'
      The contents of file "${DISPATCH_DOCKER_LOG}" should include 'docker-compose.proxy.yaml'
      The contents of file "${DISPATCH_DOCKER_LOG}" should include ' down'
    End
  End

  Describe 'command dispatch: fix-ssh on a clean-slate instance preserves credentials across --force-recreate (regression: fix-ssh clean-slate credential loss)'
    # End-to-end regression coverage for task doc requirement 2
    # (plan/phase-01-fix-orphaned-sidecar-teardown/002-fix-review-regressions.md):
    # the fix lives in src/index.sh's credential-snapshot CMD guard (inline
    # top-level script logic, not a function), so -- same rationale as the
    # other end-to-end Describe blocks in this file -- this runs the real
    # built bin/ai-sandbox.sh via `When run script`.
    #
    # `docker inspect ... ai.sandbox.config` is mocked to return a persisted
    # config recording clean_slate=true (as `create --clean` would save), so
    # restore_saved_config() sets CLEAN_SLATE=true for a bare `fix-ssh` (no
    # --clean flag this run) exactly as should_restore_config()'s broadened
    # trigger (task 001) intends. `security` is shadowed to always fail so
    # the test never touches the real host Keychain; ensure_clean_slate_
    # credentials() then falls back to a fake ~/.claude/.credentials.json
    # planted under a throwaway HOME. `ssh_preflight()`'s SSH_AUTH_SOCK check
    # needs a real, live-but-protocol-silent UNIX socket (a plain `-S` file
    # test isn't enough: ssh-add -l against a dead/unbound socket path exits
    # 2, which fix_ssh() treats as fatal) -- a background Python listener
    # provides one without speaking the ssh-agent protocol (ssh-add exits 1,
    # "communication with agent failed", which ssh_preflight() tolerates).
    #
    # Without the fix, AI_SANDBOX_CREDENTIALS_JSON_B64 is never populated for
    # fix-ssh, so COMPOSE_FILES omits docker-compose.claude-auth.yaml (and,
    # since CLEAN_SLATE=true also skips docker-compose.mirror-claude.yaml),
    # leaving --force-recreate with no credential source at all.
    setup() {
      DISPATCH_WORK_DIR="$(mktemp -d)"
      export XDG_CACHE_HOME="${DISPATCH_WORK_DIR}/cache"
      DISPATCH_MOCK_BIN="${DISPATCH_WORK_DIR}/mockbin"
      mkdir -p "${DISPATCH_MOCK_BIN}"
      DISPATCH_DOCKER_LOG="${DISPATCH_WORK_DIR}/docker_calls.log"
      : > "${DISPATCH_DOCKER_LOG}"
      export DISPATCH_DOCKER_LOG
      config_json='{"version":1,"profiles":[],"mode":"","no_isolate_config":false,"clean_slate":true,"marketplaces":[],"plugins":[],"enable_all_plugins":false}'
      config_b64="$(printf '%s' "${config_json}" | base64 | tr -d '\n')"
      export DISPATCH_CONFIG_B64="${config_b64}"
      cat > "${DISPATCH_MOCK_BIN}/docker" <<'MOCK_DOCKER'
#!/bin/bash
printf '%s\n' "$*" >> "${DISPATCH_DOCKER_LOG}"
case "$1" in
  info) exit 0 ;;
  ps) echo "ai-sandbox-dispatchtest"; exit 0 ;;
  inspect)
    if [[ "$*" == *"ai.sandbox.config"* ]]; then
      echo "${DISPATCH_CONFIG_B64}"
    fi
    exit 0
    ;;
  *) exit 0 ;;
esac
MOCK_DOCKER
      chmod +x "${DISPATCH_MOCK_BIN}/docker"
      # Shadow `security` so the test never reads the real host Keychain.
      cat > "${DISPATCH_MOCK_BIN}/security" <<'MOCK_SECURITY'
#!/bin/bash
exit 1
MOCK_SECURITY
      chmod +x "${DISPATCH_MOCK_BIN}/security"
      export PATH="${DISPATCH_MOCK_BIN}:${PATH}"
      export AI_SANDBOX_SKIP_PLUGIN_CHECK=1

      DISPATCH_FAKE_HOME="${DISPATCH_WORK_DIR}/home"
      mkdir -p "${DISPATCH_FAKE_HOME}/.claude"
      printf '%s' '{"claudeAiOauth":{"accessToken":"file-tok","refreshToken":"file-ref","expiresAt":9999999999000}}' \
        > "${DISPATCH_FAKE_HOME}/.claude/.credentials.json"
      export HOME="${DISPATCH_FAKE_HOME}"

      DISPATCH_SSH_SOCK="${DISPATCH_WORK_DIR}/agent.sock"
      python3 -c "
import socket, time
s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
s.bind('${DISPATCH_SSH_SOCK}')
s.listen(1)
time.sleep(30)
" &
      DISPATCH_SSH_LISTENER_PID=$!
      # Give the listener a moment to bind before the script under test runs.
      sleep 0.3
      export SSH_AUTH_SOCK="${DISPATCH_SSH_SOCK}"
    }
    cleanup() {
      kill "${DISPATCH_SSH_LISTENER_PID}" 2>/dev/null || true
      rm -rf "${DISPATCH_WORK_DIR}"
    }
    Before 'setup'
    After 'cleanup'

    It 'includes docker-compose.claude-auth.yaml in the force-recreate compose call so credentials survive'
      When run script "$PWD/bin/ai-sandbox.sh" dispatchtest fix-ssh
      The status should be success
      The output should include 'Container recreated with SSH_AUTH_SOCK='
      The contents of file "${DISPATCH_DOCKER_LOG}" should include 'docker-compose.claude-auth.yaml'
      The contents of file "${DISPATCH_DOCKER_LOG}" should include 'force-recreate'
    End
  End
End
