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
- **Cross-Platform** — native support for both Linux and Windows. The server uses a unified `lib/bridge.rs` to abstract `AF_UNIX` socket pairs (Linux) and loopback pairs (Windows).
- **Configurable IP Checkers** — the public IP checker pool can be supplied via `HOST_IP_CHECKERS_LIST` to monitor the server's outbound IP.

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
             [proxy-iroh Server]
                     |
                     +---- Parses SOCKS5 (TCP) or V2 (UDP)
                     |
                     +---- Port policy check (SOCKS5_ALLOWED_PORTS)
                     |     ↓
                     +---- DNS resolution (Dot)
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
| `SOCKS5_ALLOWED_PORTS` | No | `22,80,443,8080,8443` | Server-side egress allowlist. See [Port Policy](#port-policy). |
| `SOCKS5_BLOCK_PRIVATE_IPS` | Auto-On | `on` | Block loopback / RFC 1918 / link-local / CGNAT / IPv6 ULA destinations. See [IP Policy](#ip-policy). |
| `RELAY_IDLE_SECS` | No | `60` | Seconds a half-closed relay may sit idle before being torn down. See [Relay lifecycle](#relay-lifecycle). |
| `HOST_IP_CHECKERS_LIST` | No | defaults | Comma-separated HTTPS URLs to verify server public IP. |

**Listen Address:** The server binds to `0.0.0.0:1082` by default.

### Running the Server
```bash
RUST_LOG=info \
SOCKS5_SIGNATURE_AUTH=true \
SOCKS5_TUNNEL_ENCRYPTION=on \
SOCKS5_RATE_MAX=1200 \
SOCKS5_QUOTA_MAX=256 \
SOCKS5_ALLOWED_PORTS=22,80,443,8080,8443 \
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
SOCKS5_ALLOWED_PORTS=22,80,443,8080,8443        # individual ports
SOCKS5_ALLOWED_PORTS=1-1024,8080,8443           # ranges
SOCKS5_ALLOWED_PORTS=443                        # HTTPS only
SOCKS5_ALLOWED_PORTS=*                          # allow everything
SOCKS5_ALLOWED_PORTS=                           # deny everything
```

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

### Transport & Authentication
Every connection must begin with the tunnel `Hello`. The server verifies the HMAC signature using the account's `ProxySecret`. If the first byte is not the tunnel magic, the socket is closed immediately. The SOCKS5 conversation is encrypted via ChaCha20-Poly1305.

### Strict Mode (Default)
When `SOCKS5_SIGNATURE_AUTH=true`:
- The server refuses to start if the account is missing from the database.
- Plaintext SOCKS5 greetings (e.g., `05 01 00`) are rejected instantly with no response.
- RFC 1929 auth is bypassed (identity is proven by the tunnel HMAC).

### Privacy
Transport encryption protects data in transit. The remote server inherently sees the decrypted destination requests. End-to-end payload confidentiality (like HTTPS) must be handled by the application layer.

### Out of scope
DNS exfiltration (a client resolving arbitrary hostnames through the server's DoT resolver to leak data) is **not** mitigated by the port or IP policies. It is intended to be handled separately in `lib::dns` (see the roadmap in that module).

---

## Client Support & Requirements

To communicate with this server, a client must implement the following:

1. **Iroh Transport:** Connect using the ALPN `socks5/1`.
2. **Tunnel Handshake:** Implement the ChaCha20-Poly1305 `Hello`/`Welcome` handshake using the shared `ProxySecret`.
3. **V2 Datagram Fragmentation:** If the client intends to proxy UDP (e.g., WebTransport), it must implement the `S5T2` framing and the datagram fragmentation logic (as documented above) to handle packets larger than ~1150 bytes.
4. **TUN/VPN Mode (Optional):** The client can act as a system-wide VPN by bridging a TUN interface (MTU 1500) to the local SOCKS5 listener.

*For detailed setup and configuration of the official client binaries, please refer to [CLIENT.md](CLIENT.md).*

## License
See repository's `LICENSE` file.
