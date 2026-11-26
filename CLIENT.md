# proxy-iroh (Client)

The official client and TUN/VPN bridge for the `proxy-iroh` ecosystem.

The client provides a local SOCKS5 endpoint (`127.0.0.1:1080`) that applications can connect to, and transparently routes the traffic through an encrypted Iroh QUIC session to the remote `proxy-iroh` server. It also includes a system-wide TUN mode to capture all host traffic without requiring application-level proxy configuration.

*Note: This document covers the Client implementation. For the Server implementation, please see [README.md](README.md).*

## Features

- **Local SOCKS5 Proxy** — exposes a standard SOCKS5 interface on `127.0.0.1:1080`.
- **System-wide VPN (TUN) Mode** — a single `sudo ./vpn_client` invocation brings up the tunnel, installs routing, and captures all host traffic.
- **Bootstrap-Before-Capture Ordering** — the relay is resolved and a full SOCKS5 round-trip to a known destination succeeds *before* any routing or firewall rule is installed. A partially-configured VPN never takes over the network.
- **HTTP CONNECT Translation** — automatically translates HTTP `CONNECT` requests into SOCKS5 for compatibility with browser proxy settings.
- **V2 CONNECT-UDP & Fragmentation** — tunnels WebTransport, HTTP/3, and raw UDP by fragmenting packets at 900 bytes to bypass Iroh's MTU limits.
- **Source-Address Routing Exemption** — only sockets iroh has explicitly bound to the physical interface IP are exempted from the tunnel; every other process, including root, is captured. This closes the historical "any root process bypasses the VPN" leak.
- **Fail-Closed Kill Switch** — if any part of setup fails (routing, firewall, TUN), the client rolls back and exits rather than leaving the host in a partially-tunneled state.
- **Local CIDR Bypass (`bypass_cidrs`)** — Docker bridges, VM host gateways, and
  other local subnets can be explicitly pinned to a physical interface via
  more‑specific routes in the VPN table. Longest‑prefix‑match guarantees the
  bypass always wins over the split‑default `/1` routes, with no impact on
  tunnel coverage for every other destination. Fixes the common
  "`docker -p 127.0.0.1:5432:5432` becomes unreachable while the VPN is up"
  class of problems without touching the server's `SOCKS5_BLOCK_PRIVATE_IPS`
  or `SOCKS5_ALLOWED_PORTS` policy.
- **Transactional Cleanup** — the client tracks exactly which resources it installed and reverts only those, in reverse order, on every exit path (clean shutdown, Ctrl-C, or setup failure). Coexisting VPNs using other route tables or rule priorities are unaffected.
- **DNS Through the Tunnel by Default** — every DNS query on the host is captured by the tunnel like any other traffic. On hosts using `systemd-resolved` with DoT upstreams (the common Linux configuration), the tunnel carries the DoT stream to the server, which forwards it to the configured DoT provider. No plaintext DNS reaches the ISP, and the historical `systemd-resolved` UID exemption is gone. Requires port `853` in the server's `SOCKS5_ALLOWED_PORTS` (included in the default since 0.5.2). The `VPN_MANAGE_DNS` rewrite of `/etc/resolv.conf` is **not** the mechanism — it is a separate opt-in that requires a server-side DNS handler and is currently disabled by default.
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

> For standard proxying, the client listens on a local port and parses SOCKS5/HTTP. For VPN mode, it creates a TUN device (Linux `tun` driver, Windows WinTun), routes system traffic through it, and uses `smoltcp` to terminate TCP/UDP flows before bridging them to the local SOCKS5 listener over a `socketpair(2)` on Linux or a loopback TCP pair on Windows. On Windows, `Wintun` needs `wintun.dll` next to the executable or on `PATH`; the WinTun adapter is named by `VPN_TUN_NAME` (default `tun0`).

The VPN mode is driven by the `VpnClient` lifecycle in `lib::vpn::client`:

```text
Disconnected
    │
    ▼
Bootstrapping      ← relay hostname + TCP reachability verified
    │
    ▼
Connecting         ← iroh endpoint + local SOCKS5 bridge started
    │
    ▼
(end-to-end SOCKS5 round-trip to 1.1.1.1:443 must succeed)
    │
    ▼
Configuring        ← TUN created, kill switch installed, routes added
    │
    ▼
Connected          ← tun2socks forwarding runs until cancellation
    │
    ▼
Disconnecting      ← routes removed, kill switch removed, DNS restored
    │
    ▼
Disconnected
```

Any failure before `Connected` rolls back to `Disconnected`. Any failure after `Connected` (e.g. `tun2socks` exits unexpectedly) triggers the same shutdown path.

## Platform Support

| Platform | Local pair mechanism | TUN/VPN Support |
|---|---|---|
| Linux | `AF_UNIX` `socketpair(2)` | ✅ Yes — requires `CAP_NET_ADMIN` (or root) and `iptables` |
| Windows | Loopback TCP pair on `127.0.0.1:0` | ✅ Yes — requires an elevated token (Administrator) and `wintun.dll` on `PATH` or beside the executable |
| macOS | (planned) | ❌ No |
| Android | (planned) | ❌ No |

The two non‑Linux platforms use the same lifecycle, same `InstallConfig`,
and same policies; only the underlying command surfaces differ:

