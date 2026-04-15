# shellcheck shell=bash
# shellcheck disable=SC2016 # we want unexpanded shell expressions sent into the container

Describe 'Docker socket proxy (--docker)' integration
  start_with_proxy() {
    ./bin/ai-sandbox.sh --docker start --quiet 2> ./.ai-sandbox.proxy.startup.log || {
      cat ./.ai-sandbox.proxy.startup.log 1>&2
      echo "Container (with --docker) failed to become ready" 1>&2
      return 1
    }
    return 0
  }
  stop_with_proxy() {
    ./bin/ai-sandbox.sh --docker stop --quiet 2>/dev/null || true
    docker rm -f ai-sandbox-docker-proxy >/dev/null 2>&1 || true
  }

  BeforeAll 'start_with_proxy'
  AfterAll 'stop_with_proxy'

  Describe 'docker CLI'
    It 'is installed in the container'
      When call ./bin/ai-sandbox.sh --docker --quiet user-exec zsh -c 'docker --version'
      The output should include 'Docker version'
      The status should be success
    End

    It 'has DOCKER_HOST pointing at the socket proxy'
      When call ./bin/ai-sandbox.sh --docker --quiet user-exec zsh -c 'echo $DOCKER_HOST'
      The output should equal 'tcp://docker-socket-proxy:2375'
      The status should be success
    End
  End

  Describe 'proxied Docker API'
    It 'docker version reaches the host daemon through the proxy'
      When call ./bin/ai-sandbox.sh --docker --quiet user-exec zsh -c 'docker version --format "{{.Server.Version}}"'
      The output should match pattern '[0-9]*.[0-9]*.[0-9]*'
      The status should be success
    End

    It 'pulls and runs hello-world end-to-end'
      When call ./bin/ai-sandbox.sh --docker --quiet user-exec zsh -c 'docker pull hello-world >/dev/null && docker run --rm hello-world'
      The output should include 'Hello from Docker'
      The status should be success
    End

    It 'denies disallowed endpoints (swarm)'
      # Proxy does not whitelist SWARM endpoints, so this must fail with 403.
      When call ./bin/ai-sandbox.sh --docker --quiet user-exec zsh -c 'docker swarm init 2>&1 || true'
      The output should include '403'
    End
  End
End
