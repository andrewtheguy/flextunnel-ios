# flextunnel-ios (POC)

A **private-network access browser** for iOS. It reaches private resources
through flextunnel's SOCKS5-over-QUIC tunnel **without a system-proxy change and
without a VPN / Network Extension**, working while the app is foregrounded. It's
split-tunnel by default (traffic to off-list resources — those not in the
server's routed tunnel set — bypasses the proxy and connects directly), with the
option to route everything through the tunnel. It behaves like a mainstream
browser — **not** a privacy/anonymity browser.

It links `libflextunnel.a` (the Rust core, built from the sibling `../flextunnel`
repo) directly into the app. The core runs an in-process loopback SOCKS5 listener
over an iroh QUIC connection; the SwiftUI `WebView` (iOS 26 `WebPage`) is pointed
at it via `WKWebsiteDataStore.proxyConfigurations` (iOS 17+).

## Browser features

Beyond loading a URL, it's a real browser: multiple tabs, an address bar with
site-security indicator, back/forward + home, find-in-page, and certificate-trust
warnings. Bookmarks and history persist across launches in protected files in
the app container (Data Protection + excluded from backups), and web sessions
(cookies/logins/cache) persist via the default `WKWebsiteDataStore`. Downloads
are fetched through the tunnel and shown in a downloads panel with a confirmation
prompt and QuickLook preview; the download **list** is intentionally session-only
to reduce clutter.

## Why no VPN

flextunnel is pure-userspace SOCKS5-over-QUIC (no TUN, no root). So, unlike the
sibling `ezvpn-ios` POC, there is **no `NEPacketTunnelProvider`, no Network
Extension entitlement, and no paid Apple Developer account requirement**. A free
personal team works, and it runs in the Simulator too.

## The DNS goal (server-side resolution)

SOCKS5 sends the **hostname** (ATYP_DOMAIN) to the proxy, so DNS for tunneled
hosts is resolved on the flextunnel **server**, not the device — the same SOCKS
remote-DNS mechanism Onion Browser uses to resolve `.onion` through Tor's local
proxy. The core logs each CONNECT's address type so you can confirm it
(`ATYP_DOMAIN (remote DNS…)` vs `ATYP_IP (local DNS…)`).

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

2. **Set signing.** Select your Team on the `FlextunnelApp` target (or set
   `DEVELOPMENT_TEAM` in `project.yml` and re-run `xcodegen generate`).

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
from `Developer.xcconfig` (gitignored, per-developer) or a `--team-id` flag.

1. **Set your Team ID** (once):

   ```sh
   cp Developer.xcconfig.sample Developer.xcconfig
   # then edit Developer.xcconfig and fill in DEVELOPMENT_TEAM
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
[flextunnel README](../flextunnel/README.md).

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