| Operation | Linux | Windows |
|---|---|---|
| Split‑default routes | `ip route … table <n>` | `route add` (main FIB, metric 1) |
| Source‑address exemption | `ip rule from <ip> lookup main priority 90` | n/a — `route.exe` has no `from` predicate. Relay IPs are pinned via `/32` routes to the physical `ifIndex` |
| IPv6 block | `ip -6 route add unreachable default metric 1` | n/a — the tunnel is IPv4‑only; `IrohClientConfig` clears IPv6 transports |
| Kill switch | `iptables -m owner ! --uid-owner root -o <phys> -j REJECT` | `netsh advfirewall` block rule scoped to `interface="<phys>"`, plus an allow rule for `program="<exe>"` |
| DNS | Save/restore `/etc/resolv.conf` (symlink‑aware) | `netsh interface ipv4 set dnsservers …` — restores via DHCP or explicit static list |
| Interface lookup | `ip route get` | `Get‑NetRoute` / `Get‑NetAdapter` via PowerShell |

---

## Configuration

### Environment Variables

| Setting | Required | Meaning |
|---|---|---|
| `TUNNEL_ENCRYPTION_SECRET` | Yes | The Base64-encoded `ProxySecret` received via hub. |
| `TUNNEL_KDF_ENCRYPTION_SECRET` | Yes | The Base64-encoded `ProxySecret` received via hub. |
| `REGISTRATION_IDENT_ADDRESS` | Yes | The registered proxy address (e.g., `SMVV4f...`). |
| `TARGET_ENDPOINT_X1_SOCKS5_13` | Yes | The Iroh `EndpointId` of the remote server. |
| `RELAY_URL_PUBLIC` | Yes | The Iroh relay URL used for NAT traversal (e.g., `https://smartholdem-block.duckdns.org:3341`). |
| `HUB_ATTEST_URL` | Yes | Attestation report within the tunnel (defaults to `https://crypto-ig.com/api/v1/reports/bandwidth/attest`). |
| `CLIENT_SOCKET_ADDRESS_BIND` | Yes (TUN) | Your physical IP address (e.g., `192.168.1.50`). **Do not use `0.0.0.0`** — the client refuses to start otherwise. |
| `CLIENT_SOCKET_PORT_BIND` | Yes (TUN) | The physical UDP port to bind for Iroh (e.g., `60000`). |
| `IROH_ADVERTISE_HOST` | No | Public IP/hostname to advertise to the relay. |
| `IROH_ADVERTISE_PORT` | No | Public port to advertise to the relay. |
| `VPN_TUN_NAME` | No | TUN device name. Default `tun0`. |
| `VPN_ROUTE_TABLE` | No | Route table used for tunnel routes. Default `1600000`. Override if that collides with another VPN. |
| `VPN_BYPASS_CIDRS` | No | Comma‑separated `<CIDR>=<iface>` pairs installed as more‑specific routes in `VPN_ROUTE_TABLE` so they bypass the tunnel. **Linux:** `<iface>` is the `dev` name (`docker0`, `br-xxxxx`). **Windows:** `<iface>` is an interface alias, or **empty** to auto‑resolve from `Get-NetIPAddress`; if no host interface owns the CIDR (Docker Desktop/WSL2 internal), the entry is logged and skipped. Example: `10.10.20.0/28=br-9acee09147e0,172.17.0.0/16=docker0`. Get the exact `<iface>` on Linux via `ip -br link show type bridge`; on Windows via `Get-NetAdapter`. Default: empty. |
| `VPN_MANAGE_DNS` | No | If truthy, the client saves and rewrites `/etc/resolv.conf` to point at the tunnel gateway (`10.0.0.1`), restoring it on exit. **Requires a DNS handler on `10.0.0.1:53` on the server, which is not yet implemented.** Do not enable on hosts where `systemd-resolved` is running with DoT upstreams — the client's own resolver already works through the tunnel if `853` is in `SOCKS5_ALLOWED_PORTS` on the server, and rewriting `/etc/resolv.conf` breaks `dig` and any tool that reads it directly. On Windows the argument passed to `netsh` is `<tun_name>=<gateway>` (e.g. `tun0=10.0.0.1`), so the client knows which adapter to rewrite. Default `false`. |

The client **does not** expose any setting corresponding to the server's `SOCKS5_ALLOWED_PORTS` or `SOCKS5_BLOCK_PRIVATE_IPS`. Those are enforced server-side and cannot be bypassed or weakened by the client. See [Egress control on the server](README.md#security-model) for what traffic will be refused.

### Data Flow & MTU Requirements
The client enforces a TUN MTU of **1500 bytes**. This is critical. QUIC Initial packets are typically padded to 1250 bytes; wrapping them in a UDP/IP header requires 1378 bytes. If the MTU is lower (e.g., 1280), the OS silently drops the packets, leading to TLS truncation (`ERR_SSL_PROTOCOL_ERROR`) and WebTransport timeouts.

---

## Running the Client (SOCKS5 Mode)

This mode does not require root privileges. It simply exposes a local proxy port.

```bash
TUNNEL_ENCRYPTION_SECRET="your_secret_here" \
TUNNEL_KDF_ENCRYPTION_SECRET="your_secret_here" \
REGISTRATION_IDENT_ADDRESS="SMVV4fAq..." \
TARGET_ENDPOINT_X1_SOCKS5_13="6d9640d..." \
./lightweight-client
```

