# Hermes OpenCode Go compatibility

The `2026-09-08-opencode-session` image backports upstream
[PR #101864](https://github.com/NousResearch/hermes-agent/pull/101864) onto
the existing 0.20.4 base image. OpenCode Go rejected MiniMax M3 calls with
HTTP 400 `MissingSessionID` when `x-opencode-session` was absent.

The patch is pinned by commit and SHA-256. The inline build adapts the
upstream helper imports to 0.20.4 and wraps its existing request builder.
Main requests and auxiliary requests use the conversation root, preserving
the header across context compression. Both auxiliary Anthropic and
Responses adapters forward the header to the SDK. The model, base-image
digest, STT configuration and Nix lockfile are unchanged.

Remove this backport when upgrading to an upstream image containing the
fix, and rerun the regression test. A running gateway healthcheck alone
does not establish model connectivity.

## Local validation

Build the exact inline Dockerfile locally without resolving production
secret paths. Run these commands from the repository root:

```bash
hermes_check_dir="$(mktemp -d)"
docker compose -f services/hermes/docker-compose.yml config \
  --no-env-resolution --no-path-resolution --format json |
  python3 -c 'import json,sys; print(json.load(sys.stdin)["services"]["hermes"]["build"]["dockerfile_inline"], end="")' \
  > "$hermes_check_dir/Dockerfile"
docker build --platform linux/amd64 \
  -t homelab/hermes-agent:2026-09-08-opencode-session \
  -f "$hermes_check_dir/Dockerfile" "$hermes_check_dir"
docker run --rm --platform linux/amd64 --network none \
  --tmpfs /opt/data:uid=10000,gid=10000,mode=0700 --user 10000:10000 \
  -e PYTHONPATH=/opt/hermes \
  --mount "type=bind,source=$(pwd)/services/hermes/test_opencode_session.py,target=/tmp/test_opencode_session.py,readonly" \
  --entrypoint /opt/hermes/.venv/bin/python \
  homelab/hermes-agent:2026-09-08-opencode-session /tmp/test_opencode_session.py
```

The test uses the real Hermes builders and Anthropic SDK with a mock HTTP
relay. It verifies MiniMax M3 streaming, auxiliary compression and the next
turn after session rotation. It requires no credentials and cannot reach
the network. The six upstream regression cases included by the patch were
also validated in a disposable test image, with pytest kept out of the
production image's Python environment.

Production deployment remains exclusively `scripts/rollout.sh deploy
kodo.witek.sh`, subject to the repository's authorization and frozen-SHA
requirements. After rollout, verify an actual provider response as well
as the installed host healthcheck; local tests use a mock provider.
