#!/usr/bin/env bash
# gen-manifest.sh [DIST] — prints the builtinManifest entries for Ingress'
# components_manifest.go from the archives in DIST (default dist/), for the
# release tagged r$INGRESS_REV.
. "$(dirname "$0")/lib.sh"
dir=${1:-$DIST}
tag=r$INGRESS_REV
for tool in openfortivpn openconnect; do
  case $tool in
    openfortivpn) ver=$(ofv_version) ;;
    openconnect)  ver=$(oc_version) ;;
  esac
  printf '\t"%s": {\n' "$tool"
  for plat in darwin-arm64 darwin-amd64 linux-amd64; do
    f=$dir/$tool-$ver-$plat.tar.gz
    [ -f "$f" ] || { printf '\t\t// %s: not built\n' "$plat"; continue; }
    printf '\t\t"%s": {Version: "%s", URL: depsURL("%s", "%s"), SHA256: "%s"},\n' \
      "${plat/-//}" "$ver" "$tag" "$(basename "$f")" "$(sha256_of "$f")"
  done
  printf '\t},\n'
done