Once running, configure your browser or use `curl`:
```bash
curl -v --proxy socks5h://127.0.0.1:1080 https://smartholdem.io
```

---

## Running the Client (TUN/VPN Mode)

Requires root (`sudo`) to create the TUN device and modify routing tables.

```bash
sudo -E ./vpn_client
```

Before the first run, confirm your physical IP and that the chosen route table and rule priorities are free:

```bash
# Physical interface IP (the value for CLIENT_SOCKET_ADDRESS_BIND)
ip route get 1.1.1.1 | awk '{for(i=1;i<=NF;i++) if($i=="src") print $(i+1)}'

# Route table 1600000 should be empty
ip route show table 1600000

# Rule priorities 90 and 200 should be free
ip rule | grep -E 'priority (90|200)\b'
```

### What happens under the hood

1. **Bootstrap** (`vpn/bootstrap.rs`): resolves the relay hostname and verifies at least one returned address accepts a TCP connection on the relay port. Runs before any routing change, using the pre-existing default route.
2. **Transport** (`vpn/bridge.rs`): starts the local SOCKS5 listener and the iroh endpoint. Binds to `CLIENT_SOCKET_ADDRESS_BIND` so that outbound transport traffic carries a predictable source address.
3. **End-to-end test** (`vpn/client.rs`): performs a full SOCKS5 `CONNECT` to `1.1.1.1:443` through the local bridge. This exercises the tunnel handshake, the server relay, and the server's port policy before any traffic is captured. If it fails, the client shuts down and exits — nothing is installed.
4. **TUN creation** (`vpn/tun_setup.rs`): creates `tun0` with IP `10.0.0.2/24` and MTU `1500`.
5. **Routing and kill switch** (`vpn/leaks.rs`):
   - Adds a more‑specific route for every entry in `VPN_BYPASS_CIDRS` **first**,
     so they are the last thing torn down at shutdown. On Linux:
     `ip route replace <cidr> dev <iface> table <n>`. On Windows: an on‑link
     `route add <cidr> 0.0.0.0 if <ifIndex>` at metric 1. Longest‑prefix‑match
     makes these beat the split‑default `/1` routes regardless of ordering.
   - Adds split-default routes (`0.0.0.0/1`, `128.0.0.0/1`) to the VPN route table only. `main` is untouched.
   - Blackholes `224.0.0.0/4`, `240.0.0.0/4`, and `255.255.255.255/32` so mDNS/SSDP/broadcast never reach the tunnel.
   - Blocks IPv6 with an `unreachable` default route.
   - Installs the transport exemption as **`ip rule from <CLIENT_SOCKET_ADDRESS_BIND> lookup main priority 90`**. This matches only iroh's own sockets, not all root traffic.
   - Installs the tunnel default as `ip rule lookup <VPN_ROUTE_TABLE> priority 200`.
   - Installs a fail-closed iptables kill switch: non-root egress to the physical interface is `REJECT`ed; forwarding from `tun0` to the physical interface is explicitly `ACCEPT`ed.
   - Each installed resource is tracked individually; if any step fails, only the ones already installed are rolled back.
6. **DNS** (`vpn/dns.rs`, if `VPN_MANAGE_DNS` is enabled): records whether `/etc/resolv.conf` is a symlink or a file, then replaces it with one that points at `10.0.0.1`. On shutdown, restores the original exactly (as a symlink if it was a symlink, as a file if it was a file).
7. **Forwarding** (`vpn/tun2socks.rs`): intercepts TCP SYNs via `smoltcp`, spawns per-flow SOCKS5 tasks, and forwards UDP via V2 CONNECT-UDP.
8. **Shutdown** (`vpn/leaks.rs::Drop` and `vpn/client.rs`): routes are removed, then the kill switch, then `/etc/resolv.conf` is restored — in reverse order of installation. Finally the local SOCKS5 bridge and iroh endpoint are stopped.

A partial installation — for example, TUN created but firewall rule failed — is rolled back in full. The host does not end up in a state where traffic goes into `tun0` with no firewall keeping it off the physical interface.

### Traffic Routing Model

The VPN's central question — **does this packet go through the tunnel or does it leave the host directly?** — is answered by two `ip rule` entries and one `/32` route. Everything below is a consequence of those three facts:

```
90:  from 192.168.0.12 lookup main              ← bypass rule
200: from all lookup 1600000                    ← tunnel rule
     route 37.60.224.253/32 via <gw> dev wlo1   ← per-relay bypass (more specific)
       src 192.168.0.12
```

Everything is **source-address based**, not UID based. There are no `uidrange` rules, including for root. The source address is decided by the kernel during route selection: if the socket has not been pre-bound, the kernel assigns the source from the route it picks.

#### Quick reference

