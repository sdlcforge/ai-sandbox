# shellcheck shell=bash

spec_helper_configure() {
  # Set __SOURCED__ so Include'd scripts don't execute top-level code
  export __SOURCED__=1
}

# Helper to run commands inside the ai-sandbox container
container_exec() {
  docker exec ai-sandbox "$@"
}
