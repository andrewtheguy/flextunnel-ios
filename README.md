# flextunnel-ios (POC)

A **private-network access browser** for iOS. It reaches private resources
through flextunnel's SOCKS5-over-QUIC tunnel **without a system-proxy change and
without a VPN / Network Extension**, working while the app is foregrounded. It's
split-tunnel by default (traffic to non-whitelisted resources bypasses the
proxy and connects directly), with the option to route everything through the
tunnel. It behaves like a mainstream browser — **not** a privacy/anonymity
browser.

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

## Build & run

1. **Build the Rust static library** (from the sibling repo). This stages
   `vendor/libflextunnel.xcframework` and `vendor/flextunnel.h` here automatically:

   ```sh
   cd ../flextunnel
   ./build-ios.sh release
   ```

2. **Generate the Xcode project:**

   ```sh
   cd ../flextunnel-ios
   xcodegen generate
   open Flextunnel.xcodeproj
   ```

3. **Set signing.** Select your Team on the `FlextunnelApp` target (or set
   `DEVELOPMENT_TEAM` in `project.yml` and re-run `xcodegen generate`).

4. **Run** on a device or the Simulator. Enter:
   - *Server node id* — the flextunnel server's iroh endpoint id.
   - *Auth token* — a token the server accepts (stored in the Keychain).
   - *Relay URLs* — optional hints; leave blank for iroh defaults.
   - *SOCKS bind port* — the loopback port the core binds.

   Tap **Start proxy**, then browse. The **Tunnel status** button shows health,
   the bound port, and the active split-tunnel set.

## Split-tunnel whitelist

iOS `WKWebsiteDataStore.proxyConfigurations` is global — every WebView request
goes to the local SOCKS5 proxy, with no per-host routing. So the routing decision
is made in the Rust library, not the WebView: the on-device proxy tunnels
whitelisted destinations and connects everything else directly.

The whitelist is **defined on the server** and pushed to the client during the
handshake; the app surfaces it under **Tunnel status** (forwarded domains/CIDRs,
or "All traffic" when the server runs no whitelist). Off-list hosts are **always
direct-connected** today (never blocked). A future client-side blocking mode is
on the roadmap — see "Whitelist split-tunneling → Roadmap" in the
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
- The vendored `libflextunnel.xcframework` is arm64-only; build/verify against a
  pinned arm64 iOS 26 Simulator, e.g. `-destination 'platform=iOS
  Simulator,name=iPhone 17,OS=26.2'`.
- The `.xcodeproj` and the staged `vendor/` artifacts are git-ignored on purpose;
  regenerate/rebuild them as above.