| Traffic class | Path | Mechanism | Notes |
|---|---|---|---|
| **Application traffic — normal user** (browsers, curl, apt, etc.) | **Tunnel** | source unbound → `priority 200` → table `1600000` → `default dev tun0` | Source becomes `10.0.0.2` |
| **Application traffic — root** (`sudo curl`, `sudo apt`, …) | **Tunnel** | same as above — no root exemption exists | This is the fix that distinguishes the current client from earlier versions |
| **systemd-resolved DoT dials** (`1.1.1.1:853`) | **Tunnel** | same as application traffic | Server must allow port `853` (in default since 0.5.2) |
| **Any DNS query that bypasses systemd-resolved** (`dig` reading `/etc/resolv.conf`, static Go binaries, containers) | **Tunnel** | same as application traffic | Server must allow the port the resolver queries |
| **UDP to multicast / broadcast** (`224.0.0.0/4`, `240.0.0.0/4`, `255.255.255.255/32`) | **Blocked** | `blackhole` route in table `1600000` | Never leaves the host. mDNS, SSDP, LLMNR, DHCP — all dropped |
| **Any IPv6 traffic** | **Blocked** | `ip -6 route add unreachable default metric 1` | No tunneled IPv6 exists in this build |
| **iroh QUIC UDP socket** | **Bypass** | socket pre-bound to `192.168.0.12` via `bind_addr_with_opts` → matches `priority 90` | Source is `192.168.0.12` |
| **iroh TCP relay dials** (`iroh_relay::client`) | **Bypass** | `/32` route in table `1600000` for each resolved relay IP, with `src 192.168.0.12` forced | More specific than `default dev tun0`, so it wins |
| **Docker bridge IP without `bypass_cidrs`** (e.g. `10.10.20.2`) | **Tunnel** | `0.0.0.0/1` → `tun0` | Server `is_forbidden_ip` rejects private targets with `REP=0x02` |
| **Docker bridge IP with `bypass_cidrs`** | **Bypass** | `<cidr> dev <bridge_iface>` in table `1600000` | More specific than `/1`; never enters `tun0` |
| **Relay IPs pinned to physical NIC** | **Bypass** | `<relay>/32 via <gw> dev <phys> src <transport>` | Already covered above; listed here for completeness |
| **Relay hostname resolution** (bootstrap only) | **Bypass** | Happens before `priority 200` is installed | Uses the host resolver over the physical default route |
| **A malicious root process that deliberately `bind()`s to `192.168.0.12`** | **Bypass** | Matches `priority 90` | Known limitation — see below |
| **Traffic during bootstrap** (before routing is installed) | **Bypass** | No VPN rules exist yet | Brief; only the relay verification and connectivity test run in this window |
| **Traffic during shutdown** (after routing is removed) | **Bypass** | Rules removed before the transport stops | A few hundred ms; kill switch is also gone, so this is a normal network state, not a leak |

#### Through the tunnel — in detail

Any packet whose source the kernel has not pre-assigned goes through `priority 200 → table 1600000 → default dev tun0`. In practice this is **every TCP connection and every UDP datagram the host originates**, regardless of which process created the socket or which user owns it. The kernel assigns `10.0.0.2` as the source and forwards to `tun0`, where `tun2socks` wraps each flow in a SOCKS5 request to the local bridge and forwards it over the iroh tunnel to the server.

What happens **at the server** for tunneled traffic:

- **Port allowlist** (`SOCKS5_ALLOWED_PORTS`) — the destination port must be in the allowlist, otherwise the server returns `REP = 0x02`. Default: `22,80,443,8080,8443,853`. This is why SMTP, RDP, SMB, MySQL, and every database port are refused even though they are tunneled.
- **IP policy** (`SOCKS5_BLOCK_PRIVATE_IPS`) — the resolved destination must be a public IP, otherwise `REP = 0x02`. This is why destinations on `127.0.0.0/8`, `10.0.0.0/8`, `192.168.0.0/16`, `169.254.0.0/16`, and similar ranges are refused even though they are tunneled.

So "goes through the tunnel" is not the same as "reaches its destination." It means the packet **reaches the server** and is then subject to the server's policy. A refused connection from the tunnel is a normal proxy refusal — the client sees `REP = 0x02` and the application sees `ECONNREFUSED` (or its equivalent), not a hang.

#### Bypasses the tunnel — in detail

Four categories of traffic leave the host directly:

**1. iroh's QUIC UDP socket.** When `vpn_client` starts, it creates the iroh endpoint with `bind_addr_with_opts(CLIENT_SOCKET_ADDRESS_BIND, …)`. That call binds the UDP socket to `192.168.0.12:<port>`. From that moment on, every datagram from that socket carries source `192.168.0.12` and therefore matches `priority 90`, which routes it out the physical interface. This is the transport itself — it is the tunnel.

**2. iroh's TCP relay dials.** `iroh_relay::client` opens plain TCP sockets to the relay endpoints. It does not respect `bind_addr_with_opts` — that setting only affects the QUIC socket. Without the `/32` route, those dials would enter `tun0` and immediately deadlock (the tunnel needs the relay, and the relay dial is inside the tunnel). To prevent this, the client adds a more-specific route for each relay IP to table `1600000` with `via <gateway> dev <physical> src 192.168.0.12` forced. The `/32` wins longest-prefix-match against `default dev tun0` and sends the dial out the physical interface with the correct source address.

The consequence of this rule: **the relay IPs are reachable as if the tunnel were not up.** If you run `curl 37.60.224.253:3341` while the VPN is active, it will not go through the tunnel — it will dial the relay directly from the physical interface. This is intentional (it is what keeps the tunnel alive) but worth understanding.

**3. Relay hostname resolution, at bootstrap.** Before any routing is installed, `vpn/bootstrap.rs` resolves `smartholdem-block.duckdns.org` using the normal system resolver. That query goes over the physical default route (no VPN rule exists yet). The result is verified (TCP connect to the relay port must succeed) before proceeding. Once routing is up, iroh has this IP cached and does not re-resolve it.

