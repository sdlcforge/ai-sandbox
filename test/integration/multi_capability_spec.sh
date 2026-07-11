# shellcheck shell=bash
# shellcheck disable=SC2016 # we want unexpanded shell expressions sent into the container
#
# Coordinated with 007-fix-capability-ifs-word-splitting.md: none of
# web_search_spec.sh / host_access_spec.sh / lan_access_spec.sh activate more
# than one network capability at a time, so none of them could have caught
# docker/init-firewall.sh's file-wide `IFS=$'\n\t'` breaking the
# space-separated word-splitting the capability-dispatch loop (and the
# host-access per-port loop) rely on -- the exact gap this task closes. This
# spec activates two network capabilities together (`--profile web-search
# --profile host-access`) and asserts BOTH capabilities' rules are actually
# present/functional, not just that the container starts: against the
# pre-fix code, AI_SANDBOX_CAPABILITIES arrives as the single un-split token
# "web-search host-access", matches no `case` pattern, and neither
# capability's rules get installed -- both assertions below would fail.
#
# Flag placement follows README.md's documented `ai-sandbox start --profile
# <name1> --profile <name2> ...` form (command word first, then flags,
# multiple --profile flags merged left to right) -- see
# network_allow_spec.sh's note on the pre-existing flag-order parsing bug for
# why docker_proxy_spec.sh's `--profile <name> start` form is avoided here.
Describe 'multiple simultaneous network capabilities (--profile web-search --profile host-access)' integration
  # Distinct from host_access_spec.sh's ports so this spec can run
  # independently of (and in either order relative to) that file without any
  # risk of a stale listener/pidfile collision.
  listen_port=18952
  listener_pidfile="./.ai-sandbox.multi-capability-listener.pid"
  # Same well-known public (non-private) IPv4 host web_search_spec.sh probes.
  public_host='1.1.1.1'

  start_host_listener() {
    # `-k`: keep accepting connections after each one completes. Output is
    # discarded; only the socket being open/closed matters for this probe.
    nc -kl "${listen_port}" >/dev/null 2>&1 &
    listener_pid=$!
    disown
    echo "${listener_pid}" > "${listener_pidfile}"
  }
  stop_host_listener() {
    # Guards against a leaked listener/pidfile from an interrupted prior run,
    # matching host_access_spec.sh's identical cleanup pattern.
    if [ -f "${listener_pidfile}" ]; then
      _listener_pid="$(cat "${listener_pidfile}")"
      if [ -n "${_listener_pid}" ] && ps -p "${_listener_pid}" -o comm= 2>/dev/null | grep -q '^nc$'; then
        kill "${_listener_pid}" 2>/dev/null || true
      fi
      rm -f "${listener_pidfile}"
    fi
  }

  BeforeAll 'stop_host_listener'
  BeforeAll 'start_host_listener'
  AfterAll 'stop_host_listener'

  Describe 'with both --profile web-search and --profile host-access active'
    start_with_both() {
      ./bin/ai-sandbox.sh start --profile web-search --profile host-access --quiet 2> ./.ai-sandbox.multi-capability.startup.log || {
        cat ./.ai-sandbox.multi-capability.startup.log 1>&2
        echo "Container (with --profile web-search --profile host-access) failed to become ready" 1>&2
        return 1
      }
      return 0
    }
    stop_with_both() {
      ./bin/ai-sandbox.sh stop --profile web-search --profile host-access --quiet 2>/dev/null || true
    }

    BeforeAll 'start_with_both'
    AfterAll 'stop_with_both'

    It 'reaches a public non-private host on port 443 (web-search capability is functional)'
      Skip if 'network probe opted out via AI_SANDBOX_SKIP_EGRESS_NET' [ -n "${AI_SANDBOX_SKIP_EGRESS_NET:-}" ]
      When call ./bin/ai-sandbox.sh --quiet user-exec zsh -c "curl -sS --max-time 5 -o /dev/null -w '%{http_code}' https://${public_host}"
      The status should be success
      The output should match pattern '*[1-5][0-9][0-9]*'
    End

    It 'reaches the host listener via host.docker.internal:<port> (host-access capability is functional)'
      When call ./bin/ai-sandbox.sh --quiet user-exec zsh -c "python3 -c \"import socket; socket.create_connection(('host.docker.internal', ${listen_port}), timeout=5).close()\""
      The status should be success
    End
  End
End
