# Hoodi self-hosted beaconcha.in `/api/v1` — Status

**Updated:** 2026-06-22 · **Host:** GS-Ext-bchain-a15-node-12 (128-core EPYC 7H12 / 2 TB RAM / 98 TB) · **Mode:** current-forward · **For:** stakepad dev team

---

## TL;DR

The self-hosted Hoodi `/api/v1` is **deployed and live**, replacing the paid hosted
beaconcha.in API. It runs in **current-forward mode** (indexes from a recent anchor forward,
not from genesis) and serves real Hoodi data.

The earlier **hardware-headroom problem is gone** — that was the old 8-core/31 GB VM. This
box (128 cores / 2 TB RAM) keeps the indexer caught up with the per-epoch ~1.42M-validator
workload comfortably (bounded sawtooth lag, ~1–23 slots). Full genesis history is
intentionally **deferred**: the Hoodi nodes here are non-archive (checkpoint-synced
Lighthouse + snap Geth), and current-forward was the agreed scope.

## Access

- **URL:** `http://38.29.227.105/` — HTTP basic auth, user **`stakepad`** (password shared separately)
- **API example:** `curl -u stakepad:<pass> http://38.29.227.105/api/v1/epoch/latest`
- **Health (no auth):** `http://38.29.227.105/api/healthz-loadbalancer`
- Note: basic auth is over plain HTTP (base64, not encrypted) — fine for a testnet API; TLS can be added on request.

## What works (verified 2026-06-22)

- `/api/v1/epoch/latest`, `/api/v1/epoch/{n}` — ✅ real data (~1.17M active validators of ~1.42M total)
- `/api/v1/slot/{n}` — ✅ real proposer + attestation data
- `/api/v1/validator/{i}` — ✅ **~20 ms** (was ~15 s before this round's fix)
- Full validator set (~1.42M) + consecutive epochs indexed; tracks chain head in a bounded sawtooth.
- `/api/v1/epoch/finalized` populates as epochs finalize — use `/api/v1/epoch/latest` for the very latest.

## Fixes made this round (committed + pushed to `path-a/hoodi-v1.59.0`)

1. **EIP-7549 / Electra attester attribution.** The explorer mis-attributed *every* attestation
   to validator 0 on Hoodi — it predated Electra, where `attestation.Data.Index` is always 0 and
   `aggregation_bits` spans all committees in `committee_bits`. Rewrote the resolver to walk
   `committee_bits` + the concatenated `aggregation_bits`; verified bit-exact against the node.
2. **`hoodi.chain.yml` was missing the mainnet preset** (`SLOTS_PER_EPOCH`, etc.) → the explorer
   fatally rejected the chain config on startup. Merged the mainnet preset in.
3. **Validator endpoint ~15 s → ~20 ms.** The handler re-read the single ~1.4M-column
   `<chain>:lastAttestationSlot` wide row on every request (a multi-second read against the
   dev-grade emulator at Hoodi scale). Now served from the already-maintained in-memory
   `LastAttestationCache`.
4. Config completeness: Pectra (EIP-7002/7251) predeploy addresses + a frontend session secret.
5. Opened `:80` in the host firewall (ufw) so the API is reachable externally.

Prior-round fixes still carry: missing Bigtable schema init; two gRPC 4 MB message-limit fixes;
`--semi-supernode` on Lighthouse for PeerDAS/Fulu blob support; the current-forward `startSlot`
anchor; v1.59.0 migration fixes; and the O(N) `lastAttestationSlot` write fix.

## Known caveats

- **Bigtable emulator is still dev-grade** (free, postgres-backed). With this box's headroom it
  keeps up fine for current-forward; real GCP Bigtable remains the production-grade option and is
  required for full-archive scale. Accepted tradeoff for now.
- **No genesis/full history.** Nodes are non-archive → current-forward only. Full history needs
  archive nodes (Lighthouse `--reconstruct-historic-states` + an EL archive) — a separate,
  day-scale effort that can be scheduled if/when needed.
- Testnet has no price feed → benign `incomplete historic eth prices` errors in the logs.

## Remaining decisions

1. Confirm current-forward is sufficient for dev-team testing, or schedule the full-history (archive) effort.
2. Real GCP Bigtable vs the free emulator for the longer term.
3. Optional: TLS in front of the API.

Deployment is fully reproducible — see `docs/stakepad-hoodi/RUNBOOK.md`.
