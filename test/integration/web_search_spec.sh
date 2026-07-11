# shellcheck shell=bash
# shellcheck disable=SC2016 # we want unexpanded shell expressions sent into the container
#
# Coordinated with 001-add-dynamic-firewall-mechanism-and-web-search.md:
# confirms the web-search capability's AI_SANDBOX_WEB_SEARCH iptables chain
# actually grants port-443 egress to public (non-private) IPv4 hosts when
# --profile web-search is active, that the capability is strictly opt-in (no
# broadened access on a plain default-posture container), that the chain's
# RFC-reserved/private-range exclusions hold even with the capability active,
# and that the capability is scoped to port 443 only.
#
# Flag placement follows README.md's documented `ai-sandbox start --profile
# <name> ...` form (command word first, then flags) -- see
# network_allow_spec.sh's note on the pre-existing flag-order parsing bug
# for why docker_proxy_spec.sh's `--profile <name> start` form is avoided here.
Describe 'web-search capability (--profile web-search)' integration
  # 1.1.1.1 is a well-known public (non-private) IPv4 host not on the
  # default allow-list (github.com / Anthropic API hosts), matching the task
  # doc's suggested test-safe target.
  public_host='1.1.1.1'
  # Guaranteed-inert address inside the 10.0.0.0/8 RFC 1918 range the
  # AI_SANDBOX_WEB_SEARCH chain RETURNs on -- not a real host, so a probe
  # here can only be blocked by the firewall, never coincidentally succeed
  # via some route on the test runner's own network.
  private_host='10.255.255.1'

  Describe 'with --profile web-search active'
    start_with_web_search() {
      ./bin/ai-sandbox.sh start --profile web-search --quiet 2> ./.ai-sandbox.web-search.startup.log || {
        cat ./.ai-sandbox.web-search.startup.log 1>&2
        echo "Container (with --profile web-search) failed to become ready" 1>&2
        return 1
      }
      return 0
    }
    stop_with_web_search() {
      ./bin/ai-sandbox.sh stop --profile web-search --quiet 2>/dev/null || true
    }

    BeforeAll 'start_with_web_search'
    AfterAll 'stop_with_web_search'

    It 'reaches a public non-private host on port 443'
      Skip if 'network probe opted out via AI_SANDBOX_SKIP_EGRESS_NET' [ -n "${AI_SANDBOX_SKIP_EGRESS_NET:-}" ]
      When call ./bin/ai-sandbox.sh --quiet user-exec zsh -c "curl -sS --max-time 5 -o /dev/null -w '%{http_code}' https://${public_host}"
      The status should be success
      # A real 3-digit HTTP status (as opposed to curl's '000' no-connection
      # sentinel) proves the TLS handshake and HTTP round-trip both
      # completed -- true reachability, not just "curl didn't error". Glob
      # wildcards on both ends: `user-exec`'s own "Checking docker is
      # running... confirmed." preamble line precedes the curl output in the
      # captured multi-line stdout.
      The output should match pattern '*[1-5][0-9][0-9]*'
    End

    It 'still blocks a private-range destination even though web-search is active'
      Skip if 'network probe opted out via AI_SANDBOX_SKIP_EGRESS_NET' [ -n "${AI_SANDBOX_SKIP_EGRESS_NET:-}" ]
      When call ./bin/ai-sandbox.sh --quiet user-exec zsh -c "curl -sS --max-time 5 -o /dev/null -w '%{http_code}' https://${private_host}"
      The status should not be success
    End

    It 'still blocks a non-443 port to an otherwise-web-search-allowed public host'
      Skip if 'network probe opted out via AI_SANDBOX_SKIP_EGRESS_NET' [ -n "${AI_SANDBOX_SKIP_EGRESS_NET:-}" ]
      When call ./bin/ai-sandbox.sh --quiet user-exec zsh -c "curl -sS --max-time 5 -o /dev/null -w '%{http_code}' http://${public_host}"
      The status should not be success
    End
  End

  Describe 'without --profile web-search (default posture)'
    # Explicit `--profile base` (rather than a bare `start --quiet`) is
    # required here, not just for symmetry with the block above: src/utils.sh
    # restore_saved_config() persists the *previous* invocation's profile
    # set on this named instance's container label and re-applies it whenever
    # start/enter is called with no config-changing flags at all. Since the
    # 'with --profile web-search active' block above just ran --profile
    # web-search on this same default (unnamed) instance, a flag-less
    # `start --quiet` here would silently restore --profile web-search
    # instead of reverting to the default composition -- defeating the
    # opt-in check this block exists to make. Passing --profile explicitly
    # (even naming the ordinary default profile) sets
    # CONFIG_FLAGS_PROVIDED=true and skips that restore path entirely.
    start_default() {
      ./bin/ai-sandbox.sh start --profile base --quiet 2> ./.ai-sandbox.web-search-off.startup.log || {
        cat ./.ai-sandbox.web-search-off.startup.log 1>&2
        echo "Container (without --profile web-search) failed to become ready" 1>&2
        return 1
      }
      return 0
    }
    stop_default() {
      ./bin/ai-sandbox.sh stop --profile base --quiet 2>/dev/null || true
    }

    BeforeAll 'start_default'
    AfterAll 'stop_default'

    It 'does not reach the public host that web-search made reachable above (capability is opt-in)'
      Skip if 'network probe opted out via AI_SANDBOX_SKIP_EGRESS_NET' [ -n "${AI_SANDBOX_SKIP_EGRESS_NET:-}" ]
      When call ./bin/ai-sandbox.sh --quiet user-exec zsh -c "curl -sS --max-time 5 -o /dev/null -w '%{http_code}' https://${public_host}"
      The status should not be success
    End
  End
End
