# write_sources FILE TOOL — SOURCES.txt: exactly what went into an artifact.
write_sources() {
  local f=$1 tool=$2
  {
    echo "Built by ingress-deps (https://github.com/azizbekatajanov/ingress-deps)"
    echo "commit: ${INGRESS_DEPS_COMMIT:-$(git -C "$ROOT" rev-parse --verify -q HEAD || echo unknown)}"
    echo "build revision: ingress.$INGRESS_REV"
    echo
    if [ "$tool" = openconnect ]; then
      echo "openconnect $OPENCONNECT_VERSION  $OPENCONNECT_URL  sha256:$OPENCONNECT_SHA256"
      echo "  patches:"
      for p in "$ROOT"/patches/openconnect/*.patch; do echo "    $(basename "$p")  sha256:$(sha256_of "$p")"; done
      echo "vpnc-script  https://gitlab.com/openconnect/vpnc-scripts @ $VPNC_SCRIPTS_COMMIT  sha256:$VPNC_SCRIPT_SHA256"
    elif [ "$tool" = sstpc ]; then
      echo "sstp-client $SSTP_CLIENT_VERSION  $SSTP_CLIENT_URL  sha256:$SSTP_CLIENT_SHA256"
      echo "  patches:"
      for p in "$ROOT"/patches/sstp-client/*.patch; do echo "    $(basename "$p")  sha256:$(sha256_of "$p")"; done
      echo "${EVENT_SOURCE:-}"
    else
      echo "openfortivpn $OPENFORTIVPN_VERSION  $OPENFORTIVPN_URL  sha256:$OPENFORTIVPN_SHA256"
    fi
    echo "${TLS_SOURCE:-}"
  } > "$f"
}
