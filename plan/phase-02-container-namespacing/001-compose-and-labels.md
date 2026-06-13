# Task 001: Docker Compose Parameterization and New Labels

**Phase:** 2 — Container Namespacing
**Tier:** sonnet-med

## Purpose and scope

Update `docker/docker-compose.yaml` to parameterize the container name and add the three new Docker labels that power multi-instance management. This is a self-contained, mechanical change to a single file; it can be reviewed independently of the bash function changes in task 002.

## Requirements

### `docker/docker-compose.yaml`

**Change `container_name`:**
```yaml
# Before:
container_name: ai-sandbox

# After:
container_name: ai-sandbox-${SANDBOX_NAME}
```

`SANDBOX_NAME` is exported by `parse_options()` (Phase 1) and forwarded to the compose environment. The compose project is also scoped (`-p ai-sandbox-${SANDBOX_NAME}`) in `index.sh`, so the sidecar services in overlay files (proxy, chromium) are automatically namespaced within the compose project.

**Add new labels:**
```yaml
labels:
  # existing labels unchanged:
  ai.sandbox.ssh-auth-sock-host: "${SSH_AUTH_SOCK}"
  ai.sandbox.profile-hash: "${PROFILE_COMPOSITION_HASH:-}"
  ai.sandbox.mode: "${EFFECTIVE_MODE:-mirror}"
  ai.sandbox.no-isolate-config: "${NO_ISOLATE_CONFIG:-false}"
  ai.sandbox.docker-proxy: "${EFFECTIVE_PROXY:-false}"
  # new labels:
  ai.sandbox.managed: "true"
  ai.sandbox.instance: "${SANDBOX_NAME}"
  ai.sandbox.profiles: "${SANDBOX_PROFILES:-}"
```

`SANDBOX_PROFILES` is a comma-separated string of profile names (e.g., `"base,docker"`) exported by `parse_options()` for `create` invocations. On subsequent `start` invocations, `index.sh` reads this label and reconstructs the PROFILES array before running profile-installer.

**Export `SANDBOX_NAME` and `SANDBOX_PROFILES`:** These must be present in the compose environment. They are exported by Phase 1's `parse_options()`, so no additional action is needed in the compose file itself — just confirm the variables flow through.

### Verify compose overlay files are unaffected

`docker-compose.chromium.yaml`, `docker-compose.isolate-config.yaml`, `docker-compose.shared-config.yaml`, `docker-compose.proxy.yaml`, and `docker-compose.generated.yaml` all extend the `ai-sandbox` *service key* (not the container name), so they do not need changes. Confirm by reviewing each overlay's `services:` key — it should reference the service name `ai-sandbox`, not the `container_name`.

## Assumptions

- `SANDBOX_NAME` will always be non-empty when compose is invoked (enforced by Phase 1 dispatch — global commands that don't need compose never reach this point).
- `SANDBOX_PROFILES` may be empty on a `start` invocation against an existing container (when the profiles are read from the label instead); the `:-` default handles this.
- The image tag (`ai-sandbox:profile-<hash>`) stays `AI_SANDBOX_IMAGE_TAG` — unchanged. Images are shared.

## References

- `docker/docker-compose.yaml` — file to modify
- Design doc: `/Users/zane/.claude/plans/i-have-a-series-drifting-hedgehog.md` — Container/image namespacing section

## Validation

```bash
make build
make lint

# Confirm container_name is parameterized:
grep 'container_name' docker/docker-compose.yaml
# Expected: container_name: ai-sandbox-${SANDBOX_NAME}

# Confirm new labels are present:
grep 'ai.sandbox.managed\|ai.sandbox.instance\|ai.sandbox.profiles' docker/docker-compose.yaml
# Expected: 3 matching lines

# Confirm docker compose config renders correctly (requires SANDBOX_NAME to be set):
SANDBOX_NAME=test SANDBOX_PROFILES="" EFFECTIVE_MODE=mirror NO_ISOLATE_CONFIG=false \
  EFFECTIVE_PROXY=false PROFILE_COMPOSITION_HASH=abc123 SSH_AUTH_SOCK=/tmp/s \
  HOST_USER=user HOST_UID=1000 HOST_GID=1000 HOST_ARCH=arm64 HOST_HOME=/Users/user \
  HOST_TZ=UTC GIT_USER_NAME=Test GIT_USER_EMAIL=t@t.com AI_SANDBOX_IMAGE_TAG=ai-sandbox:profile-abc123 \
  AI_SANDBOX_DOCKERFILE=docker/Dockerfile TOOL_CACHE_DIR=/tmp/tc \
  docker compose -f docker/docker-compose.yaml config 2>&1 | grep 'container_name'
# Expected: container_name: ai-sandbox-test
```
