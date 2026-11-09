#!/usr/bin/env bash
# tests/fake-gp.sh OPENCONNECT [expect-fail]
#
# Runs OPENCONNECT (--authenticate only: no tun, no root) against
# openconnect's own tests/fake-gp-server.py, made *strict* the way some real
# gateways are: a SAML/prelogin-cookie login is accepted only if a "passwd"
# field is present too (openconnect#859 — what MR !656 fixes). Run inside a
# container with python3 + flask (see run-fake-gp-docker.sh).
set -uo pipefail
OC_BIN=$1
EXPECT=${2:-pass}
SRC=${OC_SRC:?OC_SRC must point at the openconnect source tree}
WORK=$(mktemp -d)
sed -e "s/request.form.get(C.portal_saml):/request.form.get(C.portal_saml) and 'passwd' in request.form:/" \
    -e "s/request.form.get(C.gateway_saml):/request.form.get(C.gateway_saml) and 'passwd' in request.form:/" \
    "$SRC/tests/fake-gp-server.py" > "$WORK/strict-gp-server.py"
grep -c "'passwd' in request.form" "$WORK/strict-gp-server.py" | grep -q 2 || { echo "strict patch did not apply"; exit 2; }

CERTS=$SRC/tests/certs
python3 "$WORK/strict-gp-server.py" localhost 8443 "$CERTS/server-cert.pem" "$CERTS/server-key.pem" >"$WORK/server.log" 2>&1 &
SERVER=$!
trap 'kill $SERVER 2>/dev/null' EXIT
for _ in $(seq 50); do curl -skf https://localhost:8443/CONFIGURE >/dev/null && break; sleep 0.2; done

configure() { curl -sk -o /dev/null -X POST https://localhost:8443/CONFIGURE "$@"; }
fails=0
run() { # NAME EXPECTED(pass|fail) ARGS... ; stdin: secret
  local name=$1 want=$2; shift 2
  if out=$(timeout 30 "$OC_BIN" --protocol=gp --authenticate --cafile="$CERTS/ca.pem" "$@" https://localhost:8443 2>&1); then got=pass; else got=fail; fi
  if [ "$got" = "$want" ]; then echo "ok   $name ($got)"; else echo "FAIL $name: got $got, want $want"; echo "$out" | tail -5 | sed 's/^/     /'; fails=$((fails+1)); fi
}

saml=$EXPECT
configure -d gateway_saml=prelogin-cookie
echo FAKE_cookie | run "gateway SAML prelogin-cookie" "$saml" --user=testuser --usergroup=gateway:prelogin-cookie --passwd-on-stdin
# Portal SAML where the portal hands back a portal-userauthcookie: openconnect
# replays it to the gateway by itself, one cookie is enough.
configure -d portal_saml=prelogin-cookie -d portal_cookie=portal-userauthcookie -d gateways=gw1
echo FAKE_cookie | run "portal SAML, portal returns userauthcookie" "$saml" --user=testuser --usergroup=portal:prelogin-cookie --passwd-on-stdin
# Portal SAML without a portal cookie: openconnect asks the gateway form for
# "prelogin-cookie: " again (no blind retry for alt secrets). Ingress answers
# that prompt with the same cookie; simulate it with a second stdin line.
configure -d portal_saml=prelogin-cookie -d gateway_saml=prelogin-cookie -d gateways=gw1
printf 'FAKE_cookie\nFAKE_cookie\n' | run "portal SAML, cookie re-sent to gateway" "$saml" --user=testuser --usergroup=portal:prelogin-cookie --passwd-on-stdin
configure -d "gateways=US East,EU West"
echo secret | run "password login, gateway via --authgroup" pass --user=testuser --passwd-on-stdin --authgroup="EU West"
echo secret | run "password login, direct to gateway" pass --user=testuser --usergroup=gateway --passwd-on-stdin

[ "$fails" = 0 ] || { echo "--- server log"; tail -20 "$WORK/server.log"; exit 1; }
