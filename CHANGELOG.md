# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [0.7.0] - 2026-11-22

Dual-signed attestation. Server and client now independently report per-session
byte counts to the central hub; the hub credits `min(server, client)`, so one-sided
inflation is self-defeating. See [SECURITY.md](SECURITY.md) for the economic model
and its limits.

### Added

- **`SessionOpen` message** on ALPN `proxy/svc/0` — the server records the
  client-chosen `session_id` at the hub before sending `Welcome`. The hub rejects
  any `ServerReport` for a session it never saw open.
- **`ServerReport` message** on ALPN `proxy/svc/0` — sent at relay teardown with
  byte counts, `started_at`/`ended_at`, `path_type`, and a per-server monotonic
  `nonce`. Replayed or out-of-window reports are rejected.
- **`ClientAttestation` HTTPS endpoint** `/api/v1/bandwidth/attest` — the client
  posts cumulative byte counts to the hub through its own SOCKS5 tunnel. The
  server can drop the traffic (zero credit for itself) but cannot read, modify, or
  forge the payload (client HMAC + TLS).
- **Wire format v4** — the tunnel `Hello` now carries a 16-byte client-chosen
  `session_id` between `sig_type` and `addr_len`, covered by the HMAC.
  `MAGIC_HELLO` bumped to `S5-TUNNEL-v4`, `HELLO_FIXED_LEN` from 74 to 90.
- **`PathType` (`Direct` / `Relay`) plumbing** — captured from the iroh
  `Connection` at accept and reported per session. The hub discounts direct-path
  sessions relative to relay-verified ones.
- **Separate client attestation listener** (`127.0.0.1:1081` by default) — avoids
  a loop where attestation traffic is re-captured by the TUN adapter.

### Changed

- **ALPN `proxy/svc/0` wire is now discriminator-prefixed.** Every frame is
  `[u32 len][u8 msg_type][postcard payload]`, where `msg_type` is `0x01` (verify),
  `0x02` (`SessionOpen`), or `0x03` (`ServerReport`). This is wire-breaking:
  server and hub must be deployed together.
- **`SessionOpen` is a precondition for `Welcome`** on `CLIENT_TYPE` handshakes.
  On-chain verification and session registration run sequentially on the iroh
  runtime; exactly one result reaches the mio loop. A hub rejection closes the
  connection before the `Welcome` is sent. Fail-closed.
- **`ClientAttestation` carries the client's real `session_id`.** The hub can now
  key `ServerReport` and `ClientAttestation` under the same id, which is what makes
  `min()` computable.

### Fixed

- Fixed central hub transport frame decoding and message-type handling.
- Unified inbound frame parsing for client verification, session registration, and
  server reporting.
- Fixed Postcard serialization mismatch between the proxy server and central hub.
- Corrected verification message framing to use the shared length-prefixed
  protocol.
- Fixed response handling for session registration and server reporting.
- Fixed panic on relay teardown when `tokio::spawn` was called from the mio main
  thread (no reactor context); now uses `rt_handle.spawn`.

## [0.6.2] - 2026-11-17

On-chain client address verification is deferred to a future release. The work below is independent of that feature and ships first so the file-descriptor lifecycle can be validated in production without the on-chain check in the critical path.

### Added

- **Windows service mode.** With `cargo build --release --features daemonize` (or the pre-built release that ships with the feature enabled), the binary accepts three additional subcommands:
  - `server install` — registers the binary with the Service Control Manager as `proxy-iroh`, `AutoStart`, running as `LocalSystem`.
  - `server uninstall` — removes the service registration.
  - `server service` — invoked by SCM at boot; runs the server with no console and no TUI, reporting status transitions to SCM.
  
  Installation and uninstallation require an elevated prompt. `sc start proxy-iroh` / `sc stop proxy-iroh` control the service lifecycle. Logs are written to the service account's `%LOCALAPPDATA%\CiGPeerApp\server_app.log` (`C:\Windows\System32\config\systemprofile\AppData\Local\CiGPeerApp` for `LocalSystem`).
- **`background` subcommand on Windows.** Re-execs the binary detached, with no console and no TUI, surviving the parent prompt. Prints the child PID; stop with `taskkill`. Complements the interactive and service modes.
- **`daemonize` cargo feature.** Gates the `windows-service` dependency and the service module. Builds without the feature compile on all platforms and refuse the three service subcommands with a clear error; `background` remains available.
- **`ShutdownHandle`.** A single shared shutdown primitive driven by Ctrl-C (interactive), SCM stop (service), or the TUI quit key. Preserves the existing double-signal force-exit behaviour: first trigger drains connections, second calls `std::process::exit(1)`.
- **`RELAY_HARD_IDLE_SECS` (default `600`).** Per-relay ceiling for relays whose client and destination are both still open. `RELAY_IDLE_SECS` (60 s) continues to govern half-closed relays. The hard timeout covers the case that was previously unbounded: a background client keeping the QUIC Connection alive via keepalives, with browser-side connections the destination never FINed — the relay saw no traffic, neither close flag was set, and the timeout never fired. On a long-lived client this accumulated one relay per abandoned browser tab over a full day.

