# Proxy-only mode & port forwarding

Besides the browser, the app can run as a plain tunnel endpoint: choose
**Forward ports** on the setup screen and tap **Start Port Forwarding** to
bring up the same flextunnel core (the loopback SOCKS5 listener plus the QUIC
link to your server) with a status-and-forwards screen instead of the browser. The point is to serve **other
apps on the device**: iOS loopback is shared across processes, so anything you
run — an SSH client, RDP viewer, database GUI, another browser — can reach
`localhost:<port>` endpoints this app provides while it is alive.

Two things are on offer in that mode:

- the **SOCKS5 proxy itself** at `127.0.0.1:<SOCKS bind port>` (default 18080),
  for client apps that speak SOCKS5;
- **port forwards** — plain TCP listeners on `localhost:<local port>` that relay
  every accepted connection to a fixed `remote host:port` through the core, for
  client apps that don't.

Unlike the SOCKS bind (IPv4-only, bound by the Rust core), each forward listens
on **both loopback stacks** — `127.0.0.1` and `::1` — because client apps
connecting to `localhost` may try IPv6 first. A forward is usable while either
stack is bound and reports failure only when both are down. Either way nothing
is ever exposed on the LAN.

## Port forwards

A forward is `localhost:<local port> → <remote host>:<remote port>`. Each
accepted connection is relayed through the in-app SOCKS5 listener, so the core
applies exactly the same routing as the browser:

- **on-list** targets (in the server-pushed tunnel set) go through the QUIC
  tunnel and are resolved/connected **server-side** — hostnames that only
  resolve on the server's network, `[host_aliases]` names, and internal IPs all
  work;
- **off-list** targets are dialed directly from the device.

Each row shows a **tunneled** (green) or **direct** (orange) badge predicting
that decision from the pushed tunnel set. The badge is advisory — the core (and
the server's own whitelist) remain the authority per connection.

### Managing forwards

Tap **+** to add; tap a row to edit. Fields: optional label, local port, remote
host (hostname or IP — hostnames are passed through unresolved, so DNS happens
on the server for tunneled targets), remote port. The sheet rejects a local
port that is out of range, already used by another forward, or equal to the
SOCKS port; ports below 1024 are warned about (iOS apps can't bind them).

Each row has an **enabled toggle**:

- **on** — the listener binds whenever the SOCKS proxy is up, and rebinds
  automatically across reconnects and port changes;
- **off** — the listener closes immediately (open connections drop, the local
  port is released) and stays out of auto-start until re-enabled.

The status line under each enabled forward is live: `listening`,
`listening · N active` (open connection count), or a red reason such as
`port 8080 is in use`.

Forwards persist across launches (as JSON in the app container, with the same
at-rest protections as bookmarks/history) and **auto-start** whenever the proxy
comes up — including when the proxy was started in browser mode; the management
UI just lives in proxy-only mode.

## Background behavior (best-effort)

There is no VPN / Network Extension, so the listeners live inside the app
process and follow its lifecycle. When you switch away, the app requests
extended execution and keeps serving for roughly **30 seconds**; after that iOS
suspends the process:

- suspended, not gone — the sockets survive, and listeners resume as soon as
  you return to the app;
- connections that were mid-transfer usually survive a brief suspension; longer
  ones die and the client must reconnect;
- the QUIC link often idles out while suspended; the core reconnects it on its
  own once the app is foregrounded (this is invisible for off-list forwards and
  a short stall for tunneled ones).

Practically: bring flextunnel to the foreground, switch to the client app, and
do your work in bouts; re-open flextunnel whenever the forward has gone stale.

## What forwards are (and aren't) good for

A forward is a raw TCP pipe. It carries any TCP protocol, but it does not — and
cannot — rewrite what flows through it:

- **great for**: SSH, RDP/VNC, databases (Postgres, MySQL, Redis, …), internal
  dev/admin HTTP services addressed by IP or that accept any `Host`;
- **poor for**: public HTTP(S) sites behind CDNs or name-based virtual hosting.
  A browser pointed at `http://127.0.0.1:9090` sends `Host: 127.0.0.1:9090`,
  and the far end may reject it (e.g. Cloudflare's *error 1003: Direct IP
  access not allowed*). Use the in-app browser — or the SOCKS proxy directly —
  for web browsing; that path preserves hostnames end to end.
- **TCP only.** The SOCKS5 front-end doesn't relay UDP, so neither do forwards.

## Troubleshooting

| Symptom | Cause / fix |
| --- | --- |
| red `port N is in use` | Another process owns the local port (in the Simulator this includes Mac processes — loopback is shared with the host). Pick another port. |
| client connects, then immediately drops | Target rejected through the tunnel (not in the server's routed set server-side), or unreachable. Check the badge and the server's `routed_domains`/`routed_cidrs`. |
| tunneled forward stalls, direct ones fine | Tunnel link is reconnecting — see the status header. On-list targets need the link; off-list ones don't. |
| web page shows a CDN error (e.g. 1003) | Host-header mismatch by design — see "What forwards are good for" above. |
| forward dead after returning to the app | iOS suspended the process past the ~30 s grace. The listener rebinds on return; reconnect the client. |
