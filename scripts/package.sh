#!/usr/bin/env bash
# package.sh TOOL VERSION OS ARCH STAGEDIR
# Packs STAGEDIR (bin/, libexec/, LICENSES/, SOURCES.txt at its root — the
# layout Ingress' installer expects, no wrapping directory) into
# dist/TOOL-VERSION-OS-ARCH.tar.gz, owned by root, without macOS metadata.
. "$(dirname "$0")/lib.sh"
tool=$1 version=$2 os=$3 arch=$4 stage=$5
out=$DIST/$tool-$version-$os-$arch.tar.gz
[ -x "$stage/bin/$tool" ] || die "$stage/bin/$tool missing or not executable"

entries=(bin LICENSES SOURCES.txt)
[ -d "$stage/libexec" ] && entries=(bin libexec LICENSES SOURCES.txt)

if tar --version 2>/dev/null | grep -q 'GNU tar'; then
  tar -C "$stage" --sort=name --owner=0 --group=0 --numeric-owner -czf "$out" "${entries[@]}"
else # bsdtar (macOS)
  COPYFILE_DISABLE=1 tar -C "$stage" --no-mac-metadata --uid 0 --gid 0 --uname root --gname root -czf "$out" "${entries[@]}"
fi
log "packed $(basename "$out") sha256:$(sha256_of "$out")"