### Changed

- **`pump_bi` accepts a cancellation token.** The pump now selects each direction against the token, so cancellation from any sibling task propagates within one poll cycle. Previously the pump waited only on the iroh stream futures; when a QUIC Connection closed without the stream futures erroring promptly (a known edge case when the peer resets without a stream-level frame), the pump kept the tokio half of the socketpair open, the mio side never saw EOF, and the relay's FDs stayed pinned.
- **All per-Connection cancellation sites re-enabled.** Five sites in the per-Connection task — `accept_bi()` error, socketpair error, mio handoff error, bridge-to-iroh error, and end-of-task cleanup — were commented out during earlier debugging and never restored. Their surrounding comments still described the intended behaviour; the code did not perform it. With the pump now honoring the token, these calls are the mechanism by which internal errors cascade to the pump.
- **Startup validation.** The server refuses to start with `SOCKS5_TUNNEL_ENCRYPTION=true` and `SOCKS5_SIGNATURE_AUTH=false`. That combination cannot serve a working tunnel client — the Hello cannot be verified because `signature_config` is `None` — and would silently fall back to the plaintext SOCKS5 path, contradicting the operator's intent in setting the tunnel flag. The mirror check (`signature=true`, `tunnel=false`) already existed and is unchanged.
- **`Relay` cipher state is now optional.** `Encryptor` and `Decryptor` are wrapped in `Option`, matching the reality that in plaintext modes there is no tunnel to encrypt or decrypt. The relay behaves as a transparent byte pipe when both are `None`, and as a framed relay when both are `Some`. The invariant "tunnel enabled implies cipher present" is enforced by the startup check and the `TunnelWelcome` transition that installs the cipher before `Responding` is reachable, not by a runtime assert.
- **`CONN_HARD_IDLE_SECS` (default `300`) documented** in the README configuration table. The watchdog that fires on this timer is what drives `conn_ctoken` cancellation for a Connection whose transport has gone silent; without the pump honoring the token (above), the watchdog had no effect on pinned FDs.

### Fixed

- **Pump's error-path socketpair shutdown was a no-op.** The shutdown call constructed the async future and dropped it without polling, so the write side never closed on the error path and the relay's half-close cascade stalled. Shutdown now runs unconditionally after the copy future returns, on both success and error.
- **Per-relay FDs accumulated for the lifetime of a background client.** Relays with both sides open and no traffic were never timed out, because the timeout required one side to be closed before checking activity. A client left running kept every Connection alive with its keepalive, so the Connection never closed and each abandoned browser-tab relay persisted indefinitely — reaching ~700 FDs over a day. `RELAY_HARD_IDLE_SECS` closes this case.
- **Plaintext authentication modes panicked at the relay transition.** Modes 1 and 2 (`SOCKS5_TUNNEL_ENCRYPTION=false`) reached `finish_into_relay` with `encryptor` and `decryptor` both `None`, where the relay transition asserted a tunnel was active and terminated the process with `PANIC!`. The assert was correct for its original assumption — that the relay transition only occurs on the tunnel path — but that assumption has been false since plaintext modes were added at the handshake level. With the `Relay` change above, plaintext handshakes now complete their relay with pass-through semantics: bytes read from the client are forwarded to the remote unchanged, and bytes read from the remote are forwarded to the client unchanged. Tunnel modes are unaffected because `encryptor`/`decryptor` are still `Some` on that path, verified by the startup check and by `pending_switch` installation in the `TunnelWelcome` transition.

## [0.6.1] - 2026-11-16

### Added

