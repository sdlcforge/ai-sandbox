# shellcheck shell=bash
# shellcheck disable=SC2016 # we want to send unexpanded variables into the container so they expand in the container
Describe 'Static playground overlay' integration
  # Dedicated named instance -- --static-playground is opt-in and must not
  # affect the shared default container that container_spec.sh/others use.
  # Mirrors named_instance_enter_spec.sh's create/delete lifecycle.
  instance_name="playground-test"
  compose_project="ai-sandbox-${instance_name}"
  overlay_volume="${compose_project}_playground-overlay"

  create_instance() {
    ./bin/ai-sandbox.sh instances create "${instance_name}" --static-playground --clean --quiet \
      2> ./.ai-sandbox.playground-test.log || {
      cat ./.ai-sandbox.playground-test.log >&2
      echo "Named instance '${instance_name}' failed to be created" >&2
      return 1
    }
  }
  # `delete` is an explicit dispatch branch in src/index.sh, so it also
  # removes the playground-overlay named volume (src/index.sh's delete/clean
  # handlers) whenever STATIC_PLAYGROUND is true, restored via
  # restore_saved_config(). Idempotent (`|| true`) so a run that already
  # deleted the instance (see the dedicated deletion test below) leaves this
  # teardown a harmless no-op.
  delete_instance() {
    ./bin/ai-sandbox.sh "${instance_name}" delete --quiet 2>/dev/null || true
  }

  # Disposable probe subdir directly under the real host ~/playground --
  # never under an existing repo -- so the write-isolation assertion below
  # can never collide with or corrupt real host content. Cleaned up on the
  # host both before and after the run: it should never actually appear
  # there (that is the assertion under test), but if the overlay is broken
  # this guarantees no stray directory is left in the real ~/playground tree.
  write_probe_dir="ai-sandbox-static-playground-write-probe"
  write_probe_file="marker"
  host_write_probe_path="$HOME/playground/${write_probe_dir}"

  cleanup_host_write_probe() { rm -rf "${host_write_probe_path}" 2>/dev/null || true; }

  BeforeAll 'create_instance'
  BeforeAll 'cleanup_host_write_probe'
  AfterAll 'cleanup_host_write_probe'
  AfterAll 'delete_instance'

  It 'exposes AI_SANDBOX_STATIC_PLAYGROUND=1 inside the container'
    When call ./bin/ai-sandbox.sh --quiet "${instance_name}" user-exec zsh -c 'echo ${AI_SANDBOX_STATIC_PLAYGROUND:-unset}'
    The output should eq '1'
  End

  It 'mounts an overlayfs at ~/playground'
    # Unlike ~/.config (which has no host bind at all outside the overlay
    # mechanism), ~/playground's base compose file already binds the real
    # host directory read-write at this same target; static-playground.yaml
    # overrides that to a `:ro` bind at the same target (finding #1 in the
    # design note), and 06-overlay-playground's cont-init then stacks the
    # overlay mount on top of it. `findmnt` therefore reports both rows in
    # mount order (oldest/bottom first) -- `tail -n1` selects the topmost,
    # currently-effective mount, matching what a real read/write actually
    # sees.
    When call ./bin/ai-sandbox.sh --quiet "${instance_name}" user-exec zsh -c 'findmnt -n -o FSTYPE "$HOME/playground" | tail -n1'
    The output should eq 'overlay'
  End

  Describe 'read-through with no upfront copy'
    # Compares against the *real* host file (an absolute $HOME/playground/...
    # path resolved by this host-side bash, not a relative "README.md" read
    # from cwd) so this is correct regardless of which worktree checkout the
    # spec itself happens to run from -- ~/playground/ai-sandbox is always
    # the real, primary checkout of this repo per the task doc's assumption.
    It 'shows the real host README.md content for this repo, unmodified'
      expected="$(cat "$HOME/playground/ai-sandbox/README.md")"
      When call ./bin/ai-sandbox.sh --quiet "${instance_name}" user-exec zsh -c 'cat "$HOME/playground/ai-sandbox/README.md"'
      The output should eq "${expected}"
    End
  End

  Describe 'write isolation'
    It 'lets the container write under the playground overlay'
      When call ./bin/ai-sandbox.sh --quiet "${instance_name}" user-exec zsh -c "mkdir -p \$HOME/playground/${write_probe_dir} && echo container-only > \$HOME/playground/${write_probe_dir}/${write_probe_file} && cat \$HOME/playground/${write_probe_dir}/${write_probe_file}"
      The output should eq 'container-only'
    End

    It 'keeps that write out of the real host ~/playground (core write-isolation assertion)'
      # This example depends on the previous one having run; ShellSpec runs
      # examples in source order within a Describe by default (same
      # convention as container_spec.sh's Config isolation block).
      #
      # This is the assertion that would genuinely fail without
      # --static-playground: absent the overlay, the base compose file
      # bind-mounts the real ~/playground read-write straight through
      # (docker/docker-compose.yaml), so the write above would land on the
      # actual host directory and this check would find the probe file
      # present, failing the example -- the test cannot pass vacuously.
      When call test -e "${host_write_probe_path}/${write_probe_file}"
      The status should be failure
    End
  End

  It 'lists the playground overlay volume via sandbox-volumes'
    When call ./bin/ai-sandbox.sh --quiet "${instance_name}" user-exec sandbox-volumes list
    The output should include 'playground'
  End

  Describe 'deletion removes the named volume'
    It 'removes the compose-scoped playground-overlay volume'
      # Bare setup statement (not the invocation under test) -- delete is a
      # one-shot `docker compose down` dispatch branch, not an
      # interactive/exec command that inherits and consumes ShellSpec's
      # stdin pipe, so no `</dev/null` guard is needed here (contrast
      # named_instance_enter_spec.sh's `enter` and container_spec.sh's
      # user-exec drift setup, both of which do need it).
      ./bin/ai-sandbox.sh "${instance_name}" delete --quiet 2>/dev/null
      When call docker volume inspect "${overlay_volume}"
      The status should be failure
      The output should eq '[]'
      The stderr should include 'no such volume'
    End
  End
End
