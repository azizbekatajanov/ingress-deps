#!/usr/bin/env bash
# tests/sstpc-init.sh SSTPC — sstpc must get past its OpenSSL setup on a
# machine without our build tree: the legacy provider (MD4 for MS-CHAPv2)
# has to be built in, not a module looked up in the build directory.
# Nothing listens on 127.0.0.1:9, so a working build fails *later*, on
# connect.
set -uo pipefail
out=$(echo pw | OPENSSL_MODULES=/nonexistent timeout 10 "$1" --log-stderr --user u --password - 127.0.0.1:9 2>&1)
if grep -q "Could not load legacy crypto provider\|Could not initialize" <<<"$out"; then
  echo "FAIL: sstpc can't initialize OpenSSL:"; echo "$out"; exit 1
fi
echo "ok   sstpc initializes OpenSSL (legacy provider built in)"
