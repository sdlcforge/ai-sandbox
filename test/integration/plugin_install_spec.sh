# shellcheck shell=bash

Describe 'Plugin install via --enable-plugin' integration
  # Uses a named sandbox ("plugintest") to avoid colliding with the default
  # sandbox started by container_spec.sh, the "enter-test" instance started
  # by named_instance_enter_spec.sh, or the "credtest" instance started by
  # clean_container_spec.sh when both run in the same session.
  create_instance() {
    ./bin/ai-sandbox.sh instances create plugintest --clean --quiet \
      --add-marketplace "file://${PWD}/test/fixtures/plugins/hello-world-marketplace" \
      --enable-plugin hello-world \
      2> ./.ai-sandbox.plugintest.log || {
      cat ./.ai-sandbox.plugintest.log >&2
      echo "Named instance 'plugintest' failed to be created" >&2
      return 1
    }
  }
  delete_instance() {
    ./bin/ai-sandbox.sh plugintest delete --quiet 2>/dev/null || true
  }

  BeforeAll 'create_instance'
  AfterAll 'delete_instance'

  Describe 'plugin installed via --enable-plugin'
    # `sh -c` does not pick up `claude` on PATH here: the assembled Dockerfile
    # actually used to build the image is docker/Dockerfile.base (see
    # docker/scripts/assemble-dockerfile.sh), which only appends the
    # .bun/bin/.local/bin/go/bin PATH additions to ~/.zshenv (no image-level
    # `ENV PATH=...`) -- unlike the separate, unused docker/Dockerfile, which
    # does have that ENV line and gave the false impression PATH would resolve
    # for a bare `sh -c`. `zsh -c` picks it up because zsh always sources
    # ~/.zshenv (even non-interactively), matching the sibling 'Bun' test's
    # `zsh -c "bun --version"` convention in container_spec.sh.
    #
    # `docker compose up -d` (invoked by `instances create`) can return before
    # the container's cont-init.d scripts (including 10-plugin-setup, which
    # does the actual marketplace-add/install work) finish running. This race
    # was observed in practice here: a `claude plugin list` issued immediately
    # after `create` returns reported "No plugins installed" even though
    # 10-plugin-setup went on to install the plugin successfully moments
    # later. Poll for up to ~15s instead of asserting on a single attempt.
    plugin_list() {
      local _attempt _output
      for _attempt in $(seq 1 15); do
        _output="$(./bin/ai-sandbox.sh --quiet plugintest user-exec zsh -c 'claude plugin list 2>&1')"
        if printf '%s' "${_output}" | grep -qF 'hello-world@hello-world-marketplace'; then
          printf '%s\n' "${_output}"
          return 0
        fi
        sleep 1
      done
      printf '%s\n' "${_output}"
      return 1
    }

    It 'appears installed and enabled in claude plugin list'
      When call plugin_list
      The output should include 'hello-world@hello-world-marketplace'
      The status should be success
    End
  End
End
