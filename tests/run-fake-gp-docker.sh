#!/usr/bin/env bash
# tests/run-fake-gp-docker.sh ARCH — tests dist/openconnect-*-linux-ARCH
# against the strict fake GP server, then shows that Debian's stock
# (unpatched) openconnect fails the SAML cases.
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
. "$ROOT/versions.env"
arch=${1:-amd64}
docker run --rm --platform "linux/$arch" -v "$ROOT:/src:ro" python:3.12-slim bash -c '
  set -e
  apt-get update -qq >/dev/null && apt-get install -y -qq curl openconnect >/dev/null 2>&1
  pip install -q flask 2>/dev/null
  mkdir -p /oc && tar -C /oc -xzf /src/.cache/openconnect-'"$OPENCONNECT_VERSION"'.tar.gz
  mkdir -p /ours && tar -C /ours -xzf /src/dist/openconnect-'"$OPENCONNECT_VERSION-ingress.$INGRESS_REV"'-linux-'"$arch"'.tar.gz
  export OC_SRC=/oc/openconnect-'"$OPENCONNECT_VERSION"'
  echo "== ingress build: $(/ours/bin/openconnect --version 2>&1 | head -1)"
  bash /src/tests/fake-gp.sh /ours/bin/openconnect pass
  echo "== stock Debian openconnect (unpatched): $(openconnect --version 2>&1 | head -1)"
  bash /src/tests/fake-gp.sh "$(command -v openconnect)" fail
'
