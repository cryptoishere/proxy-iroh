# Authentication Modes

Ordered simplest → most advanced. Each mode lists its trust assumptions, handshake shape, and security properties.

## Trust model

The server and hub both hold a **master secret `M`**. From `M`, `derive_system(M)` yields one shared key; `derive_client(M, addr)` yields per-address keys. A client is provisioned with only its own `derive_client(M, addr)`.

Consequences for every HMAC mode below:

- Client-to-client impersonation: **impossible** (B cannot derive A's keys).
- Server-to-client impersonation: **possible** (server holds `M`).
- Hub compromise = server compromise (same `M`).
- On-chain verification bounds what `M` compromise can reach, but does not prevent server impersonation.

---

## Startup validation

The server refuses to start with combinations that cannot work end-to-end:

| Tunnel | Signature | Result |
|---|---|---|
| `false` | `false` | Mode 1 or Mode 2 (`SOCKS5_AUTH_REQUIRED` decides) |
| `false` | `true` | **refused** — plaintext signature transport would expose credentials |
| `true` | `false` | **refused** — tunnel Hello cannot be verified without a signature configuration |
| `true` | `true` | Mode 3, 4, or 5 (`client_type` decides) |

Both refusals are deliberate. `SOCKS5_TUNNEL_ENCRYPTION=true` and `SOCKS5_SIGNATURE_AUTH=true` are inseparable: the tunnel handshake exists to verify the Hello HMAC, and the HMAC requires a signature configuration to exist. Enabling one without the other produces a server that appears configured but cannot serve a working client.

---

## Mode 1 — Plaintext NO-AUTH

```bash
SOCKS5_TUNNEL_ENCRYPTION=false
SOCKS5_SIGNATURE_AUTH=false
SOCKS5_AUTH_REQUIRED=false
```

Plaintext SOCKS5, no credentials. Anyone who reaches `LISTEN_ADDR` is proxied, subject only to rate/quota/port/IP policy.

**Use:** loopback testing only. **Never:** internet-facing.

---

## Mode 2 — Plaintext RFC 1929

```bash
SOCKS5_TUNNEL_ENCRYPTION=false
SOCKS5_SIGNATURE_AUTH=false
SOCKS5_AUTH_REQUIRED=true
SOCKS5_USERS=alice:secret
```

**The password is sent in the clear.** Transport is plaintext end-to-end.

**Use:** loopback, or behind an already-encrypted layer (WireGuard, SSH tunnel). **Never:** open internet — the password is trivially sniffed.

---

## Mode 3 — Tunnel HMAC, SYSTEM

```bash
SOCKS5_TUNNEL_ENCRYPTION=true
SOCKS5_SIGNATURE_AUTH=true
# SOCKS5_AUTH_REQUIRED and SOCKS5_USERS are ignored in this mode
```

Client sends `sig_type = SYSTEM_TYPE (0x00)`. Hello tag = `HMAC(derive_system(M), …)`. Server recomputes and compares. Welcome follows, then ChaCha20-Poly1305 frames, then NO-AUTH SOCKS5 inside.

`strict_signature_only` closes any non-Hello first byte, eliminating the plaintext fallback entirely.

| Against | Status |
|---|---|
| Passive observer | ✓ encrypted |
| MITM | ✓ HMAC + integrity |
| Unauthorized use | ✓ only `M` holders |
| Plaintext fallback | ✓ none |
| Per-client identity | ✗ one shared credential |
| Revocation | ✗ needs key rotation |
| `M` compromise | ✗ total |

**Use:** single-operator deployments, trusted shared secret.

**Client requirement:** `client_type: SYSTEM_TYPE`. The default `CLIENT_TYPE` produces an HMAC mismatch.

---

## Mode 4 — Tunnel HMAC, CLIENT

```bash
SOCKS5_TUNNEL_ENCRYPTION=true
SOCKS5_SIGNATURE_AUTH=true
```

Client sends `sig_type = CLIENT_TYPE (0x01)` plus its wallet address. Hello tag = `HMAC(derive_client(M, addr), …)`. Server derives the same keys from `M + addr` and verifies.

**Why this works:** the server does not need to know the client's secret in advance — it recomputes it from the master. A match proves the client holds `derive_client(M, addr)`, not merely `M`. Client B cannot forge A's HMAC because B lacks A's derivation.

| Against | Status |
|---|---|
| Client→client impersonation | ✓ blocked |
| Per-client identity | ✓ |
| Revocation | ✗ permanent once provisioned |
| `M` compromise | ✗ can derive any client |
| Server→client impersonation | ✗ unchanged |

**Use:** multi-client deployments, baseline for a proxy service.

**Not solved:** revocation. Rotating a single client's access requires rotating `M` for everyone.

---

## Mode 5 — Tunnel HMAC, CLIENT + on-chain check (planned)

```bash
SOCKS5_TUNNEL_ENCRYPTION=true
SOCKS5_SIGNATURE_AUTH=true
CENTRAL_ENDPOINT_SNI=<hub>
CENTRAL_ENDPOINT_SNI_PORT=<port>
```

Handshake identical to Mode 4 up through HMAC verification. Then before sending the Welcome, the server queries the hub via the `ProxyFrameMetadata`/`ProxyCallerResponse` exchange: **"is `addr` on chain and not revoked?"** Only `true` allows Welcome. Any error closes the connection (fail-closed).

**Adds to Mode 4:**

| Property | Status |
|---|---|
| Revocation without key rotation | ✓ |
| Bounds `M` compromise to on-chain addresses | ✓ |
| Per-address audit trail | ✓ |
| Server→client impersonation | ✗ unchanged |
| Hub-side forgery | ✗ hub holds `M` |
| Replay of a captured Hello within 60 s window | ✗ unchanged |

**Use:** any deployment needing revocation, or any internet-facing service with more than a handful of clients. Recommended production mode once shipped.

**Future consideration:** end-to-end unforgeability against the server requires clients to sign the Hello with a wallet private key instead of a shared-secret derivation. That is a wire-format change, not currently planned.

---

## Configuration matrix

| Env var | M1 | M2 | M3 | M4 | M5 |
|---|---|---|---|---|---|
| `SOCKS5_TUNNEL_ENCRYPTION` | false | false | **true** | **true** | **true** |
| `SOCKS5_SIGNATURE_AUTH` | false | false | **true** | **true** | **true** |
| `SOCKS5_AUTH_REQUIRED` | false | **true** | ignored | ignored | ignored |
| `SOCKS5_USERS` | — | **set** | ignored | ignored | ignored |
| `CENTRAL_ENDPOINT_SNI` | — | — | — | — | **required** |
| Client `client_type` | n/a | n/a | `0x00` | `0x01` | `0x01` |

`ignored` means the variable has no effect and should be removed from the env to avoid implying a layer that isn't there.

---

## Selecting a mode

```
Internet-facing?
├─ No  → Mode 1 (loopback) or Mode 2 (private network with existing encryption)
└─ Yes
    ├─ Single shared credential OK?        → Mode 3
    └─ Per-client identity needed
        ├─ Revocation not required          → Mode 4
        └─ Revocation required (recommended) → Mode 5
```

---

## Summary

| Mode | Encrypted | Per-client ID | Revocation | Hub | Operational |
|---|---|---|---|---|---|
| 1 | ✗ | ✗ | ✗ | no | ✓ |
| 2 | ✗ | password only | change password | no | ✓ |
| 3 | ✓ | ✗ | ✗ | no | ✓ |
| 4 | ✓ | ✓ | ✗ | no | ✓ |
| 5 | ✓ | ✓ | ✓ | **yes** | planned |

Useful progression: **1 → 2 → 3 → 4 → 5**. Any internet-facing deployment should be at Mode 3 or above; Mode 5 is the target once available.
