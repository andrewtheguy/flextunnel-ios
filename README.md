# flextunnel-ios (POC)

A minimal iOS app that routes a `WKWebView` through flextunnel's SOCKS5 tunnel
**without a system-proxy change and without a VPN / Network Extension**, working
only while the app is foregrounded.

It links `libflextunnel.a` (the Rust core, built from the sibling `../flextunnel`
repo) directly into the app. The core runs an in-process loopback SOCKS5 listener
over an iroh QUIC connection; the web view is pointed at it via
`WKWebsiteDataStore.proxyConfigurations` (iOS 17+).

## Why no VPN

flextunnel is pure-userspace SOCKS5-over-QUIC (no TUN, no root). So, unlike the
sibling `ezvpn-ios` POC, there is **no `NEPacketTunnelProvider`, no Network
Extension entitlement, and no paid Apple Developer account requirement**. A free
personal team works, and it runs in the Simulator too.

## The DNS goal (server-side resolution)

SOCKS5 sends the **hostname** (ATYP_DOMAIN) to the proxy, so DNS is resolved on
the flextunnel **server**, not the device. This is the same mechanism that lets
Onion Browser resolve `.onion` names through Tor's local SOCKS proxy. The core
logs each CONNECT's address type so you can confirm it (`ATYP_DOMAIN (remote
DNS…)` vs `ATYP_IP (local DNS…)`).

## Prerequisites

- Xcode (tested with 26.x) on Apple Silicon.
- [`xcodegen`](https://github.com/yonaskolb/XcodeGen): `brew install xcodegen`.
- Rust with the iOS target: `rustup target add aarch64-apple-ios`.

## Build & run

1. **Build the Rust static library** (from the sibling repo). This stages
   `vendor/libflextunnel.a` and `vendor/flextunnel.h` here automatically:

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
   - *Auth token* — a token the server accepts.
   - *Relay URLs* — optional hints; leave blank for iroh defaults.

   Tap **Start proxy**, then open the proxied WebView and load a URL.

## Verifying server-side DNS

Run the flextunnel **server** with `RUST_LOG=info`. Browsing should log
`ATYP_DOMAIN (remote DNS, resolved on server)` per CONNECT — **not** `ATYP_IP`.
For a definitive check, add a hostname that only resolves on the server's network
(e.g. in the server host's `/etc/hosts`) and load it from the app; if it loads,
DNS happened on the server. (If you instead see `ATYP_IP`, Network framework
pre-resolved locally — fall back to an HTTP-CONNECT proxy front-end.)

## Notes

- `WKWebsiteDataStore.proxyConfigurations` requires **iOS 17+** (the deployment
  target here). WKWebView could not be proxied at runtime before iOS 17.
- The `.xcodeproj` and the staged `vendor/` artifacts are git-ignored on purpose;
  regenerate/rebuild them as above.
