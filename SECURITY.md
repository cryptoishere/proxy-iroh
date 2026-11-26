# Security model — dual-signed bandwidth attestation

Server and client independently report per-session byte counts to the central hub.
The hub credits `min(server, client)`, so one-sided inflation is self-defeating:
whichever party lied wins the lower number for both.

## The economic premise

The server wants to inflate reported bytes (to earn more). The client wants to
deflate reported bytes (to pay less). `min()` breaks both. What breaks `min()` is
collusion — both parties agreeing to a lie. No cryptographic mechanism observable
by the hub can distinguish "both parties honestly report X" from "both parties
agree to lie about X". That limit is fundamental and is why the rest of the design
is external evidence, not cryptography.

## What is achievable

1. **One-sided falsification is trivially detected.** `min(client, server)` bounds
   the credit. Whichever party lied gets the lower number.
2. **Collusion is detectable probabilistically** through external evidence
   (synthetic sampling, cohort analysis, relay byte counts).
3. **The client's report cannot be silently dropped by the server.** Delivery is
   TLS-protected and cert-pinned through the tunnel; the server's reward is
   conditional on the hub receiving it.

## The tunnel-only constraint

The client must not interact directly with the hub while the VPN is active. The
only permitted channel for bandwidth attestation is through the VPN tunnel to the
hub's HTTPS API. The client reaches it by `CONNECT hub.example.com:443` through
its own SOCKS5 listener. The server sees only opaque TLS bytes to an ordinary
hostname. The client pins the hub's certificate (or validates it against a CA the
server does not control), so a `CONNECT` redirection to a server-owned endpoint
fails the TLS handshake.

## Three signed artifacts per session

| Artifact | Signed by | Sent to | Transport |
|---|---|---|---|
| `SessionOpen` | server (Iroh `EndpointId`) | hub | `proxy/svc/0`, before `Welcome` |
| `ServerReport` | server (Iroh `EndpointId`) | hub | `proxy/svc/0`, at relay teardown |
| `ClientAttestation` | client (`derive_client(M, addr)`) | hub | HTTPS through the tunnel |

The hub credits only when it holds all three for the same `session_id`.

## Why the tunnel-only transport does not weaken the design

The server physically handles the client's TCP connection to the hub — it does the
`CONNECT`. It can attempt:

| Attack | Why it fails |
|---|---|
| MITM the TLS to read or modify the attestation | Client pins the hub's cert; handshake fails. |
| Redirect `CONNECT` to its own HTTPS server | Same — cert mismatch. |
| Serve a cached `200 OK` from a prior attestation | The client's HMAC covers the new `nonce` and `at`. A replayed reply has the wrong nonce; the client detects and retries. |
| Drop the `CONNECT` entirely | Client sees failure. `ServerReport` files without a matching attestation. Hub credits zero. The server's only way to be paid is to forward. |

Dropping the client's `CONNECT` is economically self-defeating. That is the
enforcement mechanism the tunnel-only constraint requires.

## Economic equilibrium

| Client reports | Server reports | Hub credits | Outcome |
|---|---|---|---|
| Truth | Truth | Truth | Both paid fairly |
| Truth | Inflated | Client's lower | Server over-reported, no gain; flag raised |
| Inflated | Truth | Server's lower | Client over-paid, no gain; flag raised |
| Under-reported | Under-reported | Lower figure | Server earns less than actual; self-defeating |
| Inflated | Inflated (collusion) | Inflated | **Undetectable from reports alone** → sampling, cohort, relay |

The first four rows are the equilibrium: **honesty is a dominant strategy** for
both parties when collusion is excluded. The fifth row is what external evidence
is for.

## Tokenomics (server-side rewards for data transmission)

> "Smartoshi" — the base unit of measurement. STH — the coin ticker.

Price per data upload (sending): 0.00000001 STH
Price per data download (receiving): 0.00000001 STH

1 byte of data sent = upload price
1 byte of data received = download price

Hub commission (deducted from the total server reward): 60%

## Credit formula

```
credited = min(server, client) × path_discount × cohort_factor
```

- `path_discount` = 0.2 for sessions established via a relay, and 1.0 for direct sessions. This coefficient reflects the fact that a direct connection offers lower latency, whereas using a relay—as a fallback option—is less desirable.
- `cohort_factor` = `min(1, cohort_p99_throughput × duration × 2 / credited)`,
  catching impossibly-high claims against peer servers.

## External evidence for collusion

None of these can cryptographically prove collusion, but each raises the cost:

1. **Synthetic clients** (hub → server). The hub provisions a fresh
   `derive_client(M, addr_hub_test_n)` and drives known bytes through the server.
   The server reports the session without knowing it was hub-originated. The hub
   compares.
2. **Cohort comparison.** Servers grouped by `(link_class, region)`. A server whose
   median per-session bytes exceed the cohort's p99 by 3× is capped.

## What no design can prevent

- **Hub compromise.** The hub holds `M`, signs `SessionOpen`, controls sampling,
  and controls the ledger. There is no external authority to appeal to.
- **Client, server, and relay collusion.** Requires all three parties aligned
  against the hub. The relay is hub-controlled, so this implies hub compromise.
- **A server that behaves honestly during hub sampling and inflates only for
  colluding clients**, with volume kept below cohort thresholds. Detectable
  eventually via drift analysis but not preventable.

These are properties of the trust model, not of the implementation. Documenting
them prevents the illusion that the hub is *proving* bandwidth rather than
*bounding* it.

## References

- [README.md](README.md) — server features and configuration
- [SERVER.modes.md](SERVER.modes.md) — authentication modes and trust assumptions
