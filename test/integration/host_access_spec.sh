# shellcheck shell=bash
# shellcheck disable=SC2016 # we want unexpanded shell expressions sent into the container
#
# Coordinated with 003-add-host-access-capability.md: confirms the
# host-access capability's AI_SANDBOX_HOST_ACCESS iptables chain actually
# grants egress to a currently-listening host TCP port via
# host.docker.internal when --profile host-access is active, that the
# allow-listing is scoped to actually-listening ports only (a high,
# almost-certainly-unbound port stays blocked even with the capability
# active -- not a blanket allow on the whole host-gateway IP), and that the
# capability is strictly opt-in (no broadened access on a plain
# default-posture container).
#
# Flag placement follows README.md's documented `ai-sandbox start --profile
# <name> ...` form (command word first, then flags) -- see
# network_allow_spec.sh's note on the pre-existing flag-order parsing bug
# for why docker_proxy_spec.sh's `--profile <name> start` form is avoided here.
#
# Reachability is probed with a `python3 socket.create_connection(...)`
# one-liner (python3 is installed in the base image -- docker/Dockerfile.base)
# rather than curl: this project's assembled curl build has no
# `--connect-only` (confirmed via `curl --help all` inside the image), and a
# bare `curl` GET would hang waiting for an HTTP response the plain `nc`
# listener below never sends, timing out even on the reachable-port case.
# `create_connection` performs just the TCP connect/close; an unhandled
# exception (refused/unreachable/timeout) exits the interpreter non-zero,
# which is all these assertions need.
#
# Unlike web_search_spec.sh / network_allow_spec.sh's public-internet
# probes, these assertions never leave the host -- host.docker.internal
# resolves to the Docker host-gateway, which is required for every
# integration test in this suite to even start a container. There is
# nothing here to opt out of via AI_SANDBOX_SKIP_EGRESS_NET (that var
# exists for environments lacking real internet egress -- see
# plan/phase-01-firewall-enforcement/001-author-failing-egress-test.md).
Describe 'host-access capability (--profile host-access)' integration
  # Fixed, high, almost-certainly-unused ports. Deliberately not derived
  # from mktemp/$$/etc: this Describe block's top-level statements are
  # translated into plain shell once, and BeforeAll/AfterAll hooks (which
  # may run in different subshells than the It examples) all need to agree
  # on the same port numbers.
  listen_port=18942
  unbound_port=18943
  listener_pidfile="./.ai-sandbox.host-access-listener.pid"

  start_host_listener() {
    # `-k`: keep accepting connections after each one completes -- multiple
    # It examples below connect to this same listener. Output is discarded;
    # only the socket being open/closed matters for these probes.
    nc -kl "${listen_port}" >/dev/null 2>&1 &
    listener_pid=$!
    disown
    echo "${listener_pid}" > "${listener_pidfile}"
  }
  stop_host_listener() {
    # Guards against a leaked listener/pidfile from an interrupted prior
    # run, consistent with container_spec.sh's cleanup_sv_probe pattern
    # (registered as both BeforeAll and AfterAll below). The `ps -o comm=`
    # check confirms the recorded PID is still actually an `nc` process
    # before killing it -- a stale pidfile surviving across runs could
    # otherwise point at a since-reused PID belonging to an unrelated
    # process (PID reuse), and killing on PID alone with no such check
    # would risk killing that unrelated process instead of a no-op.
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

  Describe 'with --profile host-access active'
    start_with_host_access() {
      ./bin/ai-sandbox.sh start --profile host-access --quiet 2> ./.ai-sandbox.host-access.startup.log || {
        cat ./.ai-sandbox.host-access.startup.log 1>&2
        echo "Container (with --profile host-access) failed to become ready" 1>&2
        return 1
      }
      return 0
    }
    stop_with_host_access() {
      ./bin/ai-sandbox.sh stop --profile host-access --quiet 2>/dev/null || true
    }

    BeforeAll 'start_with_host_access'
    AfterAll 'stop_with_host_access'

    It 'reaches the host listener via host.docker.internal:<port>'
      When call ./bin/ai-sandbox.sh --quiet user-exec zsh -c "python3 -c \"import socket; socket.create_connection(('host.docker.internal', ${listen_port}), timeout=5).close()\""
      The status should be success
    End

    It 'still blocks a host port that is not currently listening'
      When call ./bin/ai-sandbox.sh --quiet user-exec zsh -c "python3 -c \"import socket; socket.create_connection(('host.docker.internal', ${unbound_port}), timeout=5).close()\""
      The status should not be success
    End
  End

  Describe 'without --profile host-access (default posture)'
    # Explicit `--profile base` (rather than a bare `start --quiet`) is
    # required here, not just for symmetry with the block above: src/utils.sh
    # restore_saved_config() persists the *previous* invocation's profile
    # set on this named instance's container label and re-applies it whenever
    # start/enter is called with no config-changing flags at all. Since the
    # 'with --profile host-access active' block above just ran --profile
    # host-access on this same default (unnamed) instance, a flag-less
    # `start --quiet` here would silently restore --profile host-access
    # instead of reverting to the default composition -- defeating the
    # opt-in check this block exists to make. Passing --profile explicitly
    # (even naming the ordinary default profile) sets
    # CONFIG_FLAGS_PROVIDED=true and skips that restore path entirely.
    start_default() {
      ./bin/ai-sandbox.sh start --profile base --quiet 2> ./.ai-sandbox.host-access-off.startup.log || {
        cat ./.ai-sandbox.host-access-off.startup.log 1>&2
        echo "Container (without --profile host-access) failed to become ready" 1>&2
        return 1
      }
      return 0
    }
    stop_default() {
      ./bin/ai-sandbox.sh stop --profile base --quiet 2>/dev/null || true
    }

    BeforeAll 'start_default'
    AfterAll 'stop_default'

    It 'does not reach the host listener that host-access made reachable above (capability is opt-in)'
      When call ./bin/ai-sandbox.sh --quiet user-exec zsh -c "python3 -c \"import socket; socket.create_connection(('host.docker.internal', ${listen_port}), timeout=5).close()\""
      The status should not be success
    End
  End
End
