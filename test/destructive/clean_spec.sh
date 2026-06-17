# shellcheck shell=bash
# shellcheck disable=SC2034,SC2317,SC2329 # ShellSpec DSL — vars/functions invoked indirectly

# Destructive: these tests create and delete real Docker images.
# Run via `make test.destructive` which explains the risk and asks for confirmation.

Describe 'do_clean_images()' destructive
  Include "$PWD/bin/ai-sandbox.sh"

  # Tag a small image under the ai-sandbox:* namespace so there is always
  # something for the clean function to remove.
  seed_images() {
    docker image tag ubuntu:latest ai-sandbox:destructive-test-a 2>/dev/null || true
    docker image tag ubuntu:latest ai-sandbox:destructive-test-b 2>/dev/null || true
  }
  # Safety net: remove the seeds in case the test itself fails before cleaning.
  unseed_images() {
    docker image rm -f ai-sandbox:destructive-test-a \
                       ai-sandbox:destructive-test-b 2>/dev/null || true
  }
  count_sandbox_images() {
    docker images ai-sandbox --format '{{.Repository}}:{{.Tag}}' 2>/dev/null \
      | wc -l | tr -d ' '
  }

  BeforeAll 'seed_images'
  AfterAll 'unseed_images'

  It 'removes all ai-sandbox:* images from the local daemon'
    QUIET=1
    When call do_clean_images
    The status should be success
    The output should include 'deleted images'
    The output should include 'ai-sandbox:'
  End

  It 'leaves no ai-sandbox images behind'
    When call count_sandbox_images
    The output should eq '0'
  End
End
