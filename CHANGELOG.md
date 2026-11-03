# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

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

[Unreleased]: https://github.com/cryptoishere/proxy-iroh/compare/v0.5.0...HEAD
[0.5.0]: https://github.com/cryptoishere/proxy-iroh/releases/tag/v0.5.0