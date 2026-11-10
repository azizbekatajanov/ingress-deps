#!/usr/bin/env bash
# build-macos.sh ARCH   (ARCH: arm64 | x86_64)
#
# Builds openconnect (with our patches) and openfortivpn for macOS against a
# static OpenSSL, and packs both into dist/. x86_64 is cross-compiled when
# run on Apple Silicon (no Intel runner needed). Only system libraries
# (libxml2, zlib, libiconv, frameworks) are linked dynamically — nothing from
# Homebrew.
. "$(dirname "$0")/lib.sh"
. "$(dirname "$0")/sources.sh"

arch=${1:?usage: build-macos.sh arm64|x86_64}
case $arch in
  arm64)  ossl_target=darwin64-arm64-cc;  host=aarch64-apple-darwin; goarch=arm64 ;;
  x86_64) ossl_target=darwin64-x86_64-cc; host=x86_64-apple-darwin;  goarch=amd64 ;;
  *) die "unknown arch $arch" ;;
esac

export MACOSX_DEPLOYMENT_TARGET
SDK=$(xcrun --sdk macosx --show-sdk-path)
export CC="clang -arch $arch -isysroot $SDK -mmacosx-version-min=$MACOSX_DEPLOYMENT_TARGET"
JOBS=$(sysctl -n hw.ncpu)

WORK=$ROOT/build/darwin-$goarch
DEPS=$WORK/deps
rm -rf "$WORK"; mkdir -p "$WORK" "$DEPS"
# Only our own .pc files — never Homebrew's.
export PKG_CONFIG_LIBDIR=$DEPS/lib/pkgconfig PKG_CONFIG_PATH=

# --- OpenSSL (static) --------------------------------------------------------
log "OpenSSL $OPENSSL_VERSION ($arch)"
tar -C "$WORK" -xzf "$(fetch "$OPENSSL_URL" "$OPENSSL_SHA256" "openssl-$OPENSSL_VERSION.tar.gz")"
(
  cd "$WORK/openssl-$OPENSSL_VERSION"
  # CC already carries -arch; OpenSSL's darwin targets add their own too,
  # so hand it a plain clang + the flags it doesn't set.
  # --openssldir=/etc/ssl: trust store = macOS's own /etc/ssl/cert.pem
  # (kept up to date by the OS). Without it OPENSSLDIR is baked in as this
  # build directory and no public CA verifies at all.
  # no-autoload-config: never read an openssl.cnf — these binaries run as
  # root, and macOS' /etc/ssl/openssl.cnf is LibreSSL's anyway.
  # no-module: providers (legacy too: sstpc needs its MD4 for MS-CHAPv2)
  # are built into libcrypto; a loadable module would be looked for in this
  # build directory, which doesn't exist on users' machines.
  CC=clang ./Configure "$ossl_target" no-shared no-module no-tests no-docs no-apps no-autoload-config \
    --prefix="$DEPS" --openssldir=/etc/ssl --libdir=lib \
    -isysroot "$SDK" -mmacosx-version-min="$MACOSX_DEPLOYMENT_TARGET" >/dev/null
  make -j"$JOBS" >/dev/null
  make install_sw >/dev/null
)

# --- openconnect -------------------------------------------------------------
oc_default_script="/Library/Application Support/Ingress/components/openconnect/libexec/vpnc-script"
log "openconnect $OPENCONNECT_VERSION ($arch)"
tar -C "$WORK" -xzf "$(fetch "$OPENCONNECT_URL" "$OPENCONNECT_SHA256" "openconnect-$OPENCONNECT_VERSION.tar.gz")"
OC=$WORK/openconnect-$OPENCONNECT_VERSION
apply_patches "$OC" "$ROOT/patches/openconnect"
(
  cd "$OC"
  # libxml2 and zlib come from the macOS SDK (no .pc files there).
  LIBXML2_CFLAGS="-I$SDK/usr/include/libxml2" LIBXML2_LIBS="-lxml2" \
  ZLIB_CFLAGS="" ZLIB_LIBS="-lz" \
  ./configure --host="$host" --prefix=/opt/ingress-openconnect \
    --disable-shared --enable-static --disable-nls --disable-docs \
    --without-gnutls --with-builtin-json \
    --without-lz4 --without-libproxy --without-stoken --without-libpcsclite \
    --without-libpskc --without-gssapi \
    --with-vpnc-script="$oc_default_script" >/dev/null
  make -j"$JOBS" >/dev/null
)

# --- openfortivpn ------------------------------------------------------------
log "openfortivpn $OPENFORTIVPN_VERSION ($arch)"
tar -C "$WORK" -xzf "$(fetch "$OPENFORTIVPN_URL" "$OPENFORTIVPN_SHA256" "openfortivpn-$OPENFORTIVPN_VERSION.tar.gz")"
OFV=$WORK/openfortivpn-$OPENFORTIVPN_VERSION
(
  cd "$OFV"
  ./autogen.sh >/dev/null 2>&1
  ./configure --host="$host" --prefix=/opt/ingress-openfortivpn >/dev/null
  make -j"$JOBS" >/dev/null
)