**4. Deliberate bypass by a root process.** A process running as root can call `bind(192.168.0.12, 0)` on a socket before connecting. The kernel then assigns `192.168.0.12` as source, the packet matches `priority 90`, and it leaves the physical interface. The iptables kill switch does not stop this because its only rule is `! --uid-owner root -o <physical> -j REJECT` — root-egress is permitted so the transport can function.

This is a fundamental limitation of source-address routing. Routing cannot distinguish "iroh" from "root pretending to be iroh." Closing this gap requires one of:

- **`SO_MARK` on iroh's sockets** — a per-socket tag iptables can match. `iroh 1.x` does not currently expose this.
- **Running iroh as a dedicated non-root user** and tightening the kill switch to `! --uid-owner iroh-vpn -o <physical> -j REJECT`.
- **Network-namespace isolation** of the transport.

None of these are implemented. The current model is **fail-closed for ordinary processes (including root that does not deliberately bind the physical IP)** and **fail-open for a deliberate attacker with root**.

**5. Bypass CIDRs — Docker bridges, VM gateways, loopback‑adjacent subnets.**

`docker-proxy` (the default `userland-proxy: true`) opens a *second* TCP
connection from `127.0.0.1:<ephemeral>` to the container's bridge IP, e.g.
`10.10.20.2:5432`. Without a bypass, this destination matches `0.0.0.0/1
dev tun0` and enters the tunnel. The server's `is_forbidden_ip` (RFC1918)
rejects it with `REP=0x02`, and the user sees `EOFException` in DBeaver,
`ECONNREFUSED` from `psql`, etc.

`VPN_BYPASS_CIDRS` fixes this without weakening any policy. The client
installs a route in `VPN_ROUTE_TABLE` that names the bridge as the egress
interface. Because it is longer than `/1`, longest‑prefix‑match sends the
traffic to the bridge instead of `tun0`.

```bash
# Linux — find the exact CIDR / interface
ip -br addr show type bridge
# br-9acee09147e0  10.10.20.1/28  ← CIDR = 10.10.20.0/28, iface = br-9acee09147e0

sudo VPN_BYPASS_CIDRS=10.10.20.0/28=br-9acee09147e0 -E ./vpn_client
```

```powershell
# Windows — Docker Desktop (WSL2 backend): the CIDR lives inside the VM,
# the host has no interface on it, so the client logs
#   "no Windows interface owns this CIDR; assuming Docker Desktop/WSL2
#    internal — no host route needed"
# and skips cleanly. 127.0.0.1:5432 from the host works because WSL2
# localhostForwarding delivers it into the VM before any host route
# exists.

# Windows — Windows Server with native containers: the "nat" network
# IS on the host.
$env:VPN_BYPASS_CIDRS = "10.10.20.0/28=vEthernet (nat)"
.\vpn_client.exe
```

**What this does *not* do:** it does not weaken server policy. The bypass
route is client‑side only. Any traffic that *does* enter `tun0` (public
internet, relay IPs already covered, any destination not in
`VPN_BYPASS_CIDRS`) is still subject to `is_forbidden_ip` and
`SOCKS5_ALLOWED_PORTS`.

#### Blocked traffic — in detail

Two categories are dropped before any routing decision:

- **IPv4 multicast, reserved, and broadcast.** `224.0.0.0/4`, `240.0.0.0/4`, and `255.255.255.255/32` get `blackhole` routes in table `1600000`. mDNS beacons (`224.0.0.251:5353`), SSDP discovery (`239.255.255.250:1900`), LLMNR, and DHCP broadcast never reach `tun2socks` — they are discarded at the route lookup, before any SOCKS5 task is spawned. This is what prevents the "one wasted iroh Connection per mDNS beacon" pattern that earlier builds exhibited.

- **IPv6.** An `unreachable` default at metric 1 makes all IPv6 attempts fail immediately with `ENETUNREACH`. There is no IPv6 tunnel in this build. Hosts on an IPv6-only network will have no connectivity while the VPN is up.

The one consequence worth noting: **LAN services that rely on multicast are unreachable while the VPN is up.** Avahi/Bonjour discovery, Chromecast discovery, network printers, and DHCP renewal all break. This is a deliberate choice — multicast is a per-segment protocol and should not traverse a VPN — but it is visible to users.

#### Special case: `VPN_MANAGE_DNS=true`

With `VPN_MANAGE_DNS=true` (not the default), the client rewrites `/etc/resolv.conf` to `nameserver 10.0.0.1`. In this mode:

- Applications that read `/etc/resolv.conf` directly (`dig`, static Go binaries, some container DNS setups) send queries to `10.0.0.1:53`, which is **inside the tunnel** (source `10.0.0.2` → `tun0` → server).
- **The server does not listen on `10.0.0.1:53`.** This is the missing server-side DNS handler.
- Those queries fail. `dig` reports `connection refused` or times out.
- Applications using `nss-resolve` (most apps on a systemd host) are unaffected — they still query systemd-resolved on `127.0.0.53`, which is loopback and works, and systemd-resolved's own DoT dial continues to work through the tunnel via `853`.

Do not enable `VPN_MANAGE_DNS=true` until the server-side DNS handler is implemented. The setting exists for that future state and is not correct for the current build.

#### Verifying the routing model on a live host

