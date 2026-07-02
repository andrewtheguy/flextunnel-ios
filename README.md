# flextunnel-ios

An iOS app for reaching **private resources** — hosts on your server's network
by **hostname** (including names that only resolve via the server's DNS),
the server's own `localhost`, or hosts by **IP** — without a VPN. It's the iOS
client for [flextunnel](https://github.com/andrewtheguy/flextunnel), a SOCKS5-over-QUIC proxy where the
**server** makes the outbound TCP connection from its own network, resolving DNS
server-side when the target is a hostname. Because the transport is [iroh](https://www.iroh.computer/)
QUIC (NAT traversal, relay fallback, TLS 1.3), the app dials the server by its
endpoint id — the server needs no public inbound port, and neither end needs
root or a TUN device.

There are two ways to use the tunnel, chosen on the setup screen:

- **Browse the web** — a built-in browser routed through the tunnel. This is a
  **private-network access browser**, not a privacy/anonymity browser: it
  behaves like a mainstream browser and split-tunnels by default. The flextunnel
  Rust core is embedded on-device (via `libflextunnel.xcframework`) and runs a
  local SOCKS5 listener on loopback; the SwiftUI `WebView` routes all its
  traffic through that listener via `WKWebsiteDataStore.proxyConfigurations`.
- **Forward ports** — run the proxy without the browser and forward local
  `localhost` ports to private hosts, so other apps on the device (SSH, RDP,
  databases…) can reach them.

## Documentation

- [Split-tunnel routing](docs/split-tunnel-routing.md) — how tunnel-vs-direct is
  decided, the server-pushed tunnel set, and verifying server-side DNS.
- [Proxy-only mode & port forwarding](docs/port-forwarding.md) — the SOCKS5
  endpoint and localhost port forwards for other apps, background behavior,
  what forwards are good for, and troubleshooting.
- [Local FFI development](docs/local-ffi-development.md) — building against a
  local `../flextunnel` Rust checkout instead of the pinned release.

## Prerequisites

- Xcode (tested with 26.x) on Apple Silicon.
- [`xcodegen`](https://github.com/yonaskolb/XcodeGen): `brew install xcodegen`.
- Rust with the iOS target: `rustup target add aarch64-apple-ios`.

The Rust static library (`libflextunnel.xcframework`) is delivered via a local
Swift package, `Packages/Flextunnel`. Its binary target downloads the **pinned
release zip** by URL + checksum, so a clean checkout builds reproducibly — there's
no vendored copy to stage. To move to a new release, run
`scripts/bump-xcframework.sh <tag>` (rewrites the url + checksum).

## Build & run

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

   Pick **Browse the web** or **Forward ports**, then tap the start button.
   Tunnel health, the bound port, and the active split-tunnel set are shown
   under **Tunnel status** in the browser, or on the port-forwarding screen.

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
