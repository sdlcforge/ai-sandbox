# shellcheck shell=bash
#
# Regression coverage for 008-set-s6-stage2-fail-behavior.md.
#
# Phase 1 built an elaborate firewall-init sidecar + nonce handshake so that if
# the default-deny egress policy fails to apply, the ai-sandbox container's own
# cont-init.d/03-init-firewall stage exits nonzero to abort startup ("fail
# closed, never fail open"). Phase 1's tests validated 03-init-firewall's *own*
# exit behaviour, but never validated what s6-overlay actually *does* with that
# exit code end-to-end -- and s6-overlay's DEFAULT (with S6_BEHAVIOUR_IF_STAGE2_
# FAILS unset) is fail-OPEN: its cont-init runner evaluates
# `b=0${S6_BEHAVIOUR_IF_STAGE2_FAILS}` and only halts the boot when that value
# is >= 2, so an unset (b=0) or =1 value lets the container finish booting to an
# idle, exec-able state with a default-ACCEPT OUTPUT policy. This task bakes
# `ENV S6_BEHAVIOUR_IF_STAGE2_FAILS=2` into docker/Dockerfile.base to close that
# gap; this spec is the end-to-end guard that it stays closed.
#
# Approach: rather than assert on 03-init-firewall's script exit in isolation
# (the exact gap that let this issue ship through Phase 1), this spec exercises
# the REAL ai-sandbox image through s6-overlay and asserts on the *container's*
# resulting state. It reproduces the production failure trigger -- 03-init-
# firewall exiting nonzero because the firewall was never confirmed applied --
# by running the image with no firewall-init sidecar and a short
# AI_SANDBOX_FIREWALL_WAIT_TIMEOUT, so 03-init-firewall's own wait-then-`exit 1`
# path fires. (The sidecar's own failure modes are Task 007's domain; what THIS
# task adds, and this spec guards, is what s6-overlay does with 03's nonzero
# exit.) It runs the image directly with `docker run` -- established in this
# suite via spec_helper.sh's `container_exec` docker-exec helper -- so it can
# control the sidecar's absence and the wait timeout without going through the
# launcher's full compose assembly. The baked env var lives in Dockerfile.base,
# so EVERY ai-sandbox variant image inherits it; any built variant works here.
Describe 'firewall fail-closed halt (S6_BEHAVIOUR_IF_STAGE2_FAILS=2)' integration
  # Short, so 03-init-firewall's wait times out quickly; the halt then follows
  # once the remaining cont-init.d stages run and the aggregate stage-2 failure
  # is evaluated (s6-overlay runs every cont-init.d script before deciding
  # pass/fail, then brings the container down -- see the task doc's Status).
  wait_timeout=5
  fail_closed_container='ai-sandbox-failclosed-test'
  fail_open_container='ai-sandbox-failopen-test'

  # Resolve any built ai-sandbox variant image (they all inherit the base ENV);
  # build the default composition if none exists yet. Echoes the image ref.
  resolve_ai_sandbox_image() {
    local img
    img="$(docker images --filter 'reference=ai-sandbox:*' --format '{{.Repository}}:{{.Tag}}' | head -n1)"
    if [ -z "${img}" ]; then
      AI_SANDBOX_SKIP_PLUGIN_CHECK=1 ./bin/ai-sandbox.sh build --quiet >/dev/null 2>&1 || return 1
      img="$(docker images --filter 'reference=ai-sandbox:*' --format '{{.Repository}}:{{.Tag}}' | head -n1)"
    fi
    [ -n "${img}" ] || return 1
    printf '%s\n' "${img}"
  }

  # Poll until the named container is no longer running, up to max_secs. Returns
  # 0 as soon as it stops; returns 0 anyway after the budget expires so the It
  # examples assert the actual observed state rather than the hook masking it.
  wait_until_stopped() {
    local name="$1" max_secs="${2:-60}" elapsed=0
    while [ "${elapsed}" -lt "${max_secs}" ]; do
      [ "$(docker inspect -f '{{.State.Running}}' "${name}" 2>/dev/null)" = 'false' ] && return 0
      sleep 1
      elapsed=$((elapsed + 1))
    done
    return 0
  }

  container_is_running() {
    [ "$(docker inspect -f '{{.State.Running}}' "$1" 2>/dev/null)" = 'true' ]
  }

  # Attempt to attach a session to the container, exactly as user-exec/root-exec
  # (docker exec) would. Non-zero exit == no session could be established.
  try_exec_session() {
    docker exec "$1" sh -c 'echo REACHED' 2>&1
  }

  container_logs() {
    docker logs "$1" 2>&1
  }

  Describe 'with a forced firewall-init failure (image default: fail-closed)'
    start_failed_firewall_container() {
      local img
      img="$(resolve_ai_sandbox_image)" || return 1
      docker rm -f "${fail_closed_container}" >/dev/null 2>&1 || true
      # No firewall-init sidecar in this compose-less run, so the handshake
      # marker never appears and 03-init-firewall times out and exits 1 -- the
      # same nonzero exit any real sidecar failure produces.
      docker run -d --name "${fail_closed_container}" \
        -e AI_SANDBOX_FIREWALL_WAIT_TIMEOUT="${wait_timeout}" \
        "${img}" >/dev/null || return 1
      wait_until_stopped "${fail_closed_container}" 60
    }
    remove_failed_firewall_container() {
      docker rm -f "${fail_closed_container}" >/dev/null 2>&1 || true
    }

    BeforeAll 'start_failed_firewall_container'
    AfterAll 'remove_failed_firewall_container'

    It 'halts the container (it is no longer running) instead of failing open'
      # The core fail-closed property. Against the pre-fix configuration (env
      # unset) this container would instead finish booting and stay running
      # with an unrestricted OUTPUT policy -- see the fail-open contrast below.
      When call container_is_running "${fail_closed_container}"
      The status should be failure
    End

    It 'exited nonzero, distinguishing a hard failure from a slow-but-healthy start'
      When call docker inspect -f '{{.State.Status}} {{.State.ExitCode}}' "${fail_closed_container}"
      The output should include 'exited'
      The output should not include 'exited 0'
      The status should be success
    End

    It 'leaves no session reachable: docker exec into the halted container fails'
      # user-exec / root-exec / `docker compose exec` all reduce to `docker
      # exec`; none can attach to a stopped container.
      When call try_exec_session "${fail_closed_container}"
      The output should not include 'REACHED'
      The status should not be success
    End

    It 'never reached stage 3: legacy-services (s6 longruns) never started'
      # The property that actually matters: the point at which a sandboxed
      # session becomes reachable is never crossed. A normal boot logs
      # "legacy-services successfully started"; a halted boot never does.
      When call container_logs "${fail_closed_container}"
      The output should not include 'legacy-services successfully started'
    End

    It 'surfaces a diagnosable reason in the container logs'
      When call container_logs "${fail_closed_container}"
      The output should include 'refusing to start the sandbox without a confirmed egress firewall'
      The output should include 'legacy-cont-init'
    End
  End

  Describe 'the same forced failure with S6_BEHAVIOUR_IF_STAGE2_FAILS=0 (pre-fix behaviour)'
    # Discrimination / red-green witness: this overrides the baked =2 back to the
    # pre-fix value and shows the SAME forced firewall failure leaves the
    # container running and attachable -- i.e. fail-OPEN. This is what the =2
    # default closes; it also proves the fail-closed assertions above are not
    # passing vacuously (e.g. the container failing to start for some unrelated
    # reason).
    start_failopen_container() {
      local img
      img="$(resolve_ai_sandbox_image)" || return 1
      docker rm -f "${fail_open_container}" >/dev/null 2>&1 || true
      docker run -d --name "${fail_open_container}" \
        -e AI_SANDBOX_FIREWALL_WAIT_TIMEOUT="${wait_timeout}" \
        -e S6_BEHAVIOUR_IF_STAGE2_FAILS=0 \
        "${img}" >/dev/null || return 1
      # Give it well past the wait timeout + remaining cont-init.d stages to
      # settle into its (fail-open) steady state before asserting.
      sleep $((wait_timeout + 8))
    }
    remove_failopen_container() {
      docker rm -f "${fail_open_container}" >/dev/null 2>&1 || true
    }

    BeforeAll 'start_failopen_container'
    AfterAll 'remove_failopen_container'

    It 'does NOT halt: the container stays running despite the firewall failure'
      When call container_is_running "${fail_open_container}"
      The status should be success
    End

    It 'and a session IS reachable on it (the exposure the =2 default eliminates)'
      When call try_exec_session "${fail_open_container}"
      The output should include 'REACHED'
      The status should be success
    End
  End
End