```bash
# Default lookup for a public destination → tunnel
ip route get 1.1.1.1
# Expect: 1.1.1.1 dev tun0 src 10.0.0.2

# Lookup with explicit source = physical IP → bypass
ip route get 1.1.1.1 from 192.168.0.12
# Expect: 1.1.1.1 via <router> dev wlo1 src 192.168.0.12

# Lookup for a relay IP → bypass via /32, even without an explicit source
ip route get 37.60.224.253
# Expect: 37.60.224.253 via <router> dev wlo1 src 192.168.0.12

# Multicast is blackholed
ip route get 224.0.0.251
# Expect: RTNETLINK answers: Network is unreachable

# IPv6 is blocked
ip -6 route get 2606:4700:4700::1111
# Expect: RTNETLINK answers: Network is unreachable

# Actual source of a live relay connection
sudo ss -tnp | grep 3341
# Expect: 192.168.0.12:* → <relay IP>:3341

# Actual source of a live application connection
curl -s https://ifconfig.me/ip &
sudo ss -tnp | grep ESTAB | grep -vE '192\.168\.0\.12|127\.0\.0\.1'
# Expect: 10.0.0.2:* → <server IP>:*
```

If `ip route get 1.1.1.1` shows `dev tun0 src 10.0.0.2`, the tunnel rule is in place. If `ip route get 1.1.1.1 from 192.168.0.12` shows the physical interface, the source-address exemption is working. Those two results define the model described above.

#### What this model does not do

- It does not preserve LAN multicast reachability (mDNS, SSDP, DHCP) — those are blackholed.
- It does not tunnel IPv6.
- It does not resurrect **public** addresses that the server's policy refuses (`REP=0x02`). Use `VPN_BYPASS_CIDRS` only for **local** CIDRs; there is no client-side way to override `is_forbidden_ip` or `SOCKS5_ALLOWED_PORTS` on the server.

---

## Troubleshooting

### `vpn_client` exits during "Bootstrapping"
**Cause:** the relay hostname could not be resolved, or none of its addresses accepted a TCP connection on the relay port within the timeout.

**Fix:** check that the host has working DNS *before* the VPN starts:

```bash
dig +short smartholdem-block.duckdns.org
nc -zvw3 smartholdem-block.duckdns.org 3341
```

The bootstrap phase never touches the tunnel; if it fails, the problem is upstream of the VPN.

### `vpn_client` exits during "Connecting" with "connectivity test failed"
**Cause:** the full SOCKS5 round-trip through the tunnel did not succeed within 15 s. Either the server is down, the port policy refused `1.1.1.1:443` (unlikely, it is in the default allowlist), the transport handshake failed, or the server's `CONN_HARD_IDLE_SECS` / `IROH_READ_KILL_SECS` watchdog is firing incorrectly.

**Fix:** run the SOCKS5 mode (`./lightweight-client`) and try the same connection manually:

```bash
curl -v --proxy socks5h://127.0.0.1:1080 https://1.1.1.1:443
```

If that fails, the issue is on the tunnel or server side, not in the VPN lifecycle. The client refuses to install routing until this works, so a failure here leaves the host untouched and safe to retry.

### `vpn_client` starts but no traffic passes
**Cause:** most commonly `CLIENT_SOCKET_ADDRESS_BIND` is not the actual physical interface IP, or was changed after start.

**Fix:** confirm the source-address rule is being hit:

```bash
# While vpn_client is running
ip rule | grep 'priority 90'
# Should show:  from 192.168.x.y lookup main

# Confirm iroh is actually using that source
sudo ss -unp | grep iroh
# Should show:  UNCONN ... 192.168.x.y:60000  ...  not 0.0.0.0:60000
```

If `ss` shows iroh bound to `0.0.0.0`, the source-address rule never matches, iroh's own transport routes into the tunnel, and the tunnel deadlocks. Ensure the client received `CLIENT_SOCKET_ADDRESS_BIND` as a concrete IP.

### "Connection refused" / `REP = 0x02` from the server
**Symptom:** A specific destination works from the internet but fails through the proxy with a SOCKS5 "connection not allowed by ruleset" reply (0x02). Browsers may show `ERR_PROXY_CONNECTION_FAILED`, `ERR_TUNNEL_CONNECTION_FAILED`, or a generic "connection was reset".

**Cause:** The server's egress policy refused the destination. Two independent checks can produce this:

1. **Port policy** — the destination port is not in the server's `SOCKS5_ALLOWED_PORTS` allowlist. Defaults block mail ports (25/465/587/143/993/110/995), RDP (3389), VNC (5900/5901), SMB (139/445), LDAP (389/636), and every database port (3306, 5432, 1433, 6379, 11211, 27017, 9200, 9300). If the destination is a legitimate service on a non-default port, the server operator must add that port.
2. **IP policy** — the destination resolved to a loopback, RFC 1918, link-local, CGNAT, or IPv6 ULA address. This is intentional SSRF protection; there is no client-side workaround.

**Fix:** This is not a client bug. Contact the server operator to adjust `SOCKS5_ALLOWED_PORTS` or `SOCKS5_BLOCK_PRIVATE_IPS` on the server.

### Docker Postgres / MySQL / Redis unreachable while VPN is up

**Symptom:** DBeaver shows `EOFException`, `psql` shows `ECONNREFUSED`,
`redis-cli` hangs. Stopping `vpn_client` fixes it. `tcpdump -ni tun0
'port 5432'` shows SYN → SYN‑ACK → FIN with **no payload**.

