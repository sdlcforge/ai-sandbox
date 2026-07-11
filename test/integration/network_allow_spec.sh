# shellcheck shell=bash
# shellcheck disable=SC2016 # we want unexpanded shell expressions sent into the container
#
# Coordinated with 003-wire-profile-and-marketplace-allowlist.md: confirms
# that a profile's `network.allow` entries and `--add-marketplace` hosts
# (other than github.com/anthropic.com) are actually reachable through the
# default-deny firewall Task 002 wired up, and that hosts outside both
# allow-lists remain blocked -- i.e. this task's wiring is additive, not a
# hole in default-deny.
#
# Flag placement note: the command word comes first, then `--profile` /
# `--add-marketplace`, e.g. `start --profile na-test --quiet` -- matching
# README.md's documented `ai-sandbox start --profile base --profile docker`
# form. Flags placed *before* the command word (the form
# docker_proxy_spec.sh uses) currently make src/options.sh misparse the
# first flag as the sandbox name; see this task's own report for the
# pre-existing-bug writeup (out of this task's file scope to fix).
Describe 'network.allow / marketplace-derived firewall rules' integration
  Describe 'profile network.allow' integration
    # Inject a throwaway profile via XDG_CONFIG_HOME (same technique
    # test/unit/ai_sandbox_spec.sh's profiles_delete() coverage uses) rather
    # than adding a fixture into the shipped ./profiles/ directory -- keeps
    # this test profile out of the real profile search path for every other
    # user/invocation.
    na_test_dir="$(mktemp -d)"
    na_profile="na-integration-test"

    setup_profile() {
      export XDG_CONFIG_HOME="${na_test_dir}"
      mkdir -p "${XDG_CONFIG_HOME}/ai-sandbox/profiles"
      cat > "${XDG_CONFIG_HOME}/ai-sandbox/profiles/${na_profile}.yaml" <<'EOF'
metadata:
  name: na-integration-test
  version: "1.0.0"
network:
  allow:
    - example.com
EOF
    }
    start_na_container() {
      ./bin/ai-sandbox.sh start --profile base --profile mirror --profile "${na_profile}" \
        --quiet 2> ./.ai-sandbox.na.startup.log || {
        cat ./.ai-sandbox.na.startup.log 1>&2
        echo "Container (with --profile ${na_profile}) failed to become ready" 1>&2
        return 1
      }
      return 0
    }
    stop_na_container() {
      ./bin/ai-sandbox.sh stop --profile base --profile mirror --profile "${na_profile}" \
        --quiet 2>/dev/null || true
    }
    cleanup_na_profile() {
      rm -rf "${na_test_dir}"
    }

    BeforeAll 'setup_profile'
    BeforeAll 'start_na_container'
    AfterAll 'stop_na_container'
    AfterAll 'cleanup_na_profile'

    It 'reaches a network.allow-listed host on port 443'
      Skip if 'network probe opted out via AI_SANDBOX_SKIP_EGRESS_NET' [ -n "${AI_SANDBOX_SKIP_EGRESS_NET:-}" ]
      When call ./bin/ai-sandbox.sh user-exec --profile base --profile mirror --profile "${na_profile}" \
        --quiet zsh -c "curl -sS --max-time 5 -o /dev/null -w '%{http_code}' https://example.com"
      The output should include '200'
      The status should be success
    End

    It 'still blocks a host that is not in network.allow'
      Skip if 'network probe opted out via AI_SANDBOX_SKIP_EGRESS_NET' [ -n "${AI_SANDBOX_SKIP_EGRESS_NET:-}" ]
      When call ./bin/ai-sandbox.sh user-exec --profile base --profile mirror --profile "${na_profile}" \
        --quiet zsh -c "curl -sS --max-time 5 -o /dev/null -w '%{http_code}' https://example.org"
      The status should not be success
    End
  End

  Describe '--add-marketplace host' integration
    # example.net is not a real Claude Code marketplace; that's fine here --
    # 10-plugin-setup's marketplace registration is non-fatal
    # (docker/rootfs/etc/cont-init.d/10-plugin-setup warns and continues on a
    # failed `claude plugins marketplace add`), and the task's own Validation
    # section treats reachability, not registration success, as the bar for
    # this test.
    mp_ref='https://example.net/plugin-marketplace.json'

    start_mp_container() {
      ./bin/ai-sandbox.sh start --add-marketplace "${mp_ref}" \
        --quiet 2> ./.ai-sandbox.mp.startup.log || {
        cat ./.ai-sandbox.mp.startup.log 1>&2
        echo "Container (with --add-marketplace ${mp_ref}) failed to become ready" 1>&2
        return 1
      }
      return 0
    }
    stop_mp_container() {
      ./bin/ai-sandbox.sh stop --add-marketplace "${mp_ref}" --quiet 2>/dev/null || true
    }

    BeforeAll 'start_mp_container'
    AfterAll 'stop_mp_container'

    It 'reaches the --add-marketplace host on port 443'
      Skip if 'network probe opted out via AI_SANDBOX_SKIP_EGRESS_NET' [ -n "${AI_SANDBOX_SKIP_EGRESS_NET:-}" ]
      When call ./bin/ai-sandbox.sh user-exec --add-marketplace "${mp_ref}" \
        --quiet zsh -c "curl -sS --max-time 5 -o /dev/null -w '%{http_code}' https://example.net"
      The output should include '200'
      The status should be success
    End

    It 'still blocks a host that is neither default-allowed nor the marketplace host'
      Skip if 'network probe opted out via AI_SANDBOX_SKIP_EGRESS_NET' [ -n "${AI_SANDBOX_SKIP_EGRESS_NET:-}" ]
      When call ./bin/ai-sandbox.sh user-exec --add-marketplace "${mp_ref}" \
        --quiet zsh -c "curl -sS --max-time 5 -o /dev/null -w '%{http_code}' https://example.org"
      The status should not be success
    End
  End
End
