# Split-tunnel routing (the tunnel set)

The server defines a **tunnel set** — the domains/CIDRs it will route — and
pushes it to the client during the handshake. The on-device core tunnels
requests to **on-list** destinations through the QUIC connection (resolved and
connected server-side) and **direct-connects** everything off-list. This
split-tunnel behavior is the default; a server whose set matches everything
(`*` / `0.0.0.0/0`) routes all traffic.

## Why the decision lives in the Rust core

iOS `WKWebsiteDataStore.proxyConfigurations` is global — every WebView request
goes to the local SOCKS5 proxy, with no per-host routing. So the routing
decision is made in the Rust library, not the WebView: the on-device proxy
tunnels on-list destinations and connects everything else directly. Port
forwards relay through the same SOCKS5 listener, so the same per-destination
decision applies to them.

## Server enforcement and surfacing

The tunnel set is **defined on the server** and pushed to the client during the
handshake; the app surfaces it under **Tunnel status** in the browser and on
the port-forwarding screen (tunneled domains/CIDRs, or "Full tunnel (all
traffic)" when the set routes everything via `*` / `0.0.0.0/0`). The server
also enforces the same set independently as a **whitelist** (defense in depth),
rejecting any tunnel request for an off-list target. Off-list hosts are
**always direct-connected** today (never blocked client-side). A future
client-side blocking mode is on the roadmap — see "Routed-set split-tunneling →
Roadmap" in the
[flextunnel README](https://github.com/andrewtheguy/flextunnel/blob/main/README.md).

## Verifying server-side DNS

Run the flextunnel **server** with `RUST_LOG=info`. Browsing a tunneled host
should log `ATYP_DOMAIN (remote DNS, resolved on server)` per CONNECT — **not**
`ATYP_IP`. For a definitive check, add a hostname that only resolves on the
server's network (e.g. in the server host's `/etc/hosts`) and load it from the
app; if it loads, DNS happened on the server. (If you instead see `ATYP_IP`,
Network framework pre-resolved locally — fall back to an HTTP-CONNECT proxy
front-end.)