**Cause:** `docker-proxy` open a *second* connection from `127.0.0.1` to
the container's bridge IP. That second hop is captured by `0.0.0.0/1 dev
tun0`, forwarded to the server, and refused by `is_forbidden_ip` (RFC1918)
with `REP=0x02`. From the client's perspective the TCP handshake succeeds
(smoltcp on the client answers the SYN), the first payload byte
(PostgreSQL `SSLRequest`) is ACKed, and then a 0‑byte FIN arrives — this
is what `EOFException` in Java and `EOF on socket` in libpq actually mean.

**Diagnose:**

```bash
# Linux — which bridge is the container on?
docker network inspect <network> --format '{{range .IPAM.Config}}{{.Subnet}}{{end}}'
ip -br link show type bridge

# The route docker-proxy actually takes
sudo ip route get <container-ip>      # ← "dev tun0" = bug confirmed

# Reproduce without DBeaver
curl --socks5 127.0.0.1:18080 -sv telnet://<container-ip>:5432
# "SOCKS5 reply: 05 02"  ← server-side policy reject
```

```powershell
# Windows — Docker Desktop: the second hop lives inside WSL2, not the host FIB.
Get-NetRoute -DestinationPrefix "10.0.0.0/8"  # host has no route to the container
# ⇒ 127.0.0.1:5432 from the host is forwarded into the VM before any
#    host routing exists; no bypass route is needed or possible.
```

**Fix:**

```bash
# Linux: bypass the bridge CIDR
sudo VPN_BYPASS_CIDRS=<bridge-cidr>=<bridge-iface> -E ./vpn_client
```

```powershell
# Windows (native containers): same syntax; the alias is the vEthernet name
$env:VPN_BYPASS_CIDRS = "<bridge-cidr>=vEthernet (nat)"
```

**Alternative — eliminate the second hop entirely:**

```yaml
services:
  postgres:
    network_mode: host          # no docker-proxy, no bridge, no second hop
    # ports: "127.0.0.1:5432:5432"   ← remove
```

With host networking, DBeaver → `127.0.0.1:5432` → Postgres directly. No
route, no bypass, works with the VPN up or down.

### Windows — "route already exists" or firewall rule not installed

**Cause:** a previous `vpn_client.exe` was terminated without an
opportunity to run `Drop` (Task Manager End Task, `Stop-Process -Force`,
crash). The kill‑switch rules `proxy-iroh-block-out` and
`proxy-iroh-allow-exe`, plus the split‑default and bypass routes, are
still present.

**Fix:**

```powershell
# Firewall rules
netsh advfirewall firewall delete rule name="proxy-iroh-block-out"
netsh advfirewall firewall delete rule name="proxy-iroh-allow-exe"

# Routes installed by the VPN (safe to run even if some are absent)
route delete 0.0.0.0   mask 128.0.0.0
route delete 128.0.0.0 mask 128.0.0.0

# Inspect the table
Get-NetRoute | Where-Object { $_.DestinationPrefix -like "*0.0.0.0/1*" -or $_.DestinationPrefix -like "*128.0.0.0/1*" }
```

A clean restart of `vpn_client.exe` runs `Drop` on exit and cleans any of
these it recognises from a previous run. The manual commands are only
needed after a hard kill.

### WebTransport / QUIC Timeout
If you see `net::ERR_QUIC_PROTOCOL_ERROR.QUIC_NETWORK_IDLE_TIMEOUT`:
- **Cause:** Either (a) a 1250-byte QUIC Initial packet exceeded Iroh's per-datagram limit before V2 fragmentation was implemented, or (b) the server's `IROH_READ_KILL_SECS` watchdog fired on a WebTransport session that had completed its handshake and was legitimately idle.
- **Fix:** Ensure both client and server are running the latest version of `proxy-iroh` (`MAX_CHUNK = 900` fragmentation). If the error persists on **first navigation only**, it indicates a genuine datagram stall — check the server logs.

### `ERR_SSL_PROTOCOL_ERROR` in Browser
If pages load partially or fail TLS handshakes when using TUN mode:
- **Cause:** The TUN MTU is set too low. When the server sends a 1350-byte QUIC response, `tun2socks` wraps it in a 1428-byte IP packet. If the TUN MTU is 1280, the OS drops it.
- **Fix:** Verify `TUN_MTU` is set to `1500` in both `vpn_client.rs` and `QueueDevice::new()` in `tun2socks.rs`.

### DNS Resolution Fails in VPN Mode

**Cause:** DNS is tunneled by default — routing captures every UDP and TCP flow, including the ones a host resolver makes to its upstream. Resolution only succeeds when the client's resolver has a path to a DNS server that the server's port policy allows. Two configurations work; two do not.

**Configurations that work:**

| Host resolver | DoT upstream | Server ports |
|---|---|---|
| `systemd-resolved` with `+DNSOverTLS` | Cloudflare `1.1.1.1:853` (or any DoT provider) | `853` in `SOCKS5_ALLOWED_PORTS` |
| `systemd-resolved` with plain DNS | Any resolver reachable on `:53` | `53` in `SOCKS5_ALLOWED_PORTS` |

The default server allowlist since 0.5.2 includes `853`, which covers the common Linux case where `systemd-resolved` is already configured for Cloudflare DoT. No client configuration is required.

**Configurations that fail:**

- **Host resolver uses DoT but server does not allow `853`.** The `systemd-resolved` DoT dial to `1.1.1.1:853` is captured by the tunnel, refused by the server's port policy with `REP = 0x02`, and the resolver times out after ~5 s. Every `getaddrinfo` call on the host returns `SERVFAIL`. `dig` reports `communications error to 127.0.0.53#53: timed out`.
- **`VPN_MANAGE_DNS=true` on the client** with no server-side DNS handler. The client rewrites `/etc/resolv.conf` to point at `10.0.0.1`, but the server does not listen there. `dig` fails immediately with a timeout. This setting exists for a future server implementation and should not be enabled until that handler ships.

