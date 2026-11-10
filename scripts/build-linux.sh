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
  tar perl libxml2-dev libxml2-static zlib-dev zlib-static xz-dev xz-static libevent-dev libevent-static >/dev/null

JOBS=$(nproc)
WORK=/tmp/build-linux-$goarch
DEPS=$WORK/deps
rm -rf "$WORK"; mkdir -p "$WORK" "$DEPS"
export PKG_CONFIG="pkg-config --static" LDFLAGS="-static"

# OpenSSL from source, like macOS: Alpine's package keeps the legacy
# provider (MD4, which sstpc needs for MS-CHAPv2) in a separate .so that a
# static binary can't load. no-module builds it into libcrypto.
log "OpenSSL $OPENSSL_VERSION ($goarch)"
tar -C "$WORK" -xzf "$(fetch "$OPENSSL_URL" "$OPENSSL_SHA256" "openssl-$OPENSSL_VERSION.tar.gz")"
(
  cd "$WORK/openssl-$OPENSSL_VERSION"
  ./Configure "linux-$(uname -m)" no-shared no-module no-tests no-docs no-apps no-autoload-config \
    --prefix="$DEPS" --libdir=lib --openssldir=/etc/ssl >/dev/null
  make -j"$JOBS" >/dev/null
  make install_sw >/dev/null
)
export PKG_CONFIG_PATH="$DEPS/lib/pkgconfig" CPPFLAGS="-I$DEPS/include"
export LIBRARY_PATH="$DEPS/lib"

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

log "sstp-client $SSTP_CLIENT_VERSION ($goarch)"
tar -C "$WORK" -xzf "$(fetch "$SSTP_CLIENT_URL" "$SSTP_CLIENT_SHA256" "sstp-client-$SSTP_CLIENT_VERSION.tar.gz")"
SST=$WORK/sstp-client-$SSTP_CLIENT_VERSION
apply_patches "$SST" "$ROOT/patches/sstp-client"
(
  cd "$SST"
  ./configure --prefix=/opt/ingress-sstpc --disable-shared --enable-static --disable-ppp-plugin \
    --with-runtime-dir=/var/run/sstpc --with-openssl="$DEPS" >/dev/null
  # configure puts -levent into LDFLAGS, which -all-static replaces here.
  make -j"$JOBS" LDFLAGS="-all-static" LIBS="-lutil -levent -lssl -lcrypto" >/dev/null
)

TLS_SOURCE="OpenSSL $OPENSSL_VERSION (static, built in)  $OPENSSL_URL  sha256:$OPENSSL_SHA256"

check_binary() {
  file "$1" | grep -q 'statically linked' || die "$1 is not statically linked: $(file "$1")"
}

stage_common() { # STAGE TOOL
  mkdir -p "$1/bin" "$1/LICENSES"
  cp "$WORK/openssl-$OPENSSL_VERSION/LICENSE.txt" "$1/LICENSES/OpenSSL-Apache-2.0.txt"
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

SSS=$WORK/stage-sstpc
EVENT_SOURCE="libevent (static) from Alpine package $(apk list -I libevent-static 2>/dev/null | head -1 | cut -d' ' -f1), image $ALPINE_IMAGE"
stage_common "$SSS" sstpc
install -m 0755 "$SST/src/sstpc" "$SSS/bin/sstpc"
cp "$SST/COPYING" "$SSS/LICENSES/sstp-client-GPL-2.0.txt"
cp /usr/share/licenses/libevent*/LICENSE "$SSS/LICENSES/libevent-BSD-3-Clause.txt" 2>/dev/null \
  || curl -fsSL -o "$SSS/LICENSES/libevent-BSD-3-Clause.txt" "https://raw.githubusercontent.com/libevent/libevent/release-$LIBEVENT_VERSION-stable/LICENSE"

for b in "$OCS/bin/openconnect" "$OFS/bin/openfortivpn" "$SSS/bin/sstpc"; do
  strip "$b"
  check_binary "$b"
  "$b" --version 2>&1 | head -2
done

"$ROOT/scripts/package.sh" openconnect "$(oc_version)" linux "$goarch" "$OCS"
"$ROOT/scripts/package.sh" openfortivpn "$(ofv_version)" linux "$goarch" "$OFS"
"$ROOT/scripts/package.sh" sstpc "$(sstpc_version)" linux "$goarch" "$SSS"
