#!/usr/bin/env bash
# build-linux.sh — runs INSIDE the pinned Alpine container (see
# build-linux-docker.sh). Builds fully static (musl) openconnect and
# openfortivpn against Alpine's static OpenSSL/libxml2/zlib, so they run on
# any Linux distribution. openfortivpn still needs the system's pppd at
# runtime (/usr/sbin/pppd, package "ppp").
. "$(dirname "$0")/lib.sh"
. "$(dirname "$0")/sources.sh"

case $(uname -m) in
  x86_64) goarch=amd64 ;;
  aarch64) goarch=arm64 ;;
  *) die "unsupported $(uname -m)" ;;
esac

log "apk packages"
apk add --no-cache bash build-base autoconf automake libtool pkgconf linux-headers curl patch file \
  tar openssl-dev openssl-libs-static libxml2-dev libxml2-static zlib-dev zlib-static xz-dev xz-static >/dev/null

JOBS=$(nproc)
WORK=/tmp/build-linux-$goarch
rm -rf "$WORK"; mkdir -p "$WORK"
export PKG_CONFIG="pkg-config --static" LDFLAGS="-static"

log "openconnect $OPENCONNECT_VERSION ($goarch)"
tar -C "$WORK" -xzf "$(fetch "$OPENCONNECT_URL" "$OPENCONNECT_SHA256" "openconnect-$OPENCONNECT_VERSION.tar.gz")"
OC=$WORK/openconnect-$OPENCONNECT_VERSION
apply_patches "$OC" "$ROOT/patches/openconnect"
(
  cd "$OC"
  ./configure --prefix=/opt/ingress-openconnect \
    --disable-shared --enable-static --disable-nls --disable-docs \
    --without-gnutls --with-builtin-json \
    --without-lz4 --without-libproxy --without-stoken --without-libpcsclite \
    --without-libpskc --without-gssapi \
    --with-vpnc-script=/opt/ingress/components/openconnect/libexec/vpnc-script >/dev/null
  # libtool reads plain -static as "static libtool libraries only";
  # -all-static is what makes the final executable fully static.
  make -j"$JOBS" LDFLAGS="-all-static" >/dev/null
)

log "openfortivpn $OPENFORTIVPN_VERSION ($goarch)"
tar -C "$WORK" -xzf "$(fetch "$OPENFORTIVPN_URL" "$OPENFORTIVPN_SHA256" "openfortivpn-$OPENFORTIVPN_VERSION.tar.gz")"
OFV=$WORK/openfortivpn-$OPENFORTIVPN_VERSION
(
  cd "$OFV"
  ./autogen.sh >/dev/null 2>&1
  ./configure --prefix=/opt/ingress-openfortivpn --with-pppd=/usr/sbin/pppd >/dev/null
  make -j"$JOBS" >/dev/null
)

ossl=$(apk info -e openssl-libs-static >/dev/null && apk list -I openssl-libs-static 2>/dev/null | head -1 | cut -d' ' -f1)
TLS_SOURCE="OpenSSL (static) from Alpine package $ossl, image $ALPINE_IMAGE"

check_binary() {
  file "$1" | grep -q 'statically linked' || die "$1 is not statically linked: $(file "$1")"
}

stage_common() { # STAGE TOOL
  mkdir -p "$1/bin" "$1/LICENSES"
  cp /usr/share/licenses/openssl*/LICENSE* "$1/LICENSES/OpenSSL-Apache-2.0.txt" 2>/dev/null \
    || curl -fsSL -o "$1/LICENSES/OpenSSL-Apache-2.0.txt" https://www.apache.org/licenses/LICENSE-2.0.txt
  write_sources "$1/SOURCES.txt" "$2"
}

OCS=$WORK/stage-openconnect
stage_common "$OCS" openconnect
install -m 0755 "$OC/openconnect" "$OCS/bin/openconnect"
mkdir -p "$OCS/libexec"
install -m 0755 "$(fetch_vpnc_script)" "$OCS/libexec/vpnc-script"
install -m 0755 "$OC/trojans/hipreport.sh" "$OCS/libexec/hipreport.sh"
cp "$OC/COPYING.LGPL" "$OCS/LICENSES/openconnect-LGPL-2.1.txt"
cp "$(fetch_vpnc_license)" "$OCS/LICENSES/vpnc-scripts-GPL-2.0.txt"

OFS=$WORK/stage-openfortivpn
stage_common "$OFS" openfortivpn
install -m 0755 "$OFV/openfortivpn" "$OFS/bin/openfortivpn"
cp "$OFV/LICENSE" "$OFS/LICENSES/openfortivpn-GPL-3.0.txt"
cp "$OFV/LICENSE.OpenSSL" "$OFS/LICENSES/openfortivpn-OpenSSL-exception.txt"

for b in "$OCS/bin/openconnect" "$OFS/bin/openfortivpn"; do
  strip "$b"
  check_binary "$b"
  "$b" --version 2>&1 | head -2
done

"$ROOT/scripts/package.sh" openconnect "$(oc_version)" linux "$goarch" "$OCS"
"$ROOT/scripts/package.sh" openfortivpn "$(ofv_version)" linux "$goarch" "$OFS"