**Diagnose:**

```bash
# 1. Is the host resolver trying DoT?
resolvectl status | grep -E 'Protocols|DNS Servers'
# Expect:  +DNSOverTLS, DNS Servers: 1.1.1.1 ...

# 2. Is the DoT dial going through the tunnel?
sudo ss -tnp | grep ':853'
# Expect:  10.0.0.2:xxxxx → 1.1.1.1:853  (ESTAB or FIN-WAIT)

# 3. Does a lookup succeed?
dig +short smartholdem-block.duckdns.org
```

If step 2 shows `10.0.0.2` as source and step 3 times out, the DoT stream is entering the tunnel but being refused by the server.

**Fix:**

```bash
# On the server — add 853 to the allowlist and restart
SOCKS5_ALLOWED_PORTS=22,80,443,8080,8443,853 ./server
```

Verify server log shows the flow was accepted:

```
V2 CONNECT-UDP live ... -> 1.1.1.1:853
```

If instead you see `V2 CONNECT-UDP blocked: 1.1.1.1:853 (port not in allowlist)`, the port is not yet in the server's allowlist.

**If you cannot or will not expose `853` on the server:** re-exempt `systemd-resolved` from the tunnel by UID, accepting that DoT *handshakes* (though not their TLS-encrypted content) are visible to the ISP:

```bash
RESOLVE_UID=$(id -u systemd-resolve)
sudo ip rule add uidrange "$RESOLVE_UID-$RESOLVE_UID" lookup main priority 85
```

This restores the pre-0.5.2 behaviour where the host resolver bypassed the tunnel. Choose this only if you cannot add `853` to the server allowlist; otherwise the tunneled DoT path is both more private and simpler.

**Do not enable `VPN_MANAGE_DNS=true` unless the server has a DNS handler on `10.0.0.1:53`.** The current server does not. `false` — the default — is correct for every deployment today.

### "Cannot add rule … File exists" during startup
**Cause:** a previous `vpn_client` run did not shut down cleanly, and its routing rules or routes are still installed.

**Fix:** since the client tracks what it installed and rolls back on every path, this should only occur after a hard kill (SIGKILL, power loss). Clean up manually:

```bash
sudo ip rule del from <your-physical-ip> lookup main priority 90
sudo ip rule del lookup 1600000 priority 200
sudo ip route flush table 1600000
sudo ip -6 route del unreachable default metric 1
sudo iptables -D OUTPUT -m owner ! --uid-owner root -o <iface> -j REJECT
sudo iptables -D FORWARD -i tun0 -o <iface> -j ACCEPT
```

Then restart. The client's `Drop` handler will not try to remove these (it only reverts what its own `install` succeeded in creating), so a manual cleanup is always safe.

---

## Client Requirements
If you are building a custom client, it must satisfy the following to communicate with a `proxy-iroh` server:
1. **ALPN:** Connect to the server using `socks5/1`.
2. **Handshake:** Implement the ChaCha20-Poly1305 `Hello`/`Welcome` handshake using the shared `ProxySecret`.
3. **V2 Datagram Support:** Implement the `S5T2` framing (refer to the Server `README.md` for the fragment header layout) to support UDP and WebTransport.
4. **MTU:** Ensure local TUN devices are configured with an MTU of at least 1500 to prevent silent packet drops.
5. **Bootstrap before capture:** Resolve the relay and verify end-to-end transport *before* installing any routing or firewall rule. A partially-configured VPN is worse than a cleanly failed one.
6. **Source-address transport exemption:** Exempt the transport from the tunnel by source address of the physical interface IP, not by UID. UID-wide exemptions — including root — are fail-open and must not be used.
7. **Policy handling:** Treat SOCKS5 `REP = 0x02` (or the V2 equivalent) as a deterministic refusal. Do not retry with backoff — the server will refuse every attempt. Surface the error to the user, or in TUN mode let the destination TCP/UDP flow fail naturally so the application-level retry logic handles it.
8. **Local CIDR bypass:** When tunnelling local‑only destinations
   (`docker -p 127.0.0.1:port:port`, VM gateways, loopback‑adjacent
   subnets), install a more‑specific route to the owning interface
   before the split‑defaults. Client‑side only; do not relax server
   policy to compensate.
9. **Windows parity:** the kill switch must be scoped by process path
   (`program="<exe>"`), not UID, and must be installed *after* the
   Windows firewall stack is confirmed to accept netsh advfirewall
   rules. Reserve `wintun.dll` resolution as a hard dependency at
   startup — refusing to start on a missing DLL is friendlier than
   silently failing during the first `tun::create_as_async`.

## License
See repository's `LICENSE` file.
