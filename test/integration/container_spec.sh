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
    It 'has iptables rules applied'
      When call ./bin/ai-sandbox.sh --quiet root-exec zsh -c "echo 'true' > /root/access-test.tmp && cat /root/access-test.tmp && rm /root/access-test.tmp"
      The output should be present
      The output should equal 'true'
      The status should be success
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
