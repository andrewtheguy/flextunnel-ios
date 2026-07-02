# flextunnel-ios

An iOS browser for reaching **private resources** — hosts on your server's
network by **hostname** (including names that only resolve via the server's DNS),
the server's own `localhost`, or hosts by **IP** — without a VPN. It's the iOS
client for [flextunnel](https://github.com/andrewtheguy/flextunnel), a SOCKS5-over-QUIC proxy where the
**server** makes the outbound TCP connection from its own network, resolving DNS
server-side when the target is a hostname. Because the transport is [iroh](https://www.iroh.computer/)
QUIC (NAT traversal, relay fallback, TLS 1.3), the app dials the server by its
endpoint id — the server needs no public inbound port, and neither end needs
root or a TUN device.

This is a **private-network access browser**, not a privacy/anonymity browser: it
behaves like a mainstream browser and split-tunnels by default. The flextunnel
Rust core is embedded on-device (via `libflextunnel.xcframework`) and runs a
local SOCKS5 listener on loopback; the SwiftUI `WebView` routes all its traffic
through that listener via `WKWebsiteDataStore.proxyConfigurations`.

## How routing works

The server defines a **tunnel set** — the domains/CIDRs it will route — and pushes
it to the client during the handshake. The on-device core tunnels requests to
**on-list** destinations through the QUIC connection (resolved and connected
server-side) and **direct-connects** everything off-list. This split-tunnel
behavior is the default; a server whose set matches everything (`*` /
`0.0.0.0/0`) routes all traffic. The server independently enforces the same set
as a whitelist (defense in depth). The app surfaces the active set, health, and
bound port under **Tunnel status**.

The routing decision lives in the Rust core rather than the WebView because iOS
`WKWebsiteDataStore.proxyConfigurations` is global — every WebView request hits
the local SOCKS5 proxy with no per-host routing — so the core is what decides
tunnel-vs-direct per destination.

## Prerequisites

- Xcode (tested with 26.x) on Apple Silicon.
- [`xcodegen`](https://github.com/yonaskolb/XcodeGen): `brew install xcodegen`.
- Rust with the iOS target: `rustup target add aarch64-apple-ios`.

The Rust static library (`libflextunnel.xcframework`) is delivered via a local
Swift package, `Packages/Flextunnel`. Its binary target downloads the **pinned
release zip** by URL + checksum, so a clean checkout builds reproducibly — there's
no vendored copy to stage. To move to a new release, run
`scripts/bump-xcframework.sh <tag>` (rewrites the url + checksum).

1. **Generate the Xcode project** (Xcode resolves and downloads the package on
   first build):

   ```sh
   xcodegen generate
   open Flextunnel.xcodeproj
   ```

2. **Set signing.** Copy the sample and fill in your Team ID (gitignored, so it
   stays local and survives `xcodegen generate`):

   ```sh
   cp Developer.local.xcconfig.sample Developer.local.xcconfig
   # then edit Developer.local.xcconfig and set DEVELOPMENT_TEAM
   ```

   The committed `Developer.xcconfig` (wired via `configFiles` in `project.yml`)
   `#include?`s it, so Xcode and `xcodebuild` sign automatically. You can still
   just pick a Team on the `FlextunnelApp` target in Xcode instead.

3. **Run** on a device or the Simulator. Enter:
   - *Server node id* — the flextunnel server's iroh endpoint id.
   - *Auth token* — a token the server accepts (stored in the Keychain).
   - *Relay URLs* — optional hints; leave blank for iroh defaults.
   - *SOCKS bind port* — the loopback port the core binds.

   Tap **Start proxy**, then browse. The **Tunnel status** button shows health,
   the bound port, and the active split-tunnel set.

### Developing against a local Rust build (FFI)

To iterate on the Rust FFI without cutting a release, build the sibling and set
`FLEXTUNNEL_LOCAL_XCFRAMEWORK=1` — the package's binary target then links the
sibling's `dist/ios` build (reached via the committed symlink
`Packages/Flextunnel/local/libflextunnel.xcframework`) instead of the released zip:

```sh
cd ../flextunnel && ./build-ios.sh release
cd ../flextunnel-ios
FLEXTUNNEL_LOCAL_XCFRAMEWORK=1 xcodegen generate
FLEXTUNNEL_LOCAL_XCFRAMEWORK=1 xcodebuild -project Flextunnel.xcodeproj \
  -scheme FlextunnelApp \
  -destination 'platform=iOS Simulator,name=iPhone 17,OS=26.2' build
```

The var is read when Swift Package Manager evaluates `Package.swift`, so it must
be set for both `xcodegen`/resolution and the build. In the Xcode GUI, export it
before launching (`launchctl setenv FLEXTUNNEL_LOCAL_XCFRAMEWORK 1`, then restart
Xcode) since scheme env vars don't reach package resolution. Rebuild the sibling
and the next app build picks it up. Unset it to return to the pinned release.

## Archive & deploy (signed .ipa)

`scripts/create-archive-ios.sh` builds a Release `.xcarchive` and exports a
signed `.ipa` in one step. It needs an Apple Developer Team ID, which it reads
from `Developer.local.xcconfig` (gitignored, per-developer) or a `--team-id` flag.

1. **Set your Team ID** (once):

   ```sh
   cp Developer.local.xcconfig.sample Developer.local.xcconfig
   # then edit Developer.local.xcconfig and fill in DEVELOPMENT_TEAM
   ```

2. **Generate the project** if you haven't already (`xcodegen generate`).

3. **Build and export:**

   ```sh
   scripts/create-archive-ios.sh
   ```

   The archive lands in `build/flextunnel-ios.xcarchive` and the `.ipa` in
   `build/export/`. Pass `--team-id <ID>` to override the xcconfig, or
   `--allow-provisioning-updates` to let Xcode create/update signing assets.
   See `scripts/create-archive-ios.sh --help` for all options (configuration,
   output paths, and export method, which defaults to `debugging`).

## Split-tunnel routing (the tunnel set)

iOS `WKWebsiteDataStore.proxyConfigurations` is global — every WebView request
goes to the local SOCKS5 proxy, with no per-host routing. So the routing decision
is made in the Rust library, not the WebView: the on-device proxy tunnels
on-list destinations and connects everything else directly.

The tunnel set (the routed domains/CIDRs) is **defined on the server** and pushed
to the client during the handshake; the app surfaces it under **Tunnel status**
(tunneled domains/CIDRs, or "Full tunnel (all traffic)" when the set routes
everything via `*` / `0.0.0.0/0`). The server also enforces the same set
independently as a **whitelist** (defense in depth), rejecting any tunnel request
for an off-list target. Off-list hosts are **always direct-connected** today
(never blocked client-side). A future client-side blocking mode is on the roadmap
— see "Routed-set split-tunneling → Roadmap" in the
[flextunnel README](https://github.com/andrewtheguy/flextunnel/blob/main/README.md).

## Proxy-only mode & port forwarding

**Start proxy only (no browser)** on the setup screen runs the same tunnel +
SOCKS5 core without the browser, for **other apps on this device**: they can use
the SOCKS5 proxy at `127.0.0.1:<SOCKS bind port>` directly, or connect to
managed **port forwards** — loopback TCP listeners
(`localhost:<local port> → remote host:port`, bound on both 127.0.0.1 and ::1)
relayed through the core, so the
same split-tunnel routing applies (server-side DNS for tunneled targets).
Forwards persist, auto-start with the proxy, and keep serving best-effort for
~30 s after backgrounding (no Network Extension — iOS then suspends the app
until it's foregrounded again). Details: [docs/port-forwarding.md](docs/port-forwarding.md).

## Verifying server-side DNS

Run the flextunnel **server** with `RUST_LOG=info`. Browsing a tunneled host
should log `ATYP_DOMAIN (remote DNS, resolved on server)` per CONNECT — **not**
`ATYP_IP`. For a definitive check, add a hostname that only resolves on the
server's network (e.g. in the server host's `/etc/hosts`) and load it from the
app; if it loads, DNS happened on the server. (If you instead see `ATYP_IP`,
Network framework pre-resolved locally — fall back to an HTTP-CONNECT proxy
front-end.)

## Notes

- Targets **iOS 26**: the browser uses the SwiftUI `WebView` / `WebPage` API.
  (`WKWebsiteDataStore.proxyConfigurations`, the runtime proxy hook, requires
  iOS 17+.)
- `libflextunnel.xcframework` is arm64-only; build/verify against a pinned arm64
  iOS 26 Simulator, e.g. `-destination 'platform=iOS Simulator,name=iPhone
  17,OS=26.2'`.
- The `.xcodeproj` is git-ignored on purpose — regenerate it with `xcodegen`. The
  xcframework is fetched by Swift Package Manager (pinned release, or a local
  build in FFI-dev mode), not vendored into this repo.
