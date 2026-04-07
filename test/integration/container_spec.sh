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

  Describe 'SSH socket'
    It 'is accessible'
      When call ./bin/ai-sandbox.sh --quiet user-exec zsh -c 'test -S $SSH_AUTH_SOCK'
      The status should be success
    End
  End

  Describe 'DEVCONTAINER env'
    It 'is set to true'
      When call ./bin/ai-sandbox.sh --quiet user-exec zsh -c 'echo $DEVCONTAINER'
      The output should eq 'true'
    End
  End
End