# --- libevent (static) + sstp-client ------------------------------------------
log "libevent $LIBEVENT_VERSION ($arch)"
tar -C "$WORK" -xzf "$(fetch "$LIBEVENT_URL" "$LIBEVENT_SHA256" "libevent-$LIBEVENT_VERSION-stable.tar.gz")"
(
  cd "$WORK/libevent-$LIBEVENT_VERSION-stable"
  ./configure --host="$host" --prefix="$DEPS" --disable-shared --enable-static \
    --disable-openssl --disable-samples --disable-libevent-regress --disable-debug-mode >/dev/null
  make -j"$JOBS" >/dev/null
  make install >/dev/null
)

log "sstp-client $SSTP_CLIENT_VERSION ($arch)"
tar -C "$WORK" -xzf "$(fetch "$SSTP_CLIENT_URL" "$SSTP_CLIENT_SHA256" "sstp-client-$SSTP_CLIENT_VERSION.tar.gz")"
SST=$WORK/sstp-client-$SSTP_CLIENT_VERSION
apply_patches "$SST" "$ROOT/patches/sstp-client"
(
  cd "$SST"
  ./configure --host="$host" --prefix=/opt/ingress-sstpc \
    --disable-shared --enable-static --disable-ppp-plugin \
    --with-runtime-dir=/var/run/sstpc --with-openssl="$DEPS" >/dev/null
  make -j"$JOBS" >/dev/null
)

# --- checks + package --------------------------------------------------------
TLS_SOURCE="OpenSSL $OPENSSL_VERSION (static)  $OPENSSL_URL  sha256:$OPENSSL_SHA256"
check_binary() {
  local bin=$1
  [ "$(lipo -archs "$bin")" = "$arch" ] || die "$bin is $(lipo -archs "$bin"), want $arch"
  if otool -L "$bin" | tail -n +2 | grep -v -E '^\s+(/usr/lib/|/System/Library/)'; then
    die "$bin links non-system libraries (above)"
  fi
}

stage_common() { # STAGE TOOL
  mkdir -p "$1/bin" "$1/LICENSES"
  cp "$WORK/openssl-$OPENSSL_VERSION/LICENSE.txt" "$1/LICENSES/OpenSSL-Apache-2.0.txt"
  write_sources "$1/SOURCES.txt" "$2"
}

OCS=$WORK/stage-openconnect
stage_common "$OCS" openconnect
cp "$OC/openconnect" "$OCS/bin/openconnect"
mkdir -p "$OCS/libexec"
install -m 0755 "$(fetch_vpnc_script)" "$OCS/libexec/vpnc-script"
install -m 0755 "$OC/trojans/hipreport.sh" "$OCS/libexec/hipreport.sh"
cp "$OC/COPYING.LGPL" "$OCS/LICENSES/openconnect-LGPL-2.1.txt"
cp "$(fetch_vpnc_license)" "$OCS/LICENSES/vpnc-scripts-GPL-2.0.txt"

OFS=$WORK/stage-openfortivpn
stage_common "$OFS" openfortivpn
cp "$OFV/openfortivpn" "$OFS/bin/openfortivpn"
cp "$OFV/LICENSE" "$OFS/LICENSES/openfortivpn-GPL-3.0.txt"
cp "$OFV/LICENSE.OpenSSL" "$OFS/LICENSES/openfortivpn-OpenSSL-exception.txt"

SSS=$WORK/stage-sstpc
EVENT_SOURCE="libevent $LIBEVENT_VERSION (static)  $LIBEVENT_URL  sha256:$LIBEVENT_SHA256"
stage_common "$SSS" sstpc
cp "$SST/src/sstpc" "$SSS/bin/sstpc"
cp "$SST/COPYING" "$SSS/LICENSES/sstp-client-GPL-2.0.txt"
cp "$WORK/libevent-$LIBEVENT_VERSION-stable/LICENSE" "$SSS/LICENSES/libevent-BSD-3-Clause.txt"

for b in "$OCS/bin/openconnect" "$OFS/bin/openfortivpn" "$SSS/bin/sstpc"; do
  strip -x "$b"
  codesign --force --sign - "$b"   # ad-hoc: required to run on Apple Silicon
  check_binary "$b"
done

"$ROOT/scripts/package.sh" openconnect "$(oc_version)" darwin "$goarch" "$OCS"
"$ROOT/scripts/package.sh" openfortivpn "$(ofv_version)" darwin "$goarch" "$OFS"
"$ROOT/scripts/package.sh" sstpc "$(sstpc_version)" darwin "$goarch" "$SSS"
