# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [0.5.1] - 2026-11-05

### Fixed

- **Server never closed Connections for dead clients.** The server's own keepalive interval was below its idle timeout, so each PING it sent restarted its own idle timer. The idle timeout never fired and every Connection the server had ever accepted stayed open, holding around four file descriptors each. After a few hours of browser traffic, roughly 240 zombie Connections accumulated and hit the default file descriptor limit, producing `Too many open files` on socket pair creation. The server keepalive interval is now above the idle timeout. The client still sends keepalives every two seconds — that is the direction that keeps SSH and WebTransport sessions alive, and it is unchanged. When a client dies, its PINGs stop and the server's idle timer runs to completion.
- **Socket pair file descriptors leaked when a Connection closed abruptly.** The shutdown that should have closed the socket pair write side was gated behind a success check, so on transport errors it never ran and both descriptors were held until process exit. The shutdown is now issued unconditionally.
- **The relay idle timeout was only observed while the relay was still generating events.** Once both sockets in a relay had nothing left to write, the event loop stopped firing for it, so the deadline was never re-checked and the relay and its descriptors stayed in the table indefinitely. The main loop now sweeps every relay each poll cycle rather than waiting for events. The timeout value and the condition are unchanged.
- **Two failure paths in the stream-accept loop exited without notifying the event loop.** Socket pair creation failure and hand-off failure both returned early, bypassing the cleanup notification, so the bridge's descriptors stayed open until process exit. Both now fall through to the same cleanup used by every other exit path.
- **The stream-accept loop could block forever after an abnormal Connection close.** It only exited on a clean end-of-stream, which does not always arrive. It is now also gated on the per-Connection cancellation handle.
- **The server TUI did not refresh after first-run registration.** The wallet address and key fingerprint in the Identity panel were captured at startup, before the account was provisioned. Both are now re-read after successful registration and reflected immediately on first launch.

### Added

- **`CONN_HARD_IDLE_SECS` (default 300 seconds).** Per-Connection watchdog. Force-closes any Connection with no application traffic for five minutes, regardless of whether the transport layer ever reports the close.
- **`RELAY_IDLE_SECS` (default 60 seconds).** Per-relay idle timeout. A relay whose one side has closed but whose peer never sent FIN is torn down after the timeout.
- **Per-transport traffic counters.** Traffic statistics are now split into TCP and UDP, both for upload and download.

### Changed

- **Connection cleanup is structural.** The watchdog, datagram reader, datagram writer, and stream-accept loop for a Connection share one cancellation handle. Whichever of them detects termination first cancels the rest, and the four descriptors attached to the Connection are released on every termination path — clean close, watchdog, transport error, or sibling cancel.
- **Server TUI shows TCP, UDP, and Total rows separately** in the Traffic panel.
- **Server counts UDP bytes.** V2 CONNECT-UDP payloads are now included in the traffic totals, in both bridge directions.
- **The byte pump gained a per-Connection activity clock parameter**, used by the hard idle watchdog.

### Deployment note

- **Raise the process file descriptor limit to 65536** (systemd `LimitNOFILE` or `ulimit -n`). The fixes above eliminate the FD leaks, but the default of 1024 is still insufficient headroom for a proxy under normal browser load. Without it, transient `EMFILE` errors can occur during a burst even in the absence of a leak.

## [0.5.0] - 2026-11-01

This is the initial release of `proxy-iroh`, building upon the foundation of the original `socks5-tunnel` project. It introduces system-wide VPN capabilities, full UDP/QUIC/WebTransport support, cross-platform datagram bridging, and server-side egress controls.

### Added

- **`proxy-iroh` rebrand and restructure.** The project has been rebranded and restructured to reflect its expanded scope beyond a standard SOCKS5 proxy.
- **TUN/VPN integration.** `vpn_client.rs` and `tun2socks.rs` provide userspace system-wide routing. Traffic is intercepted via a TUN device, terminated via `smoltcp`, and transparently proxied over Iroh.
- **V2 CONNECT-UDP protocol.** Custom `S5T2` extension for tunneling raw UDP packets. Enables full WebTransport, HTTP/3, and QUIC support through the encrypted Iroh bridge.
- **Datagram fragmentation and reassembly.** Robust reassembly engine chunking at 900 bytes, bypassing Iroh's ~1150-byte datagram limit and preventing silent drops of 1250-byte QUIC Initial packets.
- **Cross-platform bridge.** Unified `lib/bridge.rs` supporting both Unix (`AF_UNIX` socket pairs) and Windows (loopback TCP/UDP pairs) for stream and datagram forwarding.
- **HTTP CONNECT translation.** The client translates HTTP/1.1 `CONNECT` requests into SOCKS5, improving compatibility with browser proxy settings.
- **Server port allowlist** (`SOCKS5_ALLOWED_PORTS`, default `22,80,443,8080,8443`). Default-deny egress on V1 CONNECT, V2 CONNECT, and V2 CONNECT-UDP. Supports ranges (`1-1024`), `*`, and empty string. Fails closed on parse error. Blocked destinations get SOCKS5 `REP = 0x02`. Blocks SMTP/IMAP/POP3/FTP/Telnet/RDP/VNC/SMB/LDAP and every database port (MySQL, PostgreSQL, MSSQL, Redis, Memcached, MongoDB, Elasticsearch) by default.
- **Server SSRF guard** (`SOCKS5_BLOCK_PRIVATE_IPS`, default `on`). After DNS resolution, refuses loopback, RFC 1918, link-local, CGNAT, IPv6 ULA, and unspecified destinations — including cloud metadata (`169.254.169.254`).
- **Server backpressure queues** (`pending_bridge_frames`, `pending_dest_frames`). Bounded FIFO queues (1 MiB cap) drained every `POLL_TIMEOUT` so kernel-buffer pressure does not drop fragments mid-WebTransport handshake.
- **Client backpressure queue** (`pending_iroh_fragments`). Fragments that hit `SendDatagramFull` are queued with their siblings (so reassembly stays coherent) and retried on the next tick / next Remote event.
- **Retry loop in server's bridge → iroh task.** On `send_datagram` failure, retries every 2 ms for up to 5 s or until connection close, instead of dropping the datagram.
- **Per-connection datagram reader cancellation token (client).** Cleanly cancels the reader when the bidi pump exits or an error path closes the socketpair.

### Security

- **Port allowlist and SSRF guard close two significant abuse vectors:** using the exit node as a jump host for mail relay, credential stuffing, RDP/VNC/SMB lateral movement, and database scanning; and reaching internal infrastructure or cloud metadata via SSRF. Default-deny on both.
- **Out of scope (future work):** DNS exfiltration via the DoT resolver. Intended for `lib::dns`; noted in `README.md` under *Security Model → Out of scope*.

[Unreleased]: https://github.com/cryptoishere/proxy-iroh/compare/v0.5.1...HEAD
[0.5.1]: https://github.com/cryptoishere/proxy-iroh/compare/v0.5.0...v0.5.1
[0.5.0]: https://github.com/cryptoishere/proxy-iroh/releases/tag/v0.5.0