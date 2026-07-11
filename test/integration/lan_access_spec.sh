# shellcheck shell=bash
# shellcheck disable=SC2016 # we want unexpanded shell expressions sent into the container
#
# Coordinated with 005-add-lan-access-capability.md: confirms
# AI_SANDBOX_LAN_CIDR is correctly populated inside the container when
# --profile lan-access is active (compared against an independent host-side
# computation of the same value via compute_lan_cidr()), that a destination
# clearly outside the detected LAN CIDR remains blocked even with lan-access
# active, that reachability to an actual second LAN host succeeds when the
# test runner opts in via AI_SANDBOX_LAN_TEST_TARGET, and that the
# capability is strictly opt-in (no AI_SANDBOX_LAN_CIDR / no LAN reachability
# on a plain default-posture container).
#
# Flag placement follows the command-word-first form (`start --profile
# lan-access --quiet`) -- see network_allow_spec.sh's note on the
# pre-existing flag-order parsing bug that makes docker_proxy_spec.sh's
# `--profile <name> start` form unusable outside that file's own workaround.
Describe 'lan-access capability (--profile lan-access)' integration
  # A public IP address well outside any RFC1918 LAN range and already
  # covered as a "clearly outside the LAN" destination by other specs (see
  # web_search_spec.sh's public_host) -- guaranteed not to fall inside
  # whatever CIDR compute_lan_cidr() detects for the test-runner host.
  outside_lan_host='1.1.1.1'

  Describe 'with --profile lan-access active'
    # Source ./bin/ai-sandbox.sh as a library purely to reuse its
    # already-unit-tested compute_lan_cidr() helper (same technique
    # test/unit/ai_sandbox_spec.sh uses via `Include`; test/spec_helper.sh
    # exports __SOURCED__=1 so this short-circuits before any top-level
    # command dispatch). This spec process runs on the same host as the
    # container it starts below, so an independent call to compute_lan_cidr()
    # here yields the same value src/index.sh will have computed and exported
    # into the container's environment -- giving Requirement 2's "compare
    # against a host-side computation of the expected CIDR" an actual
    # independent computation rather than a hard-coded/duplicated literal.
    Include "$PWD/bin/ai-sandbox.sh"
    expected_lan_cidr="$(compute_lan_cidr 2>/dev/null)"

    start_with_lan_access() {
      ./bin/ai-sandbox.sh start --profile lan-access --quiet 2> ./.ai-sandbox.lan-access.startup.log || {
        cat ./.ai-sandbox.lan-access.startup.log 1>&2
        echo "Container (with --profile lan-access) failed to become ready" 1>&2
        return 1
      }
      return 0
    }
    stop_with_lan_access() {
      ./bin/ai-sandbox.sh stop --profile lan-access --quiet 2>/dev/null || true
    }

    BeforeAll 'start_with_lan_access'
    AfterAll 'stop_with_lan_access'

    It 'exports AI_SANDBOX_LAN_CIDR matching the host-side computed LAN CIDR'
      Skip if 'host-side LAN CIDR detection did not resolve on this test runner (nothing to compare against)' [ -z "${expected_lan_cidr}" ]
      When call ./bin/ai-sandbox.sh --quiet user-exec zsh -c 'echo $AI_SANDBOX_LAN_CIDR'
      # 'include' (not 'equal'/'eq'): --quiet does not suppress user-exec's
      # own "Checking docker is running... confirmed." preamble line, which
      # precedes the echoed value in the captured multi-line stdout -- same
      # pre-existing behavior web_search_spec.sh's public_host test documents.
      The output should include "${expected_lan_cidr}"
      The status should be success
    End

    It 'still blocks a destination clearly outside the detected LAN CIDR'
      Skip if 'network probe opted out via AI_SANDBOX_SKIP_EGRESS_NET' [ -n "${AI_SANDBOX_SKIP_EGRESS_NET:-}" ]
      When call ./bin/ai-sandbox.sh --quiet user-exec zsh -c "curl -sS --max-time 5 -o /dev/null -w '%{http_code}' https://${outside_lan_host}"
      The status should not be success
    End

    It 'reaches an actual second LAN host when opted in via AI_SANDBOX_LAN_TEST_TARGET'
      # Strongest possible assertion (real LAN-peer reachability), but it
      # depends on test-environment topology -- a LAN peer is not always
      # available (e.g. CI runners), so this is opt-in only: unset
      # AI_SANDBOX_LAN_TEST_TARGET=<ip>:<port> skips this specific assertion
      # rather than assuming a peer exists, consistent with the
      # AI_SANDBOX_SKIP_EGRESS_NET precedent from Phase 1 Task 001 (see that
      # task's doc for the pattern this extends).
      Skip if 'no AI_SANDBOX_LAN_TEST_TARGET=<ip>:<port> opt-in set (no known-reachable LAN peer to test against)' [ -z "${AI_SANDBOX_LAN_TEST_TARGET:-}" ]
      # Safe (":-"-guarded) expansion of the source var, not just the Skip if
      # condition above: under this file's `set -u` execution, `Skip if`
      # marks the example skipped but does not itself halt evaluation of the
      # remaining statements in this block, so an unguarded
      # "${AI_SANDBOX_LAN_TEST_TARGET%%:*}" would still abort with "unbound
      # variable" on a run where the opt-in var is unset.
      lan_target="${AI_SANDBOX_LAN_TEST_TARGET:-}"
      lan_target_host="${lan_target%%:*}"
      lan_target_port="${lan_target##*:}"
      # lan-access allows all TCP ports (not just 443), and netcat is not
      # installed in the image, so a raw TCP connect via bash's /dev/tcp
      # (wrapped in `timeout` to bound worst-case latency) is used instead of
      # an HTTP/TLS-specific probe like curl -- it works against any
      # listening TCP service on the target, not just a web server.
      When call ./bin/ai-sandbox.sh --quiet user-exec bash -c "timeout 5 bash -c 'exec 3<>/dev/tcp/${lan_target_host}/${lan_target_port}' 2>/dev/null"
      The status should be success
    End
  End

  Describe 'without --profile lan-access (default posture)'
    # Explicit `--profile base` (rather than a bare `start --quiet`) is
    # required here, not just for symmetry with the block above: src/utils.sh
    # restore_saved_config() persists the *previous* invocation's profile
    # set on this named instance's container label and re-applies it whenever
    # start/enter is called with no config-changing flags at all. Since the
    # 'with --profile lan-access active' block above just ran --profile
    # lan-access on this same default (unnamed) instance, a flag-less
    # `start --quiet` here would silently restore --profile lan-access
    # instead of reverting to the default composition -- defeating the
    # opt-in check this block exists to make. Passing --profile explicitly
    # (even naming the ordinary default profile) sets
    # CONFIG_FLAGS_PROVIDED=true and skips that restore path entirely (see
    # web_search_spec.sh's identical note for this same-instance precedent).
    start_default() {
      ./bin/ai-sandbox.sh start --profile base --quiet 2> ./.ai-sandbox.lan-access-off.startup.log || {
        cat ./.ai-sandbox.lan-access-off.startup.log 1>&2
        echo "Container (without --profile lan-access) failed to become ready" 1>&2
        return 1
      }
      return 0
    }
    stop_default() {
      ./bin/ai-sandbox.sh stop --profile base --quiet 2>/dev/null || true
    }

    BeforeAll 'start_default'
    AfterAll 'stop_default'

    It 'has no AI_SANDBOX_LAN_CIDR set (capability is opt-in)'
      When call ./bin/ai-sandbox.sh --quiet user-exec zsh -c 'echo "[$AI_SANDBOX_LAN_CIDR]"'
      The output should include '[]'
    End

    It 'still blocks the destination outside the LAN CIDR that the lan-access block probed above'
      Skip if 'network probe opted out via AI_SANDBOX_SKIP_EGRESS_NET' [ -n "${AI_SANDBOX_SKIP_EGRESS_NET:-}" ]
      When call ./bin/ai-sandbox.sh --quiet user-exec zsh -c "curl -sS --max-time 5 -o /dev/null -w '%{http_code}' https://${outside_lan_host}"
      The status should not be success
    End

    It 'does not reach the LAN peer that lan-access made reachable above (capability is opt-in)'
      Skip if 'no AI_SANDBOX_LAN_TEST_TARGET=<ip>:<port> opt-in set (no known-reachable LAN peer to test against)' [ -z "${AI_SANDBOX_LAN_TEST_TARGET:-}" ]
      # See the mirrored "reaches an actual second LAN host..." test above
      # for why this uses a ":-"-guarded expansion rather than referencing
      # AI_SANDBOX_LAN_TEST_TARGET directly.
      lan_target="${AI_SANDBOX_LAN_TEST_TARGET:-}"
      lan_target_host="${lan_target%%:*}"
      lan_target_port="${lan_target##*:}"
      When call ./bin/ai-sandbox.sh --quiet user-exec bash -c "timeout 5 bash -c 'exec 3<>/dev/tcp/${lan_target_host}/${lan_target_port}' 2>/dev/null"
      The status should not be success
    End
  End
End
