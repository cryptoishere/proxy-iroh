# proxy-iroh (Server)

An authenticated, high-performance SOCKS5 and UDP proxy server powered by Iroh, with encrypted QUIC transport, direct peer-to-peer connectivity, and relay fallback.

`proxy-iroh` acts as the remote exit node for the `proxy-iroh` ecosystem. It accepts authenticated Iroh connections from clients, parses the SOCKS5 and V2 CONNECT-UDP payloads, and establishes the outbound connections to target destinations. 

*Note: This document covers the Server implementation. For the Client and TUN/VPN bridge setup, please see [CLIENT.md](CLIENT.md).*

## Features (Server-Side)

- **Strict Mode Authentication** — enforces tunnel HMAC verification before any SOCKS5 framing is parsed, protecting against scanners and unauthorized access.
- **Standard SOCKS5 Exit Node** — parses RFC 1928/1929 and establishes outbound TCP connections on behalf of the client.
- **V2 CONNECT-UDP Support** — accepts custom `S5T2` framing to tunnel raw UDP datagrams.
- **Datagram Reassembly** — intelligently reassembles fragmented UDP packets (up to 900-byte chunks) to support WebTransport, HTTP/3, and QUIC handshakes.
- **Encrypted QUIC Transport** — ChaCha20-Poly1305 encryption for all client-server communication, keyed via HMAC-SHA256.
- **P2P & Relay Fallback** — attempts direct NAT traversal with the client when possible, falling back to an Iroh relay only when necessary.
- **Server-Side Port Allowlist** — default-deny egress on the server. Only the ports named in `SOCKS5_ALLOWED_PORTS` may be reached; SMTP, IMAP, POP3, RDP, MySQL, PostgreSQL, Redis, MongoDB, Elasticsearch, VNC, SMB, LDAP, and everything else are blocked by default.
- **Server-Side IP Policy (SSRF guard)** — blocks loopback, RFC 1918, link-local, CGNAT, IPv6 ULA, and IPv6 link-local destinations after DNS resolution, protecting internal infrastructure and cloud metadata endpoints from being reached via the tunnel.
- **On-Chain Client Verification** — when a client presents `sig_type = CLIENT_TYPE`, the server queries the central hub before completing the tunnel handshake. Addresses not registered on chain, or explicitly revoked, are rejected before any tunnel bytes are exchanged. `SYSTEM_TYPE` handshakes bypass the check.
- **Dual-Signed Bandwidth Attestation** — server and client independently report per-session byte counts to the central hub. The hub credits `min(server, client)`, so one-sided inflation is self-defeating. Collusion resistance relies on external evidence (synthetic clients, cohort analysis, relay-side accounting), not cryptography. See [SECURITY.md](SECURITY.md).
- **Cross-Platform** — native support for both Linux and Windows. The server uses a unified `lib/bridge.rs` to abstract `AF_UNIX` socket pairs (Linux) and loopback pairs (Windows).
- **Configurable IP Checkers** — the public IP checker pool can be supplied via `HOST_IP_CHECKERS_LIST` to monitor the server's outbound IP.
- **Windows Launch Modes** — interactive (TUI when a terminal is attached), background (`server background`), and Windows Service (`sc start proxy-iroh`). The service is compiled in with `--features daemonize` and installs via `server install`.

## Architecture

```text
[Client]
        |
        | Authenticated Iroh Session
        | Encrypted QUIC Transport
        |
        +---- Direct peer-to-peer path
        |            or
        +---- Iroh relay fallback
                     |
                     v
             [proxy-iroh Server]  ◄──────────────►  [Central Hub]
                     |                            on-chain registry
                     |                            (ALPN proxy/svc/0)
                     +---- Tunnel Hello HMAC verify
                     |
                     +---- CLIENT_TYPE: on-chain check ──┐
                     |                                    │
                     |       SYSTEM_TYPE: skip ───────────┤
                     |                                    ▼
                     +---- Parses SOCKS5 (TCP) or V2 (UDP)
                     |
                     +---- Port policy check (SOCKS5_ALLOWED_PORTS)
                     |     ↓
                     +---- DNS resolution (DoT)
                     |     ↓
                     +---- IP policy check (RFC1918 / loopback / …)
                     |
                     | Outbound TCP / UDP
                     v
              [Target Destination]
```

