# ingress-deps

Reproducible builds of the VPN clients that [Ingress](https://github.com/azizbekatajanov/ingress) installs for its users, so nobody needs Homebrew or a distro package:

| Tool | Version | Used for |
|---|---|---|
| [openconnect](https://www.infradead.org/openconnect/) | 9.21 + [`patches/openconnect`](patches/openconnect) | GlobalProtect |
| [openfortivpn](https://github.com/adrienverge/openfortivpn) | 1.20.5 (1.21+ is broken on macOS Sonoma+, [#1165](https://github.com/adrienverge/openfortivpn/issues/1165)) | Fortinet SSL-VPN |

Targets: macOS arm64 and x86_64 (12.0+), Linux amd64 (fully static, musl).

Every input is pinned by version and sha256 in [`versions.env`](versions.env).

## Patches

- `0001-GlobalProtect-send-empty-passwd-alongside-alt-secret.patch`: [openconnect!656](https://gitlab.com/openconnect/openconnect/-/merge_requests/656) (fixes [#859](https://gitlab.com/openconnect/openconnect/-/issues/859)). When logging in with a SAML cookie (`--usergroup=portal:prelogin-cookie`), some gateways reject the request unless an empty `passwd` field is sent alongside the cookie, and fail it with `512 auth-failed-password-empty`. Ingress' SAML login depends on this.

  **When upstream merges it:** bump `OPENCONNECT_*` to the release that contains it, delete the patch, bump `INGRESS_REV`.

## Artifacts

Each release `rN` (N = `INGRESS_REV`) carries `TOOL-VERSION-ingress.N-OS-ARCH.tar.gz` plus `SHA256SUMS` and `ingress-manifest.go.txt`. The archives use the layout Ingress' installer expects. Everything sits at the archive root, owned by root, with only directories and regular files:

```
bin/<tool>
libexec/vpnc-script      (openconnect only; pinned vpnc-scripts commit)
libexec/hipreport.sh     (openconnect only)
LICENSES/                (licenses of everything inside)
SOURCES.txt              (exact sources, patches and ingress-deps commit)
```

On macOS only system libraries are linked dynamically (libxml2, zlib, libiconv). OpenSSL 3.5 LTS is linked statically, and the binaries are ad-hoc signed. On Linux the binaries are fully static against Alpine's static OpenSSL, libxml2 and zlib. openfortivpn uses the system `pppd` (`/usr/sbin/pppd`; package `ppp` on Linux).

## Building locally

```sh
./scripts/build-macos.sh arm64        # or x86_64 (cross-compiled on Apple Silicon)
./scripts/build-linux-docker.sh amd64 # needs Docker
./tests/run-fake-gp-docker.sh amd64   # test the Linux build, see below
./scripts/gen-manifest.sh             # manifest entries for Ingress
```

macOS needs Xcode command line tools and `automake autoconf libtool pkg-config` (openfortivpn has no release tarball with `configure`).

## Tests

`tests/fake-gp.sh` runs openconnect (`--authenticate`, no root needed) against openconnect's own `tests/fake-gp-server.py`. The server is made strict the way real gateways are: a SAML login is accepted only when `passwd` is present. The test covers gateway and portal SAML with `prelogin-cookie`, a portal that returns `portal-userauthcookie`, password login with a gateway chosen via `--authgroup`, and direct-to-gateway login. Our build must pass all of them. Debian's stock openconnect is run against the same server and must fail the SAML cases, which proves the patch matters.

## Releasing

1. Bump versions/patches and `INGRESS_REV` in `versions.env`, push, and let CI go green.
2. `git tag rN && git push origin rN`. CI builds again, then publishes the release with the archives, `SHA256SUMS` and `ingress-manifest.go.txt`.
3. Paste `ingress-manifest.go.txt` into Ingress' `components_manifest.go`.
