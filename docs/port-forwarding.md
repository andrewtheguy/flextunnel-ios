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
applies the tunnel-set routing per connection. (The browser reaches the same
outcome but scopes it one layer earlier, at the WebKit level — see
[split-tunnel-routing.md](split-tunnel-routing.md); forwards have no such
front-end and always relay through the listener.)

- **on-list** targets (in the server-pushed tunnel set) go through the QUIC
  tunnel and are resolved/connected **server-side** — hostnames that only
  resolve on the server's network, `[host_aliases]` names, and internal IPs all
  work;
- **off-list** targets are dialed directly from the device.

Each row shows a **tunneled** (green) or **direct** (orange) badge predicting
that decision from the pushed tunnel set. The badge is advisory — the core (and
the server's own whitelist) remain the authority per connection.

Before a session's first connection is relayed, the forwarders probe the SOCKS
port by fetching `http://flextunnel.internal/status.json` through it and
requiring the reported `server_node_id` to match the configured server (the
same guard as the desktop forwarder). A wrong answer means some other SOCKS5
server is on the port, and the connection is dropped instead of sending traffic
to the wrong place — a misconfiguration guard, not security. Success is cached
for the session; failures retry on the next connection.

### Managing forwards

Tap **+** to add; tap a row to edit. Fields: optional label, local port, remote
host (hostname or IP — hostnames are passed through unresolved, so DNS happens
on the server for tunneled targets), remote port. The sheet rejects a local
port that is out of range, already used by another forward, or equal to the
SOCKS port; ports below 1024 are warned about (iOS apps can't bind them).

Each row has a **start/stop toggle**, and the toggle is **per-session**: a
fresh session start (either CTA on the setup screen) begins with every forward
off — nothing tunnels until you switch it on:

- **on** — the listener binds while the SOCKS proxy is up, and rebinds
  automatically across mid-session reconnects and port changes;
- **off** — the listener closes immediately (open connections drop, the local
  port is released).

If starting fails during initial setup (e.g. the local port is in use), the
forward stops and the toggle flips back off, with the reason left on the row
until the next start attempt. A failure *after* the forward was listening
(e.g. iOS reclaiming the listeners around suspension) does not flip it off —
the forward stays enabled and resumes with the session.

The status line under each enabled forward is live: `listening`,
`listening · N active` (open connection count), or a red reason such as
`port 8080 is in use`.

Forward definitions persist across launches (as JSON in the app container,
with the same at-rest protections as bookmarks/history); the toggle state is
deliberately **not** part of that — it is runtime-only, so forwards never
auto-start with a session. Once switched on they work in browser-mode sessions
too; the management UI just lives in proxy-only mode.

## Background behavior (location keep-alive)

There is no VPN / Network Extension, so the listeners live inside the app
process and follow its lifecycle. To keep them alive in the background, the app
uses the same technique as Termius and Blink: while a proxy-only session is up,
it runs a **continuous Core Location session**, and iOS does not suspend an app
that is actively receiving location updates — so the SOCKS listener and every
forward stay reachable indefinitely while you use other apps.

The **"Keep alive in background"** toggle in the proxy screen's Background
section controls this; it is **off by default** (opt-in, mirroring Termius's
"Location tracking" setting) and the choice persists across launches. Switched
off, the app falls back to the best-effort ~30 s grace described below.

How it's implemented (`BackgroundKeepAlive.swift`):

- enabling the toggle prompts for **When In Use** location permission;
  granting it is all the setup there is;
- accuracy is deliberately coarse (100 km, like Blink's `geo track`) so fixes
  come from cell towers rather than the GPS radio — the battery cost is small;
- every fix is **discarded**: nothing is stored or sent anywhere; the location
  session exists purely so iOS keeps the process running;
- it starts and stops with the proxy-only session, so the system's location
  indicator never shows while the proxy is down;
- expect the location-in-use indicator while a session runs — that's iOS
  truthfully reporting the active location session.

This is fine for a personally-distributed build, but it is **not App Store
material**: review requires location be used for user-visible location
features, not as a keep-alive vehicle (Termius/Blink dress theirs up with
geo-tagging and geo-fencing features for this reason).

If location permission is **denied** (the proxy-only screen shows this, with a
shortcut to Settings), behavior falls back to best-effort: extended execution
keeps serving for roughly **30 seconds** after backgrounding, then iOS suspends
the process:

- a suspension defuncts the process's sockets — the core's SOCKS listener and
  QUIC endpoint as well as the forward listeners — and the core cannot recover
  that on its own (its accept loop keeps failing while health still reads
  alive, so everything *looks* connected while nothing answers);
- so on return to the app, the session is **relaunched automatically**: the
  same full stop/start as a manual disconnect/connect (fresh tunnel connect,
  every enabled forward rebound), without tearing the screen down. Expect a
  brief "connecting" while the handshake replays;
- connections that were open when the suspension hit are dead; the client must
  reconnect after you return.

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
| forward dead after returning to the app | iOS suspended the process — usually because keep-alive is off or location permission is denied (see "Background behavior"), so only the ~30 s grace applied. The session relaunches automatically on return; give the handshake a moment, reconnect the client, and enable the keep-alive to hold sessions across backgrounding. |
