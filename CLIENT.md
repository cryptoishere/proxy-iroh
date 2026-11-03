# proxy-iroh (Client)

The official client and TUN/VPN bridge for the `proxy-iroh` ecosystem. 

The client provides a local SOCKS5 endpoint (`127.0.0.1:1080` or `127.0.0.1:18080`) that applications can connect to, and transparently routes the traffic through an encrypted Iroh QUIC session to the remote `proxy-iroh` server. It also includes a system-wide TUN mode to capture all host traffic without requiring application-level proxy configuration.

*Note: This document covers the Client implementation. For the Server implementation, please see [README.md](README.md).*

## Features

- **Local SOCKS5 Proxy** — exposes a standard SOCKS5 interface (default `127.0.0.1:1080` or `18080`).
- **System-wide VPN (TUN) Mode** — uses a userspace `tun2socks` bridge to intercept all system traffic.
- **HTTP CONNECT Translation** — automatically translates HTTP `CONNECT` requests into SOCKS5 for compatibility with browser proxy settings.
- **V2 CONNECT-UDP & Fragmentation** — tunnels WebTransport, HTTP/3, and raw UDP by fragmenting packets at 900 bytes to bypass Iroh's MTU limits.
- **Leak Protection** — in TUN mode, automatically configures `iptables`, split routing, and DNS safeguards to prevent traffic from leaking outside the tunnel.
- **Encrypted Transport** — ChaCha20-Poly1305 for all data sent over Iroh.
- **Transparent Policy Handling** — server-side port and IP policies (see [Server README](README.md#security-model)) surface to the client as ordinary SOCKS5 `REP = 0x02` refusals. The client requires no configuration to support them.

## Architecture

```text
[Application / Browser]
        |
        | (SOCKS5 TCP or HTTP CONNECT)
        v
[proxy-iroh Client] <--- [TUN Interface (tun0)]
        |
        | Authenticated Iroh Session
        | Encrypted QUIC Transport
        |
        v
[proxy-iroh Server]
```

The client establishes an Iroh session with the server. For standard proxying, it listens on a local port and parses SOCKS5/HTTP. For VPN mode, it creates a TUN device, routes system traffic through it, and uses `smoltcp` to terminate TCP/UDP flows before bridging them to the local SOCKS5 listener.

## Platform Support

| Platform | Local pair mechanism | TUN/VPN Support |
|---|---|---|
| Linux | `AF_UNIX` socket pair | ✅ Yes (requires `CAP_NET_ADMIN`) |
| Windows | Loopback TCP/UDP pair | ❌ No (planned) |

---

## Configuration

### Environment Variables

| Setting | Required | Meaning |
|---|---|---|
| `TUNNEL_ENCRYPTION_SECRET` | Yes | The Base64-encoded `ProxySecret` shared with the server. |
| `REGISTRATION_IDENT_ADDRESS` | Yes | The registered proxy address (e.g., `SMVV4f...`). |
| `TARGET_ENDPOINT_X1_SOCKS5_13` | Yes | The Iroh `EndpointId` of the remote server. |
| `RELAY_URL_PUBLIC` | Yes | The Iroh relay URL used for NAT traversal (e.g., `https://relay.example.com`). |
| `CLIENT_SOCKET_ADDRESS_BIND` | Yes (TUN) | Your physical IP address (e.g., `192.168.1.50`). **Do not use `0.0.0.0`.** |
| `CLIENT_SOCKET_PORT_BIND` | Yes (TUN) | The physical UDP port to bind for Iroh (e.g., `60000`). |
| `IROH_ADVERTISE_HOST` | No | Public IP/hostname to advertise to the relay. |
| `IROH_ADVERTISE_PORT` | No | Public port to advertise to the relay. |

The client **does not** expose any setting corresponding to the server's `SOCKS5_ALLOWED_PORTS` or `SOCKS5_BLOCK_PRIVATE_IPS`. Those are enforced server-side and cannot be bypassed or weakened by the client. See [Egress control on the server](README.md#security-model) for what traffic will be refused.

### Data Flow & MTU Requirements
The client enforces a TUN MTU of **1500 bytes**. This is critical. QUIC Initial packets are typically padded to 1250 bytes; wrapping them in a UDP/IP header requires 1378 bytes. If the MTU is lower (e.g., 1280), the OS silently drops the packets, leading to TLS truncation (`ERR_SSL_PROTOCOL_ERROR`) and WebTransport timeouts.

---

## Running the Client (SOCKS5 Mode)

This mode does not require root privileges. It simply exposes a local proxy port.

```bash
TUNNEL_ENCRYPTION_SECRET="your_secret_here" \
REGISTRATION_IDENT_ADDRESS="SMVV4fAq..." \
TARGET_ENDPOINT_X1_SOCKS5_13="6d9640d..." \
RELAY_URL_PUBLIC="https://relay.example.com" \
./client_tunnel
```

Once running, configure your browser or use `curl`:
```bash
curl -v --proxy socks5h://127.0.0.1:1080 https://smartholdem.io
```

---

## Running the Client (TUN/VPN Mode)

This mode requires root (`sudo`) to create the TUN device and modify routing tables.

```bash
sudo -E ./vpn_client
```

### What happens under the hood:
1. **TUN Setup** (`tun_setup.rs`): Creates a TUN device (`tun0`) with IP `10.0.0.2/24` and MTU `1500`.
2. **Leak Protection** (`leaks.rs`): Installs firewall and routing rules:
   - Blocks IPv6 (to prevent leaks if the tunnel is IPv4-only).
   - Creates a split-default route in table `100` (`0.0.0.0/1` and `128.0.0.0/1`) to capture all non-local traffic.
   - Exempts the physical network interface for the Iroh transport by binding to `CLIENT_SOCKET_ADDRESS_BIND`.
   - Exempts `systemd-resolved` (if present) so DNS bootstrap can succeed.
   - Adds an `iptables` kill switch rejecting non-root traffic from bypassing the tunnel via the physical interface.
3. **tun2socks** (`tun2socks.rs`): Intercepts TCP SYN packets via `smoltcp`, spawns local SOCKS5 tasks, and forwards UDP packets via the V2 CONNECT-UDP protocol.
4. **Cleanup**: Dropping the `LeakGuard` automatically removes the routing and firewall rules.

### Routing Exemptions
To prevent a routing loop (where the encrypted Iroh traffic routes back into the tunnel itself), the client MUST bind to a specific physical interface IP. Setting `CLIENT_SOCKET_ADDRESS_BIND` to the IP of your Wi-Fi or Ethernet card (e.g., `192.168.1.50`) ensures the `ip rule` exemptions apply only to the Iroh transport.

---

## Troubleshooting

### "Connection refused" / `REP = 0x02` from the server
**Symptom:** A specific destination works from the internet but fails through the proxy with a SOCKS5 "connection not allowed by ruleset" reply (0x02). Browsers may show `ERR_PROXY_CONNECTION_FAILED`, `ERR_TUNNEL_CONNECTION_FAILED`, or a generic "connection was reset".

**Cause:** The server's egress policy refused the destination. Two independent checks can produce this:

1. **Port policy** — the destination port is not in the server's `SOCKS5_ALLOWED_PORTS` allowlist. Defaults block mail ports (25/465/587/143/993/110/995), RDP (3389), VNC (5900/5901), SMB (139/445), LDAP (389/636), and every database port (3306, 5432, 1433, 6379, 11211, 27017, 9200, 9300). If the destination is a legitimate service on a non-default port, the server operator must add that port.
2. **IP policy** — the destination resolved to a loopback, RFC 1918, link-local, CGNAT, or IPv6 ULA address. This is intentional SSRF protection; there is no client-side workaround.

**Fix:** This is not a client bug. Contact the server operator to adjust `SOCKS5_ALLOWED_PORTS` or `SOCKS5_BLOCK_PRIVATE_IPS` on the server. On the client side, verify the destination is actually public and on a permitted port:

```bash
curl -v --proxy socks5h://127.0.0.1:1080 https://example.com:443    # expected: works
curl -v --proxy socks5h://127.0.0.1:1080 http://example.com:25      # expected: REP 0x02
```

If the port is in the default allowlist but you still see refusals, check whether the destination resolves to a private IP:

```bash
dig +short example.internal.example.com
```

### WebTransport / QUIC Timeout
If you see `net::ERR_QUIC_PROTOCOL_ERROR.QUIC_NETWORK_IDLE_TIMEOUT`:
- **Cause:** Either (a) a 1250-byte QUIC Initial packet exceeded Iroh's per-datagram limit before V2 fragmentation was implemented, or (b) the server's `IROH_READ_KILL_SECS` watchdog fired on a WebTransport session that had completed its handshake and was legitimately idle.
- **Fix:** Ensure both client and server are running the latest version of `proxy-iroh` (`MAX_CHUNK = 900` fragmentation). If the error persists on **first navigation only**, it indicates a genuine datagram stall — check the server logs.

### `ERR_SSL_PROTOCOL_ERROR` in Browser
If pages load partially or fail TLS handshakes when using TUN mode:
- **Cause:** The TUN MTU is set too low. When the server sends a 1350-byte QUIC response, `tun2socks` wraps it in a 1428-byte IP packet. If the TUN MTU is 1280, the OS drops it.
- **Fix:** Verify `TUN_MTU` is set to `1500` in both `vpn_client.rs` and `QueueDevice::new()` in `tun2socks.rs`.

### DNS Resolution Fails in VPN Mode
- **Cause:** The system resolver cannot reach upstream DNS servers because the route is trapped in the TUN.
- **Fix:** The client automatically exempts `systemd-resolve`. If you are using a different resolver (e.g., NetworkManager, `dnsmasq`), ensure it is also exempted in `leaks.rs` or configure `/etc/resolv.conf` to point to a public resolver (e.g., `1.1.1.1`).

---

## Client Requirements
If you are building a custom client, it must satisfy the following to communicate with a `proxy-iroh` server:
1. **ALPN:** Connect to the server using `socks5/1`.
2. **Handshake:** Implement the ChaCha20-Poly1305 `Hello`/`Welcome` handshake using the shared `ProxySecret`.
3. **V2 Datagram Support:** Implement the `S5T2` framing (refer to the Server `README.md` for the fragment header layout) to support UDP and WebTransport.
4. **MTU:** Ensure local TUN devices are configured with an MTU of at least 1500 to prevent silent packet drops.

## License
See repository's `LICENSE` file.
