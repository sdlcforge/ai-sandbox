# shellcheck shell=bash
# shellcheck disable=SC2016 # we want to send unexpected variables into the container so they expand in the container
Describe 'Container internals' integration
  # Ensure the container is running for these tests
  start_container() {
    ./bin/ai-sandbox.sh start --quiet 2> ./.ai-sandbox.startup.log || {
      cat ./.ai-sandbox.startup.log 1>&2
      echo "Container failed to become ready" 1>&2
      return 1
    }
    return 0
  }
  stop_container() {
    ./bin/ai-sandbox.sh stop --quiet 2>/dev/null || true
  }
  container_exec() {
    ./bin/ai-sandbox.sh user-exec "$@" 2>/dev/null
  }

  BeforeAll 'start_container'
  AfterAll 'stop_container'

  Describe 'sandbox-volumes'
    # Runs first on purpose: the 'reports clean status on an untouched
    # overlay' check below requires the overlay's tmpfs upper layer to
    # be empty. Almost any other test dirties it — running `go version`
    # alone causes Go telemetry to whiteout ~20 expired counter files,
    # `Config isolation` writes a probe marker, etc. Once dirtied, the
    # tmpfs upper persists for the life of the container.
    sv_probe_dir="ai-sandbox-sv-probe"
    sv_probe_file="marker"
    sv_host_probe="$HOME/.config/${sv_probe_dir}"

    cleanup_sv_probe() { rm -rf "${sv_host_probe}" 2>/dev/null || true; }
    BeforeAll 'cleanup_sv_probe'
    AfterAll 'cleanup_sv_probe'

    # HOST_HOME inside the container equals the host's $HOME (the Dockerfile
    # creates the user with `useradd -d "$HOST_HOME"`), so a host-expanded
    # absolute path matches the registered overlay's container path. We
    # cannot pass a literal "$HOME" — sandbox-volumes is not a shell and
    # does not expand env vars in argv.
    sv_probe_path="${HOME}/.config/${sv_probe_dir}"

    It 'lists the config overlay volume'
      When call ./bin/ai-sandbox.sh --quiet user-exec sandbox-volumes list
      The output should include 'config'
      The output should include '.config'
    End

    It 'reports clean status on an untouched overlay'
      When call ./bin/ai-sandbox.sh --quiet user-exec sandbox-volumes status
      The output should include 'clean'
      The status should be success
    End

    It 'detects drift after a container-side write'
      # Dirty the overlay so the next status/diff/sync probes have work to do.
      # `</dev/null` is required: ShellSpec's executor reads test code from a
      # pipe on stdin, and `docker compose exec` (via user-exec) inherits and
      # consumes that pipe — truncating subsequent tests and the FINISHED event.
      ./bin/ai-sandbox.sh --quiet user-exec zsh -c "mkdir -p \$HOME/.config/${sv_probe_dir} && echo drift-me > \$HOME/.config/${sv_probe_dir}/${sv_probe_file}" </dev/null
      When call ./bin/ai-sandbox.sh --quiet user-exec sandbox-volumes status
      The output should include 'drift'
      The status should be failure
    End

    It 'shows a diff for the drifted path'
      When call ./bin/ai-sandbox.sh --quiet user-exec sandbox-volumes diff "${sv_probe_path}"
      The output should include "${sv_probe_file}"
    End

    It 'previews match-container sync as a dry-run without touching host'
      When call ./bin/ai-sandbox.sh --quiet user-exec sandbox-volumes sync --match-container --dry-run "${sv_probe_path}"
      The output should include 'dry-run'
      The output should include "${sv_probe_file}"
      # Host must still not have the probe.
      The path "${sv_host_probe}/${sv_probe_file}" should not be exist
    End

    It 'previews match-host sync as a dry-run'
      # The probe only exists in the container's overlay — the host side is
      # absent, so rsync exits 23 ("some files/attrs were not transferred").
      # That is the truthful answer for "match host" in this scenario, and
      # the [dry-run] header is printed before rsync runs.
      When call ./bin/ai-sandbox.sh --quiet user-exec sandbox-volumes sync --match-host --delete --dry-run "${sv_probe_path}"
      The output should include 'dry-run'
      The stderr should include 'No such file or directory'
      The status should equal 23
    End

    It 'rejects a path outside any registered volume'
      When call ./bin/ai-sandbox.sh --quiet user-exec sandbox-volumes status /etc/passwd
      The stderr should include 'not under any registered overlay volume'
      The status should be failure
    End
  End

  Describe 'Go'
    It 'is installed'
      When call ./bin/ai-sandbox.sh --quiet user-exec go version
      The output should include 'go'
      The status should be success
    End
  End

  Describe 'Node.js'
    It 'is installed via nvm'
      When call ./bin/ai-sandbox.sh --quiet user-exec zsh -c "source ~/.nvm/nvm.sh && node --version" 2>/dev/null
      The output should be present
      The status should be success
    End
  End

  Describe 'Bun'
    It 'is installed'
      When call ./bin/ai-sandbox.sh --quiet user-exec zsh -c "bun --version"
      The output should match pattern [0-9].[0-9]*.[0-9]*
      The status should be success
    End
  End

  Describe 'Claude Code'
    It 'is installed and on PATH'
      # `sh -c`/bare argv `user-exec` does not pick up `claude` on PATH: the
      # assembled Dockerfile actually used to build the image is
      # docker/Dockerfile.base (see docker/scripts/assemble-dockerfile.sh),
      # which only appends the .bun/bin/.local/bin/go/bin PATH additions to
      # ~/.zshenv (no image-level `ENV PATH=...`). `zsh -c` picks it up
      # because zsh always sources ~/.zshenv (even non-interactively),
      # matching the sibling 'Bun'/'git-delta' tests' convention above.
      When call ./bin/ai-sandbox.sh --quiet user-exec zsh -c "claude --version"
      The output should be present
      The status should be success
    End
  End

  Describe 'git-delta'
    It 'is installed'
      When call ./bin/ai-sandbox.sh --quiet user-exec zsh -c "delta --version"
      The output should include 'delta'
      The status should be success
    End
  End

  Describe 'Default shell'
    It 'is zsh'
      When call ./bin/ai-sandbox.sh --quiet user-exec zsh -c 'echo $SHELL'
      The output should include '/zsh'
    End
  End

  Describe 'User UID'
    It 'matches host UID'
      HOST_UID=$(id -u)
      When call ./bin/ai-sandbox.sh --quiet user-exec id -u
      The output should eq "$HOST_UID"
    End
  End

  Describe 'Firewall rules'
    # Relocated by 004-move-firewall-init-to-sidecar.md: the firewall's
    # CAP_NET_ADMIN now lives on the short-lived `firewall-init` sidecar, which
    # shares this container's network namespace, applies init-firewall.sh's
    # rules into it once, and writes a completion marker to the shared
    # firewall-handshake volume. The ai-sandbox container itself no longer holds
    # NET_ADMIN, so it can neither run nor read iptables -- proof that init ran
    # therefore comes from the sidecar's verified completion marker plus the
    # behavioural allow/deny probes below, not from an in-container
    # `iptables -S`. The marker path is single-sourced via the
    # AI_SANDBOX_FIREWALL_MARKER_DIR env var (docker/docker-compose.yaml).
    firewall_marker='/var/lib/ai-sandbox-firewall/applied'
    # IPv6 counterpart written by the sidecar (security-003) -- see the
    # 'applies an IPv6 default-deny policy' test below for why this reads a
    # marker's content instead of a live IPv6 probe.
    firewall_marker_ipv6='/var/lib/ai-sandbox-firewall/applied-ipv6'

    It 'does not grant the ai-sandbox container CAP_NET_ADMIN'
      # The core of the security-001 fix: this container carries a broad
      # NOPASSWD sudo grant, so it must NOT hold NET_ADMIN -- otherwise a
      # prompt-injected `sudo iptables -F` could flush the firewall. `capsh
      # --print`'s "Current IAB:" line lists capabilities NOT held (each
      # prefixed with `!`); scoping the grep to the `^Current:` line (the
      # actually-held effective set) avoids a false positive on `!cap_net_admin`
      # and correctly reports absence as a grep miss (non-zero exit).
      When call ./bin/ai-sandbox.sh --quiet root-exec zsh -c "capsh --print | grep '^Current:' | grep -q cap_net_admin"
      The status should not be success
    End

    It 'cannot flush the firewall from inside the container (security-001 regression)'
      # The specific regression guard for security-001. The container grants
      # passwordless sudo, so `sudo` elevates to root -- but without
      # CAP_NET_ADMIN even root cannot touch iptables, so the flush must fail.
      # If NET_ADMIN ever leaks back onto the ai-sandbox container this call
      # would succeed and silently disable the entire default-deny egress
      # policy, so a non-zero exit here is load-bearing, not incidental.
      When call ./bin/ai-sandbox.sh --quiet user-exec zsh -c "sudo iptables -F"
      The status should not be success
    End

    It 'runs s6-overlay with the fail-closed cont-init behaviour (S6_BEHAVIOUR_IF_STAGE2_FAILS=2)'
      # Cheap always-on guard for 008-set-s6-stage2-fail-behavior.md, complementing
      # the end-to-end halt proof in firewall_fail_closed_spec.sh: confirm the
      # security-critical env var actually reached the running container. Without
      # it (s6-overlay's fail-OPEN default), a 03-init-firewall nonzero exit would
      # NOT halt the container -- the whole lockdown-egress fail-closed guarantee
      # depends on this value being >= 2. Baked into docker/Dockerfile.base so it
      # cannot be dropped by a compose edit.
      When call ./bin/ai-sandbox.sh --quiet root-exec printenv S6_BEHAVIOUR_IF_STAGE2_FAILS
      The output should include '2'
      The status should be success
    End

    It 'applied the firewall via the firewall-init sidecar during container init'
      # The sidecar writes this marker only after init-firewall.sh succeeds AND
      # it verifies the default-deny LOG rule is present in the shared namespace
      # (see docker/init-firewall-sidecar.sh) -- so the marker is an effect only
      # a successful, correct run produces, not a log-only breadcrumb. Its
      # presence also proves this container's 03-init-firewall wait stage
      # observed completion (it blocks otherwise). The behavioural probes below
      # independently confirm the rules are actually in force.
      When call ./bin/ai-sandbox.sh --quiet root-exec zsh -c "test -e '${firewall_marker}'"
      The status should be success
    End

    It 'blocks egress to a disallowed host'
      Skip if 'network probe opted out via AI_SANDBOX_SKIP_EGRESS_NET' [ -n "${AI_SANDBOX_SKIP_EGRESS_NET:-}" ]
      # A non-zero curl exit (e.g. 7 connection-refused, 28 timeout) both
      # count as "unreachable" here -- the exact failure mode depends on
      # whether the fix task chooses DROP or REJECT, which is not this
      # test's concern; only "did not succeed" is asserted.
      When call ./bin/ai-sandbox.sh --quiet user-exec zsh -c "curl -sS --max-time 5 -o /dev/null -w '%{http_code}' https://example.com"
      The status should not be success
    End

    It 'still allows egress to a default-allow-listed host'
      # Guards against an overly-broad default-deny that would also break
      # the documented default allow-list.
      When call ./bin/ai-sandbox.sh --quiet user-exec zsh -c "curl -sS --max-time 5 -o /dev/null -w '%{http_code}' https://github.com"
      The output should include '200'
      The status should be success
    End

    It 'applies an IPv6 default-deny policy (security-003)'
      # Regression test for security-003: the IPv4 default-deny above says
      # nothing about ip6tables, which ships alongside iptables
      # (docker/Dockerfile.base) at its default ACCEPT policy -- any IPv6
      # route would otherwise bypass the whole firewall untested.
      #
      # This asserts via the sidecar's verified marker file rather than
      # either of the two more obvious options, both of which are unsound
      # here:
      #   - Querying ip6tables directly from ai-sandbox: impossible --
      #     ai-sandbox never holds CAP_NET_ADMIN (security-001), the same
      #     reason the IPv4 test above reads a marker instead of `iptables
      #     -S`.
      #   - A live `curl -6`/`ping -6` probe to an external host: verified
      #     locally (see task notes) to be a false-pass here -- Docker
      #     Desktop's default bridge network has no IPv6 route at all (only
      #     `::1` on loopback), so the probe would "fail" identically with
      #     or without any IPv6 firewall policy in place, proving nothing.
      #
      # The firewall-init sidecar -- which does hold NET_ADMIN -- verifies
      # its own `ip6tables -S OUTPUT` contains the
      # ai-sandbox-egress-ipv6-DROP catch-all (or records that ip6tables was
      # unavailable) before writing this marker, so the marker's *content*
      # is trustworthy evidence of the actually-applied policy, not a
      # "the script started" breadcrumb. Reading it back is a plain file
      # read on the shared firewall-handshake volume, which needs no special
      # capability.
      #
      # Content is token-qualified (007-nonce-based-firewall-handshake):
      # "<per-boot token> applied" or "<per-boot token> skipped: ...", so this
      # asserts by substring rather than exact match. Still asserts strictly
      # that the status suffix is 'applied' (not the sidecar's
      # 'skipped: ...' fallback for hosts without ip6tables, see
      # docker/init-firewall-sidecar.sh): the image installs ip6tables
      # unconditionally via the same `iptables` apt package as iptables
      # (docker/Dockerfile.base), and it was confirmed at implementation
      # time to apply and read back rules correctly under this project's
      # Docker Desktop target, so 'applied' is the correct expected value
      # here -- a 'skipped' marker on this project's supported platform
      # would itself indicate the IPv6 policy failed to land and should
      # fail this regression test, not be silently tolerated. 'applied' does
      # not appear anywhere in the 'skipped: ip6tables unavailable on this
      # host' fallback string, so the substring check stays exact for this
      # distinction despite the added token prefix.
      When call ./bin/ai-sandbox.sh --quiet root-exec zsh -c "cat '${firewall_marker_ipv6}'"
      The status should be success
      The output should include 'applied'
    End
  End

  Describe 'SSH agent forwarding'
    It 'exposes the stable in-container socket path'
      When call ./bin/ai-sandbox.sh --quiet user-exec zsh -c 'echo $SSH_AUTH_SOCK'
      The output should eq '/run/ai-sandbox/ssh-auth.sock'
    End

    It 'mounts a live socket at the stable path'
      When call ./bin/ai-sandbox.sh --quiet user-exec zsh -c 'test -S /run/ai-sandbox/ssh-auth.sock'
      The status should be success
    End

    It 'authenticates to github.com over SSH'
      Skip if 'network probe opted out via AI_SANDBOX_SKIP_SSH_NET' [ -n "${AI_SANDBOX_SKIP_SSH_NET:-}" ]
      # `ssh -T git@github.com` exits 1 on success (no shell), prints the auth
      # banner to stderr. We redirect to stdout and tolerate the non-zero exit.
      When call ./bin/ai-sandbox.sh --quiet user-exec zsh -c 'ssh -o BatchMode=yes -o StrictHostKeyChecking=accept-new -o ConnectTimeout=5 -T git@github.com 2>&1 || true'
      The output should include 'successfully authenticated'
    End
  End

  Describe 'DEVCONTAINER env'
    It 'is set to true'
      When call ./bin/ai-sandbox.sh --quiet user-exec zsh -c 'echo $DEVCONTAINER'
      The output should eq 'true'
    End
  End

  Describe 'Config isolation (default)'
    # Drop a marker in ~/.config inside the container; the same path on the
    # host must stay absent. The subdir is one we fully own so there's no
    # risk of collision.
    probe_dir="ai-sandbox-isolation-probe"
    probe_file="marker"
    host_probe_path="$HOME/.config/${probe_dir}"

    cleanup_host_probe() { rm -rf "${host_probe_path}" 2>/dev/null || true; }

    BeforeAll 'cleanup_host_probe'
    AfterAll 'cleanup_host_probe'

    It 'exposes AI_SANDBOX_ISOLATE_CONFIG=1 inside the container'
      When call ./bin/ai-sandbox.sh --quiet user-exec zsh -c 'echo ${AI_SANDBOX_ISOLATE_CONFIG:-unset}'
      The output should eq '1'
    End

    It 'mounts an overlayfs at ~/.config'
      When call ./bin/ai-sandbox.sh --quiet user-exec zsh -c 'findmnt -n -o FSTYPE "$HOME/.config"'
      The output should eq 'overlay'
    End

    It 'lets the container write to ~/.config'
      When call ./bin/ai-sandbox.sh --quiet user-exec zsh -c "mkdir -p \$HOME/.config/${probe_dir} && echo container-only > \$HOME/.config/${probe_dir}/${probe_file} && cat \$HOME/.config/${probe_dir}/${probe_file}"
      The output should eq 'container-only'
    End

    It 'keeps that write out of the host ~/.config'
      # This example depends on the previous one having run; ShellSpec runs
      # examples in source order within a Describe by default.
      When call test -e "${host_probe_path}/${probe_file}"
      The status should be failure
    End
  End
End
