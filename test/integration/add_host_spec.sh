# shellcheck shell=bash
# shellcheck disable=SC2016 # we want unexpanded shell expressions sent into the container
#
# Coordinated with 002-thread-add-host-extra-hosts.md and
# 003-config-persistence-triad.md: confirms a container started with
# --add-host <name>:<ip> actually resolves <name> to the pinned IPv4 inside
# the container (via both /etc/hosts and getent ahostsv4), and that the
# static host.docker.internal:host-gateway entry the base compose file
# declares still resolves alongside the caller-supplied entry (task 002's
# empirically-confirmed Compose extra_hosts append semantics -- see that
# task doc's Status section).
#
# Flag placement follows README.md's documented `ai-sandbox start --add-host
# <spec> ...` form (command word first, then flags) -- see
# network_allow_spec.sh's note on the pre-existing flag-order parsing bug for
# why docker_proxy_spec.sh's `--profile <name> start` form is avoided here.
#
# Config-persistence coverage (task doc Requirement 3's second bullet: the
# ai.sandbox.add-host label / ai.sandbox.config .add_host carrying the
# value, a subsequent no-flag per-instance command restoring it via
# restore_saved_config(), and running_config_matches() reporting a
# match/mismatch) is deliberately NOT duplicated here, mirroring
# allow_egress_spec.sh's own precedent and stated rationale: 003-config-
# persistence-triad.md's own Status section explicitly left this to task 005
# (this task), and phase-01/005's unit-level ai_sandbox_spec.sh additions
# (Describe 'restore_saved_config()' / Describe 'running_config_matches()')
# now give restore_saved_config()/running_config_matches() the same
# comprehensive add-host coverage the other eight config-input dimensions
# already have -- no integration-level test exercises this restore/matches
# contract for any of them, add-host included. The yS0R gap-closure
# comparisons (AI_SANDBOX_LAN_CIDR / AI_SANDBOX_HOST_LISTEN_PORTS drift) are
# likewise covered exclusively at the unit level for the same reason: both
# are pure-function inputs to running_config_matches(), fully exercisable via
# a mocked `docker inspect`, with no behavior a real container boot would add
# to the assertion.
Describe '--add-host' integration
  test_name='myhost'
  # 192.168.65.254 is Docker Desktop's documented host-gateway IP on macOS
  # (the same address host.docker.internal itself resolves to) -- a stable,
  # always-reachable-from-the-container literal that doesn't depend on any
  # live host-listening service, unlike host_access_spec.sh's nc listener.
  test_ip='192.168.65.254'

  # delete (not just stop) between the two Describe blocks below: task 003's
  # restore_saved_config() re-applies a stopped-but-not-deleted container's
  # saved ai.sandbox.config label (including add_host) on the next flag-less
  # start/enter -- exactly the behavior the "no --add-host flag" block's
  # negative assertions below need to NOT happen. `delete` runs `docker
  # compose down`, removing the container (and its label) outright, so each
  # block below starts from a truly clean slate regardless of prior test
  # (or prior spec file) state -- same defensive pattern lifecycle_spec.sh's
  # cleanup_containers and static_playground_spec.sh's delete_instance use.
  delete_default_instance() {
    ./bin/ai-sandbox.sh delete --quiet 2>/dev/null || true
  }

  Describe 'container created with --add-host <name>:<ip>'
    start_with_add_host() {
      ./bin/ai-sandbox.sh start --add-host "${test_name}:${test_ip}" \
        --quiet 2> ./.ai-sandbox.add-host.startup.log || {
        cat ./.ai-sandbox.add-host.startup.log 1>&2
        echo "Container (with --add-host ${test_name}:${test_ip}) failed to become ready" 1>&2
        return 1
      }
      return 0
    }
    stop_with_add_host() {
      ./bin/ai-sandbox.sh stop --add-host "${test_name}:${test_ip}" --quiet 2>/dev/null || true
    }

    BeforeAll 'delete_default_instance'
    BeforeAll 'start_with_add_host'
    AfterAll 'stop_with_add_host'
    AfterAll 'delete_default_instance'

    It 'resolves the caller-supplied name to the pinned IPv4 via getent ahostsv4 (task 002)'
      When call ./bin/ai-sandbox.sh --quiet user-exec zsh -c "getent ahostsv4 ${test_name}"
      The status should be success
      The output should include "${test_ip}"
    End

    It 'has the caller-supplied name in /etc/hosts mapped to the pinned IPv4'
      When call ./bin/ai-sandbox.sh --quiet user-exec zsh -c "grep ${test_name} /etc/hosts | grep -q ${test_ip}"
      The status should be success
    End

    It 'still resolves host.docker.internal via the static host-gateway entry (merge-semantics regression guard, task 002: Compose extra_hosts appends rather than replaces)'
      When call ./bin/ai-sandbox.sh --quiet user-exec zsh -c "getent ahostsv4 host.docker.internal"
      The status should be success
      The output should include 'host.docker.internal'
    End
  End

  Describe 'no --add-host flag (baseline, regression guard)'
    start_default() {
      ./bin/ai-sandbox.sh start --quiet 2> ./.ai-sandbox.add-host-off.startup.log || {
        cat ./.ai-sandbox.add-host-off.startup.log 1>&2
        echo "Container (without --add-host) failed to become ready" 1>&2
        return 1
      }
      return 0
    }
    stop_default() {
      ./bin/ai-sandbox.sh stop --quiet 2>/dev/null || true
    }

    BeforeAll 'delete_default_instance'
    BeforeAll 'start_default'
    AfterAll 'stop_default'
    AfterAll 'delete_default_instance'

    It 'does not resolve the add-host-only name from the block above (capability is opt-in, no leftover entry)'
      When call ./bin/ai-sandbox.sh --quiet user-exec zsh -c "getent ahostsv4 ${test_name}"
      The status should not be success
    End

    It 'still resolves host.docker.internal via the static host-gateway entry with no caller entries present'
      When call ./bin/ai-sandbox.sh --quiet user-exec zsh -c "getent ahostsv4 host.docker.internal"
      The status should be success
      The output should include 'host.docker.internal'
    End
  End
End
