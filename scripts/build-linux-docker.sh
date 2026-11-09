#!/usr/bin/env bash
# build-linux-docker.sh [amd64|arm64] — runs build-linux.sh in the pinned
# Alpine image. Default amd64 (the only Linux target Ingress ships); arm64
# is handy for a quick native check on Apple Silicon.
. "$(dirname "$0")/lib.sh"
arch=${1:-amd64}
docker run --rm --platform "linux/$arch" \
  -e INGRESS_DEPS_COMMIT="$(git -C "$ROOT" rev-parse --verify -q HEAD || echo unknown)" \
  -v "$ROOT:/src" -w /src "$ALPINE_IMAGE" \
  sh -c 'apk add --no-cache bash >/dev/null && bash scripts/build-linux.sh'