- **On-chain client address verification.** When `SOCKS5_SIGNATURE_AUTH=true` and a client presents `sig_type = CLIENT_TYPE`, the server queries the central hub to confirm the client's wallet address is registered on chain and not revoked before sending the `Welcome`. Only a positive response (`client_address_on_chain: true`) allows the tunnel to proceed. Every other outcome — hub unreachable, malformed response, timeout, or a negative result — closes the connection **before** any tunnel bytes are exchanged. `SYSTEM_TYPE` handshakes bypass the check entirely and behave exactly as in 0.6.0.
- **Central Hub transport integration.** The server maintains a live Iroh connection to the central hub on ALPN `proxy/svc/0` for on-chain verification queries, alongside the client-facing endpoint on ALPN `socks5/1`. The hub connection is lazily re-established on demand, so a hub restart does not require a server restart.
- **`CENTRAL_ENDPOINT_SNI` / `CENTRAL_ENDPOINT_SNI_PORT`** — hub hostname and port used for initial registration and verification queries.
- **`TARGET_ENDPOINT_X1_CENTRAL_HUB_13`** — the central hub's Iroh `EndpointId`.
- **`ENDPOINT_BIND_ADDRESS_CENTRAL_HUB`** (default `0.0.0.0:44445`) — bind address for the hub-facing Iroh endpoint.
- **`CONN_HARD_IDLE_SECS`** (default `300`) surfaced in the README configuration table.

### Changed

- **Startup validation.** The server refuses to start with `SOCKS5_TUNNEL_ENCRYPTION=true` and `SOCKS5_SIGNATURE_AUTH=false`. That combination cannot serve a working tunnel client — the Hello cannot be verified because `signature_config` is `None` — and would silently fall back to the plaintext SOCKS5 path, contradicting the operator's intent in setting the tunnel flag. The mirror check (`signature=true`, `tunnel=false`) already existed and is unchanged.
- **`SECURITY MODEL` section rewritten** to describe the five accepted authentication modes (2 plaintext, 3 tunnel) and the trust model that underlies the HMAC modes.
- **`Client Support & Requirements`** updated: `CLIENT_TYPE` clients must be provisioned with `derive_client(M, address)` **and** be registered on chain with the central hub. The server will not accept their `Welcome` otherwise.
- **`Relay` cipher state is now optional.** `Encryptor` and `Decryptor` are wrapped in `Option`, matching the reality that in plaintext modes there is no tunnel to encrypt or decrypt. The relay behaves as a transparent byte pipe when both are `None`, and as a framed relay when both are `Some`. The invariant "tunnel enabled implies cipher present" is enforced by the startup check and the `TunnelWelcome` transition that installs the cipher before `Responding` is reachable, not by a runtime assert.

### Fixed

- **Server started successfully with a stale hub connection.** `init_connection_state` failures were logged but did not prevent the server from accepting `CLIENT_TYPE` handshakes that would later fail at the on-chain step with a generic I/O error. The server now logs the hub failure explicitly at startup (`starting tunnel with Central Hub failed`) and every subsequent on-chain check fails closed with a named cause in the per-connection log.
- **Plaintext authentication modes panicked at the relay transition.** Modes 1 and 2 (`SOCKS5_TUNNEL_ENCRYPTION=false`) reached `finish_into_relay` with `encryptor` and `decryptor` both `None`, where `encryptor.expect("tunnel must be active in relay")` terminated the process with `PANIC!`. The panic was correct for its original assumption — that the relay transition only occurs on the tunnel path — but that assumption has been false since plaintext modes were added at the handshake level. With the `Relay` change above, plaintext handshakes now complete their relay with pass-through semantics: bytes read from the client are forwarded to the remote unchanged, and bytes read from the remote are forwarded to the client unchanged. Tunnel modes are unaffected because `encryptor`/`decryptor` are still `Some` on that path, verified by the startup check and by `pending_switch` installation in the `TunnelWelcome` transition.

## [0.6.0] - 2026-11-10

### Changed (Breaking)

- **Tunnel Hello wire format.** The plaintext `Hello` message now carries a **signature type** byte (`0x00` = SYSTEM, `0x01` = CLIENT) immediately after the magic and before the address-length field. The value is covered by the HMAC, so the client's claimed identity is cryptographically bound to possession of the matching account's secret.
- **`MAGIC_HELLO` bumped** from `S5-TUNNEL-v1\x00\x00\x00\x00` to `S5-TUNNEL-v2\x00\x00\x00\x00`. Peers running different versions now fail the handshake with `bad magic` instead of misparsing the byte stream.

This is a **wire-incompatible change**. Server and client must be upgraded together. A 0.5.x client cannot connect to a 0.6.0 server, and a 0.6.0 client cannot connect to a 0.5.x server. The failure is immediate and explicit (`bad magic`), not silent data corruption.

## [0.5.2] - 2026-11-09

### Added