### V2 Datagram Protocol
When a client requests a UDP association (e.g., for WebTransport), it sends a V2 `CONNECT-UDP` frame. Because Iroh's datagram size limit is ~1149 bytes, larger packets are fragmented. The server handles reassembly before sending the payload to the target destination.

**Wire Format (Fragment Header):**
```text
┌──────────┬───────────┬────────────┬──────────────────────────┐
│ assoc_id │ frag_idx  │ frag_total │ chunk (≤ 900 bytes)      │
│  4 B BE  │   1 B     │    1 B     │     variable             │
└──────────┴───────────┴────────────┴──────────────────────────┘
```
- `frag_total == 1, frag_idx == 0` → Unfragmented.
- `MAX_CHUNK = 900` → safely fits Iroh limits over relay or direct paths, with headroom for the 6-byte V2 header and QUIC overhead.

## Platform Support

| Platform | Local pair mechanism | Notes |
|---|---|---|
| Unix | `AF_UNIX` socket pair | Native non-blocking Unix stream/datagram pairs. |
| Windows | Loopback TCP/UDP pair | Uses `127.0.0.1:0`. Nagle disabled for low latency. |

## Server Configuration

### Environment Variables

| Setting | Required | Default | Meaning |
|---|---|---|---|
| `RUST_LOG` | No | `off` | `tracing` filter (e.g., `info`, `debug`). |
| `SOCKS5_TUNNEL_ENCRYPTION` | No | `on` | Encrypt transport with ChaCha20-Poly1305. |
| `SOCKS5_SIGNATURE_AUTH` | No | `on` | **Strict mode**. Rejects all plaintext connections. |
| `SOCKS5_USERS` | No | — | RFC 1929 users (e.g., `alice:secret`). Ignored in strict mode. |
| `SOCKS5_AUTH_REQUIRED` | No | `false` | Refuse to start if users are empty (non-strict path only). |
| `SOCKS5_RATE_MAX` | No | `1200` | Per-IP connection attempts per window. `0` disables. |
| `SOCKS5_RATE_WINDOW_SECS` | No | `60` | Rate-limit window. |
| `SOCKS5_QUOTA_MAX` | No | `256` | Concurrent connections per IP. `0` disables. |
| `SOCKS5_ALLOWED_PORTS` | No | `22,80,443,8080,8443,853` | Server-side egress allowlist. See [Port Policy](#port-policy). |
| `SOCKS5_BLOCK_PRIVATE_IPS` | Auto-On | `on` | Block loopback / RFC 1918 / link-local / CGNAT / IPv6 ULA destinations. See [IP Policy](#ip-policy). |
| `RELAY_IDLE_SECS` | No | `60` | Seconds a half-closed relay may sit idle before being torn down. See [Relay lifecycle](#relay-lifecycle). |
| `HOST_IP_CHECKERS_LIST` | No | defaults | Comma-separated HTTPS URLs to verify server public IP. |
| `CONN_HARD_IDLE_SECS` | No | `300` | Per-Connection watchdog: force-closes a Connection after N seconds without application traffic, regardless of transport-layer state. |
| `CENTRAL_ENDPOINT_SNI` | Conditional | `crypto-ig.com` | Hub hostname. Required when `SOCKS5_SIGNATURE_AUTH=true`. |
| `CENTRAL_ENDPOINT_SNI_PORT` | Conditional | `443` (release) / `9002` (debug) | Hub port. Required when `SOCKS5_SIGNATURE_AUTH=true`. |
| `TARGET_ENDPOINT_X1_CENTRAL_HUB_13` | Conditional | cfe9d0de0e7c81e3c183dd3aec1927503e80f9b3509793a20ec220ae182f30d3 | Hub Iroh `EndpointId`. Required when `SOCKS5_SIGNATURE_AUTH=true`. |
| `ENDPOINT_BIND_ADDRESS_CENTRAL_HUB` | No | `0.0.0.0:44445` | Bind address for the hub-facing Iroh endpoint. |

**Listen Address:** The server binds to `0.0.0.0:1082` by default.

### Running the Server
```bash
RUST_LOG=info \
SOCKS5_SIGNATURE_AUTH=true \
SOCKS5_TUNNEL_ENCRYPTION=on \
SOCKS5_RATE_MAX=1200 \
SOCKS5_QUOTA_MAX=256 \
SOCKS5_ALLOWED_PORTS=22,80,443,8080,8443,853 \
SOCKS5_BLOCK_PRIVATE_IPS=on \
./server
```

### Data Directory
The server stores its database (account credentials, etc.) in a platform-specific application data directory.

**Windows:**
Uses `LOCALAPPDATA` as its base directory and appends `CiGPeerApp\db`.
Example: `C:\Users\Alice\AppData\Local\CiGPeerApp\db`
*(Note: `LOCALAPPDATA` must be set).*

**Linux:**
Appends `CiGPeerApp/db` to the following base directory:
- If `XDG_DATA_HOME` is set, its value is used.
- Otherwise, the server uses `$HOME/.local/share`.
Example: `/home/alice/.local/share/CiGPeerApp/db`

## Windows Launch Modes

Three ways to run the server on Windows, each with different persistence and console behaviour. Linux users continue to wrap the binary with their own service manager (`systemd`, `runit`, `openrc`, etc.).

| Mode | Invocation | Console | TUI | Survives logoff |
|---|---|---|---|---|
| Interactive | `server.exe` | attached | yes (if terminal) | no |
| Background | `server.exe background` | detached | no | no |
| Service | `sc start proxy-iroh` | none | no | yes |

### Interactive

Double-click `server.exe` or run it from a terminal. The TUI renders when `stdout` is a terminal; otherwise tracing writes only to `server_app.log`. Stop with `q`, `Esc`, or `Ctrl-C`.

### Background

```bat
server.exe background
```

Spawns a detached child with no console and no TUI, prints its PID, and returns to the prompt. The child is not registered with SCM — it survives until killed or the session ends.

```bat
taskkill /PID <pid> /F
```

### Service

Requires a build with `--features daemonize`, and an elevated prompt for install/uninstall.

```bat
server.exe install
sc start proxy-iroh
sc stop proxy-iroh
server.exe uninstall
```

The service runs as `LocalSystem`, auto-starts on boot, and restarts are managed by the operator via `sc failure proxy-iroh reset= 0 actions= restart/5000`. Logs and the sled database live in the service account's `%LOCALAPPDATA%\CiGPeerApp` — `C:\Windows\System32\config\systemprofile\AppData\Local\CiGPeerApp` for `LocalSystem`. If the account was provisioned in a user session, either re-register from the service context or migrate the data directory before starting.

See [`SETUP.win.daemon.md`](SETUP.win.daemon.md) for the complete walkthrough.

## Central Hub Integration

The central hub maintains the on-chain registry used for client address verification. The server connects to it on a dedicated Iroh endpoint that is separate from the client-facing listener.

### Two endpoints

| Endpoint | Bind address | ALPN | Purpose |
|---|---|---|---|
| Client-facing | `ENDPOINT_BIND_ADDRESS` (default `0.0.0.0:44444`) | `socks5/1` | Accepts incoming SOCKS5/tunnel connections |
| Hub-facing | `ENDPOINT_BIND_ADDRESS_CENTRAL_HUB` (default `0.0.0.0:44445`) | `proxy/svc/0` | Connects to the hub for registration and on-chain verification |

The hub-facing `proxy/svc/0` stream carries length-prefixed frames. Since 0.7.0 every frame begins with a discriminator byte:

| `msg_type` | Payload | Purpose |
|---|---|---|
| `0x01` | `ProxyFrameMetadata` | On-chain verify (existing) |
| `0x02` | `SessionOpen` | Session registration before `Welcome` |
| `0x03` | `ServerReport` | Per-session byte counts at relay teardown |

`SessionOpen` and `ServerReport` carry `[u8; 16] session_id`, `[u8; 20] server_address`, `[u8; 20] client_address`, and a `PathType` (`Direct` / `Relay`). `ServerReport` additionally carries `bytes_ingress`, `bytes_egress`, `started_at`, `ended_at`, and a per-server monotonic `nonce`. The hub credits `min(server_report, client_attestation)` per session — see [SECURITY.md](SECURITY.md) for the economic model.

### Startup sequence

1. Hub-facing endpoint binds and derives its `EndpointId`.
2. Server connects to the hub at `TARGET_ENDPOINT_X1_CENTRAL_HUB_13` via the relay.
3. If `SOCKS5_SIGNATURE_AUTH=true`, `PeerSetup::enable` performs initial registration (first run) or login (subsequent runs) with the hub, persisting the resulting account — including its derived keys — in the local account store.
4. Client-facing endpoint binds and prints its `EndpointId` (`iroh endpoint id = ...`).
5. The main loop begins accepting client connections.

The hub connection is **long-lived**. It stays open for the lifetime of the server process, and the server reconnects it lazily whenever an on-chain verification fails with a transport error. A hub restart does not require a server restart.

### Failure behaviour

| Failure | Effect |
|---|---|
| Hub unreachable at startup | Server logs `starting tunnel with Central Hub failed` and continues. Client connections will succeed for `SYSTEM_TYPE`, fail for `CLIENT_TYPE`, until the hub becomes reachable. |
| Hub unreachable per-verification | The individual `CLIENT_TYPE` handshake closes before `Welcome`. The next attempt re-tries the hub connection. |
| Hub returns `client_address_on_chain: false` | Connection closed before `Welcome`. |
| Hub response malformed or exceeds 1 MiB | Connection closed before `Welcome`. |
| Hub does not answer within 30 s | Connection closed before `Welcome`. |

All on-chain failures are **fail-closed** by design. There is no "trust the client when the hub is down" path.

To avoid the startup window entirely, ensure the hub is reachable before starting the server, and monitor for the `starting tunnel with Central Hub failed` line in production.

## On-Chain Client Verification

When a client presents `sig_type = CLIENT_TYPE` under `SOCKS5_SIGNATURE_AUTH=true`, the server verifies the client's wallet address against the hub's on-chain registry **before** sending the `Welcome`. `SYSTEM_TYPE` handshakes are unaffected by this check.

### Handshake flow

1. Client sends `Hello` with `sig_type = CLIENT_TYPE`, its wallet address, and a client-chosen 16-byte `session_id`. The Hello HMAC covers all three.
2. Server derives `derive_client(M, address)` and verifies the Hello HMAC. The client has cryptographically proven it holds `derive_client(M, address)`.
3. Server sends `ProxyFrameMetadata { server_address, client_address }` to the hub; the hub answers `ProxyCallerResponse { client_address_on_chain: bool }`.
4. On `true`, the server sends `SessionOpen { session_id, server_address, client_address, started_at, path_type }` on the same iroh runtime and waits for the hub's ack. `Welcome` is queued only after the ack arrives.
5. Any failure in steps 3 or 4 — hub unreachable, timeout, malformed response, negative result, `SessionOpen` rejection — closes the connection before `Welcome`. Fail-closed.
6. During the session the two sides report independently: the server sends `ServerReport` at relay teardown (on `proxy/svc/0`); the client POSTs `ClientAttestation` to `/api/v1/bandwidth/attest` through its own tunnel (HTTPS). The hub credits `min(server, client)`. See [SECURITY.md](SECURITY.md).

Result caching: a successful or negative verification is cached per-address for 60 s to avoid re-querying the hub on every new `Connection` from the same client during a browsing session. Errors are **not** cached.

### What verification provides

| Property | Without on-chain | With on-chain |
|---|---|---|
| Revocation without rotating `M` | ✗ | ✓ |
| Blast radius of `M` compromise | any address an attacker chooses | bounded to addresses currently on chain |
| Per-address audit trail | ✗ | ✓ |

### What verification does not provide

- **Server-to-client unforgeability.** The server holds the master secret `M` and can derive any client's keys. It can forge a Hello for any on-chain address without the hub being able to distinguish a real client from an impersonating server. This is acceptable for a proxy where the server already sees all plaintext, but it means the server cannot provide third-party proof that a session originated from a client rather than from itself.
- **Replay protection beyond the 60 s timestamp window.** A captured Hello remains valid for 60 seconds from its embedded timestamp. The on-chain check does not consume the nonce, so a captured Hello that passes the timestamp check will also pass the on-chain check if the address is still registered.
- **Independence from hub compromise.** The hub also holds `M`, so a compromised hub can answer `true` for any address and can itself forge valid Hellos.

## Relay lifecycle

Each accepted SOCKS5 or V2 session becomes a `Relay` — a mio-driven pair of sockets (one to the client over iroh, one to the destination over TCP) plus two buffers. A relay is torn down when **either** of these conditions is met:

1. **Both halves closed cleanly.** The client FINed, the destination FINed, and all buffered data has been flushed.
2. **One half closed and the other went silent.** The client FINed but the destination never FINed back (common with long-lived HTTPS keep-alive servers), or vice versa. The relay is closed after `RELAY_IDLE_SECS` seconds of inactivity on either side.

Without (2), a destination that keeps a connection open without sending FIN would hold two file descriptors (one for the client socketpair, one for the destination TCP socket) until the process exited. On a busy server that accumulates dozens of such destinations per hour, the process hits its `ulimit -n` and starts failing new `socketpair()` / `create_bridge_pair()` calls with `EMFILE`.

Set `RELAY_IDLE_SECS` higher than the longest interval your clients spend in a half-closed state — 60 s covers any normal HTTPS exchange. Servers that see long-polling APIs with multi-minute gaps between last-byte-in and FIN may want `RELAY_IDLE_SECS=300`.

## Port Policy

The server enforces a **default-deny allowlist** on outbound TCP and UDP. Every destination is checked **before** DNS resolution (by port) and **after** DNS resolution (by resolved IP, see [IP Policy](#ip-policy)). Blocked destinations receive a SOCKS5 reply with `REP = 0x02` ("connection not allowed by ruleset") on V1, or the equivalent V2 status on V2 CONNECT / CONNECT-UDP. The client sees this as a normal proxy refusal.

### Format

`SOCKS5_ALLOWED_PORTS` accepts a comma-separated list of individual ports and `lo-hi` ranges:

```bash
SOCKS5_ALLOWED_PORTS=22,80,443,8080,8443,853        # individual ports
SOCKS5_ALLOWED_PORTS=1-1024,8080,8443           # ranges
SOCKS5_ALLOWED_PORTS=443                        # HTTPS only
SOCKS5_ALLOWED_PORTS=*                          # allow everything
SOCKS5_ALLOWED_PORTS=                           # deny everything
```
### Why `853` is in the default

Port `853` is DNS-over-TLS. Including it in the default allowlist lets clients whose host resolver is configured for DoT — the common case on Linux systems using `systemd-resolved` — resolve names while the tunnel is up.

Without it, every DNS query on such a host fails. The resolver dials `1.1.1.1:853`, the dial is captured by the client's tunnel, and the server refuses it with `REP = 0x02`. There is no plaintext DNS fallback configured on most modern Linux hosts, so name resolution breaks entirely while the VPN is up, and every application that performs a lookup reports `SERVFAIL`. This was the default behaviour before 0.5.2 and produced an unrecoverable deadlock for affected hosts.

Clients that terminate DNS inside the server (via a dedicated handler on `10.0.0.1:53`) would not need `853` exposed. That handler does not exist yet. Until it does, `853` in the default is the pragmatic choice.

If you want to restrict `853` to a specific DoT provider (e.g. Cloudflare only), the current `PortPolicy` does not support per-destination port rules. The two options are: accept the broader exposure (any authenticated client can reach any DoT server on `:853`), or extend `lib::support::net::port_policy` with a `(port, ip_prefix)` allowlist. Neither is necessary for correctness — the DoT content itself is encrypted end-to-end to the destination provider, so the tunnel sees only opaque TLS bytes.

## IP Policy

After DNS resolution, the server checks every candidate address against a policy of "never let the tunnel reach internal infrastructure." This is the primary mitigation against **Server-Side Request Forgery (SSRF)** and against cloud metadata exfiltration.

When `SOCKS5_BLOCK_PRIVATE_IPS` is `on` (the default), the following destinations are refused regardless of port:

| Range | What it protects |
|---|---|
| `127.0.0.0/8`, `::1` | Server-local services (loopback) |
| `10.0.0.0/8` | RFC 1918 private |
| `172.16.0.0/12` | RFC 1918 private |
| `192.168.0.0/16` | RFC 1918 private |
| `169.254.0.0/16` | Link-local / APIPA / cloud metadata `169.254.169.254` |
| `100.64.0.0/10` | Carrier-grade NAT |
| `0.0.0.0`, `::` | Unspecified / wildcard |
| `fc00::/7` | IPv6 ULA |
| `fe80::/10` | IPv6 link-local |
| `255.255.255.255` | Broadcast |

Set `SOCKS5_BLOCK_PRIVATE_IPS=off` only if the server is intentionally deployed to reach internal services (e.g., as an internal-only exit node behind a firewall). For any server exposed to the internet, keep it **on**.

### Interaction with DNS

The check runs **after** resolution, so it catches:

- A client requesting `http://localhost:443` directly (resolves to `127.0.0.1`)
- A client requesting `http://10.0.0.1:443` directly (already an IP)
- A client requesting `http://internal.corp.example:443` that resolves to an RFC 1918 address
- A client requesting `http://metadata.google.internal:80` that resolves to `169.254.169.254`

It does **not** catch an HTTP redirect from a public host to an internal one. That would require parsing and rewriting HTTP inside the SOCKS5 stream, which is out of scope for a transparent SOCKS5 proxy. If you need that level of protection, restrict allowed ports further (e.g., `443` only, no `80`) so redirects cannot downgrade to plaintext.

## Security Model

### Authentication modes

The server accepts five modes, selected by `SOCKS5_TUNNEL_ENCRYPTION`, `SOCKS5_SIGNATURE_AUTH`, and the client's claimed `sig_type`. Refer to `SERVER.mods.md` for the full matrix, trust assumptions, and per-mode threat coverage.

| Mode | Encryption | Per-client identity | Revocation |
|---|---|---|---|
| Plaintext NO-AUTH | ✗ | ✗ | ✗ |
| Plaintext RFC 1929 | ✗ | password only | change password |
| Tunnel HMAC, SYSTEM | ✓ | ✗ | ✗ |
| Tunnel HMAC, CLIENT | ✓ | ✓ | ✗ |
| Tunnel HMAC, CLIENT + on-chain | ✓ | ✓ | ✓ |

Internet-facing deployments should run at minimum **Tunnel HMAC, SYSTEM**. Deployments requiring per-client identity should run **Tunnel HMAC, CLIENT**; deployments requiring revocation should run **Tunnel HMAC, CLIENT + on-chain**.

### Transport and authentication

Every connection must begin with the tunnel `Hello`. The server verifies the HMAC against a key derived from the master secret `M`:

- `SYSTEM_TYPE` (0x00): `derive_system(M)` — one shared key for all SYSTEM clients.
- `CLIENT_TYPE` (0x01): `derive_client(M, address)` — one key per client wallet address, computed from `M` and the address claimed in the Hello.

A mismatch closes the socket immediately. On success the `Welcome` is queued and all subsequent SOCKS5 framing is wrapped in ChaCha20-Poly1305.

### Startup validation

The server refuses to start with configurations that cannot serve a working client:

| Tunnel | Signature | Result |
|---|---|---|
| `false` | `false` | Allowed — Mode 1 or Mode 2 |
| `false` | `true` | **Refused** — plaintext signature transport would expose credentials |
| `true` | `false` | **Refused** — tunnel Hello cannot be verified without a signature configuration |
| `true` | `true` | Allowed — Mode 3, 4, or 5 |

The `true` / `false` combination is refused because the tunnel handshake's Hello verification requires `signature_config` to be `Some`. Without it the tunnel path closes every connection, and the only operational path would be the plaintext fallback — a silent contradiction of the operator's intent in setting the tunnel flag.

### On-chain client verification

Under `SOCKS5_SIGNATURE_AUTH=true`, a `CLIENT_TYPE` handshake is not completed until the central hub confirms the client's wallet address is on chain and not revoked. Every failure mode closes the connection before any tunnel bytes are exchanged. `SYSTEM_TYPE` handshakes bypass the check.

### Bandwidth attestation

The hub credits `min(server, client)` per session: the server's `ServerReport` and the client's `ClientAttestation` must agree. One-sided inflation is self-defeating; collusion is bounded by external evidence (synthetic clients, cohort analysis, relay-side accounting), not by cryptography. The economic model and its limits are documented in [SECURITY.md](SECURITY.md).

### Trust model

The server and the hub both hold the master secret `M`. Both can derive `derive_client(M, addr)` for any address.

- **Client-to-client impersonation is impossible.** Client B cannot produce a valid Hello for address A.
- **Server-to-client impersonation is possible.** The server holds `M` and can forge a valid Hello for any address. The on-chain check bounds which addresses can be targeted but does not prevent the server from impersonating a registered client to itself. This is acceptable for a proxy where the server already sees all plaintext.

### Privacy

Transport encryption protects data in transit. The server inherently sees the decrypted destination requests. End-to-end payload confidentiality (e.g., HTTPS) must be handled by the application layer.

### Out of scope

DNS exfiltration — a client resolving arbitrary hostnames through the server's DoT resolver to leak data — is **not** mitigated by the port or IP policies. It is intended to be handled separately in `lib::dns` (see the roadmap in that module).

---

## Client Support & Requirements

To communicate with this server, a client must implement the following:

1. **Iroh Transport:** Connect using the ALPN `socks5/1`.
2. **Tunnel Handshake:** Implement the ChaCha20-Poly1305 `Hello`/`Welcome` handshake. The `Hello` carries a signature type byte (`0x00` = SYSTEM, `0x01` = CLIENT) inside the HMAC, so a client cannot change its claimed type without invalidating the HMAC.
3. **SYSTEM_TYPE clients** must hold `derive_system(M)`. On success the `Welcome` is sent immediately; no hub interaction is involved.
4. **CLIENT_TYPE clients** must:
   - Hold `derive_client(M, address)` for the wallet address they claim in the Hello, and
   - Be registered on chain with the central hub, and not revoked.
   
   If either condition fails, the server closes the connection before sending `Welcome`. There is no path to complete the handshake without both.
5. **V2 Datagram Fragmentation:** If the client intends to proxy UDP (e.g., WebTransport), it must implement the `S5T2` framing and the datagram fragmentation logic (as documented above) to handle packets larger than ~1150 bytes.
6. **TUN/VPN Mode (Optional):** The client can act as a system-wide VPN by bridging a TUN interface (MTU 1500) to the local SOCKS5 listener.

*For detailed setup and configuration of the official client binaries, please refer to [CLIENT.md](CLIENT.md).*

## License
See repository's `LICENSE` file.
