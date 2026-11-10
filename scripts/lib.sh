# Shared helpers; sourced by the build scripts.
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
# shellcheck source=../versions.env
. "$ROOT/versions.env"
CACHE=$ROOT/.cache
DIST=$ROOT/dist
mkdir -p "$CACHE" "$DIST"

log() { printf '\n==> %s\n' "$*" >&2; }
die() { printf 'error: %s\n' "$*" >&2; exit 1; }

sha256_of() {
  if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | cut -d' ' -f1
  else shasum -a 256 "$1" | cut -d' ' -f1; fi
}

# fetch URL SHA256 NAME -> path of a verified file in the cache
fetch() {
  local url=$1 want=$2 out=$CACHE/$3
  if [ ! -f "$out" ] || [ "$(sha256_of "$out")" != "$want" ]; then
    log "download $url"
    curl -fsSL --retry 3 -o "$out.tmp" "$url"
    mv "$out.tmp" "$out"
  fi
  local got
  got=$(sha256_of "$out")
  [ "$got" = "$want" ] || die "sha256 mismatch for $url: got $got, want $want"
  echo "$out"
}

fetch_vpnc_script() {
  fetch "https://gitlab.com/openconnect/vpnc-scripts/-/raw/$VPNC_SCRIPTS_COMMIT/vpnc-script" \
    "$VPNC_SCRIPT_SHA256" "vpnc-script-$VPNC_SCRIPTS_COMMIT"
}

# The vpnc-scripts license isn't pinned by hash separately: it's fetched from
# the same pinned commit.
fetch_vpnc_license() {
  local out=$CACHE/vpnc-scripts-COPYING-$VPNC_SCRIPTS_COMMIT
  [ -f "$out" ] || curl -fsSL --retry 3 -o "$out" \
    "https://gitlab.com/openconnect/vpnc-scripts/-/raw/$VPNC_SCRIPTS_COMMIT/COPYING"
  echo "$out"
}

apply_patches() { # DIR PATCHDIR
  local p
  for p in "$2"/*.patch; do
    [ -e "$p" ] || continue
    log "patch $(basename "$p")"
    patch -d "$1" -p1 --forward < "$p"
  done
}

oc_version()  { echo "$OPENCONNECT_VERSION-ingress.$INGRESS_REV"; }
ofv_version() { echo "$OPENFORTIVPN_VERSION-ingress.$INGRESS_REV"; }
sstpc_version() { echo "$SSTP_CLIENT_VERSION-ingress.$INGRESS_REV"; }
