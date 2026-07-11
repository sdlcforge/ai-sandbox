# shellcheck shell=bash
# shellcheck disable=SC2016 # we want unexpanded shell expressions sent into the container
#
# Coordinated with 002-wire-allow-egress-into-firewall.md: confirms
# --allow-egress actually opens the exact destination(s) it names (and only
# those), for both accepted spec forms (IP/CIDR+port, name+port), that a
# destination outside every allow-list (default and --allow-egress) stays
# blocked, that multiple --allow-egress flags accumulate rather than
# overwrite, and that the name-form's emitted iptables rule targets the
# resolved IP -- not a literal hostname match -- per that task's design.
#
# Flag placement follows README.md's documented `ai-sandbox start
# --allow-egress <spec> ...` form (command word first, then flags) -- see
# network_allow_spec.sh's note on the pre-existing flag-order parsing bug
# for why docker_proxy_spec.sh's `--profile <name> start` form is avoided
# here.
#
# Config-persistence coverage (task doc Requirement 3: restore_saved_config()
# rehydrating CLI_ALLOW_EGRESS on a bare `enter`, and running_config_matches()
# detecting an --allow-egress change) is deliberately NOT duplicated here.
# 001-add-allow-egress-flag-parsing.md already added comprehensive unit-level
# coverage for both functions (test/unit/ai_sandbox_spec.sh's
# restore_saved_config()/running_config_matches() Describe blocks), and no
# integration-level test exercises this restore/matches contract for any of
# the other seven config-persistence dimensions (marketplaces, plugins,
# enable-all, clean-slate, mode, no-isolate-config, profiles) either -- it is
# covered exclusively at the unit level throughout this project. Adding a
# one-off integration test just for allow-egress would depart from that
# established precedent for no allow-egress-specific reason; see this task's
# own report for the fuller reasoning.
Describe '--allow-egress' integration
  # 1.1.1.1 is the same well-known public (non-private) IPv4 host
  # web_search_spec.sh / multi_capability_spec.sh use -- not on the default
  # allow-list (github.com / Anthropic API hosts) and not a real
  # ai-sandbox-recognized profile/capability host, so it can only become
  # reachable via --allow-egress.
  test_ip='1.1.1.1'
  # example.com is the same test hostname 002-wire-allow-egress-into-
  # firewall.md's own manual validation (task doc Status) already exercised
  # -- confirmed to resolve to multiple A records via `getent ahostsv4`
  # inside this exact base image.
  test_hostname='example.com'
  # example.org: the same "definitely blocked" negative-case host
  # web_search_spec.sh / network_allow_spec.sh use -- neither on the default
  # allow-list nor ever passed via --allow-egress in this spec.
  blocked_host='example.org'
  # docker-compose.yaml's `container_name: ai-sandbox-${SANDBOX_NAME}`;
  # every Describe block below starts the default (unnamed) instance, so
  # SANDBOX_NAME is always empty here. Used by the rule-inspection helper
  # below to join this container's network namespace from a throwaway
  # diagnostic container.
  sandbox_container_name='ai-sandbox-'

  Describe 'IP+port form (--allow-egress <ip>:443)'
    start_with_ip_egress() {
      ./bin/ai-sandbox.sh start --allow-egress "${test_ip}:443" \
        --quiet 2> ./.ai-sandbox.allow-egress-ip.startup.log || {
        cat ./.ai-sandbox.allow-egress-ip.startup.log 1>&2
        echo "Container (with --allow-egress ${test_ip}:443) failed to become ready" 1>&2
        return 1
      }
      return 0
    }
    stop_with_ip_egress() {
      ./bin/ai-sandbox.sh stop --allow-egress "${test_ip}:443" --quiet 2>/dev/null || true
    }

    BeforeAll 'start_with_ip_egress'
    AfterAll 'stop_with_ip_egress'

    It 'reaches the allow-egress IP on the allow-egress port'
      Skip if 'network probe opted out via AI_SANDBOX_SKIP_EGRESS_NET' [ -n "${AI_SANDBOX_SKIP_EGRESS_NET:-}" ]
      When call ./bin/ai-sandbox.sh --quiet user-exec zsh -c "curl -sS --max-time 5 -o /dev/null -w '%{http_code}' https://${test_ip}"
      The status should be success
      The output should match pattern '*[1-5][0-9][0-9]*'
    End

    It 'still blocks a different port on the same allow-egress IP (port-scoped, not a whole-IP allow-list)'
      When call ./bin/ai-sandbox.sh --quiet user-exec zsh -c "curl -sS --max-time 5 -o /dev/null -w '%{http_code}' http://${test_ip}"
      The status should not be success
    End

    It 'still blocks a host that is neither default-allowed nor passed via --allow-egress'
      When call ./bin/ai-sandbox.sh --quiet user-exec zsh -c "curl -sS --max-time 5 -o /dev/null -w '%{http_code}' https://${blocked_host}"
      The status should not be success
    End
  End

  Describe 'name+port form (--allow-egress <hostname>:443)'
    start_with_name_egress() {
      ./bin/ai-sandbox.sh start --allow-egress "${test_hostname}:443" \
        --quiet 2> ./.ai-sandbox.allow-egress-name.startup.log || {
        cat ./.ai-sandbox.allow-egress-name.startup.log 1>&2
        echo "Container (with --allow-egress ${test_hostname}:443) failed to become ready" 1>&2
        return 1
      }
      return 0
    }
    stop_with_name_egress() {
      ./bin/ai-sandbox.sh stop --allow-egress "${test_hostname}:443" --quiet 2>/dev/null || true
    }

    BeforeAll 'start_with_name_egress'
    AfterAll 'stop_with_name_egress'

    It 'reaches the allow-egress hostname on the allow-egress port'
      Skip if 'network probe opted out via AI_SANDBOX_SKIP_EGRESS_NET' [ -n "${AI_SANDBOX_SKIP_EGRESS_NET:-}" ]
      When call ./bin/ai-sandbox.sh --quiet user-exec zsh -c "curl -sS --max-time 5 -o /dev/null -w '%{http_code}' https://${test_hostname}"
      The status should be success
      The output should match pattern '*[1-5][0-9][0-9]*'
    End

    It 'emits an ACCEPT rule for the resolved IP, not a literal hostname match'
      # Confirms 002-wire-allow-egress-into-firewall.md's design: the
      # name-form entry is resolved once, inside the container, at
      # firewall-init time (via getent ahostsv4, using the same resolver the
      # container's own traffic uses) -- iptables itself never sees the
      # literal hostname string. Resolves the hostname inside the container
      # too (not on the host runner) so this check uses the exact same
      # resolver/answer the firewall-init sidecar itself used, avoiding any
      # host/container DNS-answer mismatch (split-horizon DNS etc.).
      #
      # Can't use `root-exec iptables ...` here: docker-compose.yaml's
      # ai-sandbox service deliberately never holds CAP_NET_ADMIN (see its
      # "SECURITY (security-001)" comment) -- only the one-shot
      # `firewall-init` sidecar does, and it has already applied the rules
      # and exited by the time the container is ready. Instead, spin up a
      # throwaway `--rm` container that joins the running sandbox's network
      # namespace (`--network container:<name>`) with `--cap-add=NET_ADMIN`,
      # exactly the same out-of-band inspection technique
      # 002-wire-allow-egress-into-firewall.md's own manual validation used
      # (see that task doc's Status), overriding the image's s6-overlay
      # ENTRYPOINT so it runs a single `iptables` invocation and exits
      # rather than re-running container init inside the shared namespace.
      Skip if 'network probe opted out via AI_SANDBOX_SKIP_EGRESS_NET' [ -n "${AI_SANDBOX_SKIP_EGRESS_NET:-}" ]
      allow_egress_rule_targets_resolved_ip() {
        local resolved rules ip img
        resolved="$(./bin/ai-sandbox.sh --quiet user-exec zsh -c "getent ahostsv4 ${test_hostname}" 2>/dev/null \
          | grep -oE '^[0-9]{1,3}(\.[0-9]{1,3}){3}' | sort -u)"
        [ -n "${resolved}" ] || return 1
        img="$(docker inspect -f '{{.Image}}' "${sandbox_container_name}" 2>/dev/null)"
        [ -n "${img}" ] || return 1
        rules="$(docker run --rm --network "container:${sandbox_container_name}" --cap-add=NET_ADMIN \
          --user root --entrypoint iptables "${img}" -S OUTPUT 2>/dev/null)"
        [ -n "${rules}" ] || return 1
        # The resolved hostname string must never appear as an iptables
        # match target -- that would mean resolution did not happen and
        # iptables is (uselessly, since it has no DNS resolver) trying to
        # match the literal name.
        if echo "${rules}" | grep -q -- "${test_hostname}"; then
          return 1
        fi
        while IFS= read -r ip; do
          [ -n "${ip}" ] || continue
          echo "${rules}" | grep -q -- "-d ${ip}/32 .*--dport 443 " && return 0
        done <<< "${resolved}"
        return 1
      }
      When call allow_egress_rule_targets_resolved_ip
      The status should be success
    End
  End

  Describe 'multiple --allow-egress flags accumulate'
    start_with_multiple_egress() {
      ./bin/ai-sandbox.sh start --allow-egress "${test_ip}:443" --allow-egress "${test_hostname}:443" \
        --quiet 2> ./.ai-sandbox.allow-egress-multi.startup.log || {
        cat ./.ai-sandbox.allow-egress-multi.startup.log 1>&2
        echo "Container (with two --allow-egress flags) failed to become ready" 1>&2
        return 1
      }
      return 0
    }
    stop_with_multiple_egress() {
      ./bin/ai-sandbox.sh stop --allow-egress "${test_ip}:443" --allow-egress "${test_hostname}:443" \
        --quiet 2>/dev/null || true
    }

    BeforeAll 'start_with_multiple_egress'
    AfterAll 'stop_with_multiple_egress'

    It 'reaches the first --allow-egress entry'
      Skip if 'network probe opted out via AI_SANDBOX_SKIP_EGRESS_NET' [ -n "${AI_SANDBOX_SKIP_EGRESS_NET:-}" ]
      When call ./bin/ai-sandbox.sh --quiet user-exec zsh -c "curl -sS --max-time 5 -o /dev/null -w '%{http_code}' https://${test_ip}"
      The status should be success
      The output should match pattern '*[1-5][0-9][0-9]*'
    End

    It 'reaches the second --allow-egress entry'
      Skip if 'network probe opted out via AI_SANDBOX_SKIP_EGRESS_NET' [ -n "${AI_SANDBOX_SKIP_EGRESS_NET:-}" ]
      When call ./bin/ai-sandbox.sh --quiet user-exec zsh -c "curl -sS --max-time 5 -o /dev/null -w '%{http_code}' https://${test_hostname}"
      The status should be success
      The output should match pattern '*[1-5][0-9][0-9]*'
    End
  End
End