- **HMAC-derived key separation.** Introduced separate derived keys for HTTP authentication, tunnel authentication, and tunnel encryption, preventing the same shared secret from being reused directly across different cryptographic purposes.
- **Signature type identifiers.** Added internal signature type identifiers for system (`0x00`) and client (`0x01`) signatures.
- **Port `853` in the default `SOCKS5_ALLOWED_PORTS`.** Allows DNS-over-TLS through the tunnel. Without it, hosts configured for DoT — the common case on Linux with `systemd-resolved` — cannot resolve any names while the VPN is up: the DoT dial to `1.1.1.1:853` is captured by the client's tunnel, refused by the server's port policy, and there is no plaintext fallback. The server returns `REP = 0x02` and every `getaddrinfo` on the host fails with `SERVFAIL`.

### Changed

- **Signed RFC 1929 credentials.** Updated credential parsing and serialization to include the signature type identifier.
- **Server default `SOCKS5_ALLOWED_PORTS`** extended from `22,80,443,8080,8443` to `22,80,443,8080,8443,853`.

### Fixed

- **Tunnel Hello address-length validation.** Added client-side validation to reject empty addresses and addresses exceeding the protocol's 255-byte limit before encoding the length into a single byte. This prevents silent `u8` truncation and malformed handshake messages.
- **DNS resolution failed silently with no diagnostic when the server did not allow `853`.** The port refusal now surfaces in the server log as `V2 CONNECT blocked: ...:853 (port not in allowlist)`, and the client-visible symptom (`dig` timeouts against `127.0.0.53`, browser `ERR_NAME_NOT_RESOLVED`) is documented under *DNS Resolution Fails in VPN Mode* in `CLIENT.md`.

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
- **Server port allowlist** (`SOCKS5_ALLOWED_PORTS`, default `22,80,443,8080,8443,853`). Default-deny egress on V1 CONNECT, V2 CONNECT, and V2 CONNECT-UDP. Supports ranges (`1-1024`), `*`, and empty string. Fails closed on parse error. Blocked destinations get SOCKS5 `REP = 0x02`. Blocks SMTP/IMAP/POP3/FTP/Telnet/RDP/VNC/SMB/LDAP and every database port (MySQL, PostgreSQL, MSSQL, Redis, Memcached, MongoDB, Elasticsearch) by default.
- **Server SSRF guard** (`SOCKS5_BLOCK_PRIVATE_IPS`, default `on`). After DNS resolution, refuses loopback, RFC 1918, link-local, CGNAT, IPv6 ULA, and unspecified destinations — including cloud metadata (`169.254.169.254`).
- **Server backpressure queues** (`pending_bridge_frames`, `pending_dest_frames`). Bounded FIFO queues (1 MiB cap) drained every `POLL_TIMEOUT` so kernel-buffer pressure does not drop fragments mid-WebTransport handshake.
- **Client backpressure queue** (`pending_iroh_fragments`). Fragments that hit `SendDatagramFull` are queued with their siblings (so reassembly stays coherent) and retried on the next tick / next Remote event.
- **Retry loop in server's bridge → iroh task.** On `send_datagram` failure, retries every 2 ms for up to 5 s or until connection close, instead of dropping the datagram.
- **Per-connection datagram reader cancellation token (client).** Cleanly cancels the reader when the bidi pump exits or an error path closes the socketpair.

### Security

- **Port allowlist and SSRF guard close two significant abuse vectors:** using the exit node as a jump host for mail relay, credential stuffing, RDP/VNC/SMB lateral movement, and database scanning; and reaching internal infrastructure or cloud metadata via SSRF. Default-deny on both.
- **Out of scope (future work):** DNS exfiltration via the DoT resolver. Intended for `lib::dns`; noted in `README.md` under *Security Model → Out of scope*.

[Unreleased]: https://github.com/cryptoishere/proxy-iroh/compare/v0.6.2...HEAD
[0.6.3-rc.3]: https://github.com/cryptoishere/proxy-iroh/compare/v0.6.2...v0.6.3-rc.3
[0.6.3-rc.2]: https://github.com/cryptoishere/proxy-iroh/compare/v0.6.2...v0.6.3-rc.2
[0.6.3-rc.1]: https://github.com/cryptoishere/proxy-iroh/compare/v0.6.2...v0.6.3-rc.1
[0.6.2]: https://github.com/cryptoishere/proxy-iroh/compare/v0.6.1...v0.6.2
[0.6.1]: https://github.com/cryptoishere/proxy-iroh/compare/v0.6.0...v0.6.1
[0.6.0]: https://github.com/cryptoishere/proxy-iroh/compare/v0.5.2...v0.6.0
[0.5.2]: https://github.com/cryptoishere/proxy-iroh/compare/v0.5.1...v0.5.2
[0.5.1]: https://github.com/cryptoishere/proxy-iroh/compare/v0.5.0...v0.5.1
[0.5.0]: https://github.com/cryptoishere/proxy-iroh/releases/tag/v0.5.0