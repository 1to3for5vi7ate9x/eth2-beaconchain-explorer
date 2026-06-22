# Hoodi self-hosted beaconcha.in `/api/v1` — Status & Recommendation

**Prepared:** 2026-06-17 · **VM:** GS-Prod-VA1-VM218 · **For:** Will, TC, Jessica

---

## TL;DR

We set out to self-host beaconcha.in's `/api/v1` for Hoodi to replace the expensive
hosted API. **The software side is now fully solved** — we fixed every code-level blocker
(the original deployment was stuck because the vendor runbook was outdated and incomplete).
The explorer builds, indexes current Hoodi data, and serves the API.

**The remaining problem is hardware, not software.** Hoodi has **~1.42M validators —
*more than Ethereum mainnet*** — and this single VM does not have the headroom to keep the
indexer continuously caught up. When it falls behind, our (non-archive) Lighthouse has
already pruned the chain states the indexer needs, and indexing stalls.

**Recommendation:** provision a proper box (or use managed Google Bigtable). All our fixes
carry over. Details and options below.

---

## What "Hoodi is just a testnet" misses

The explorer's workload scales with **validator count**, and Hoodi has ~1.42M vs mainnet's
~1.0–1.1M. Every epoch (~6.4 min) the indexer must process the full validator set:
~1.18M attestations, ~1.42M balance updates, and a per-validator "last attestation slot"
record. On this VM that takes **~3.5 minutes per epoch boundary** — it fits the 6.4-min
budget only with thin margin, and any hiccup pushes it over.

## What works today (verified)

- Explorer builds and runs from the official `gobitfly/eth2-beaconchain-explorer` (v1.59.0).
- Both required datastores initialize (Postgres + a Bigtable-API store) — **the step the
  old runbook omitted entirely**, which is why the first attempt was stuck.
- Indexes **current Hoodi data forward** and serves live data:
  - `/api/v1/slot/{n}` — ✅ real proposer/attestation data
  - `/api/v1/epoch/latest`, `/api/v1/epoch/{n}/slots` — ✅ real data
  - `/api/v1/validator/{i}` — ✅ (after this round's fix)
- Committed full validator set (1,423,658) and consecutive epochs.
- When caught up, it tracks chain head in a **bounded sawtooth** (lag rises to ~15–20 slots
  at each epoch boundary, recovers to ~1).

## Why it isn't production-clean on this VM

It has **no margin**. The chain produces a slot every 12s; our per-epoch work plus
background jobs (deposit indexing, daily stats) occasionally push the indexer behind. Once
it lags more than a couple of epochs, our **non-archive Lighthouse has pruned those states**,
so every state-dependent lookup (validator participation, proposer duties, epoch
assignments) returns **404 → the indexer stalls**. This is a single root cause with many
symptoms; it is not a series of independent bugs.

Secondary: the free Bigtable emulator we used (no GCP cost) is dev/test-grade and has
edge cases at this scale (e.g. it rejects certain binary row keys). Fixable, but it's the
wrong tool for a chain this size in production.

## The fixes we made (all committed, carry over to any hardware)

11 distinct fixes across the explorer and the emulator, including: the missing Bigtable
schema init; two separate gRPC 4 MB message-limit issues; PeerDAS/Fulu blob support
(`--semi-supernode` on Lighthouse — Hoodi has data-availability sampling active); a
current-forward "start from recent" anchor (the explorer otherwise only indexes from
genesis, which needs an archive node); migration bugs in v1.59.0; and performance fixes
that took the per-epoch "last attestation slot" write from **timing out (>15 min) down to
seconds** (it was an O(N²) bug, not a fundamental limit).

- Explorer branch: `path-a/hoodi-v1.59.0`
- Emulator branch: `path-a/hoodi-scale` (`gobitfly/little_bigtable_postgres`)
- Full step-by-step: `/home/ankit-gs/hoodi-beaconcha-path-a-runbook.md`

## Options (recommended order)

| Option | What it gives | Cost / trade-off |
|---|---|---|
| **1. Proper box + real GCP Bigtable** | Production-grade, robust, removes both the headroom problem and the emulator's edge cases. gobitfly's own design. | Bigtable has a cloud cost (far below the hosted beaconcha.in API we're replacing) + a cloud dependency. |
| **2. Proper box, keep the free emulator** | Avoids cloud cost; the extra cores/NVMe give headroom so it stays caught up. | Still a dev-grade emulator; needs the BYTEA fix + watching at scale. |
| **3. Keep tuning this VM** | No new spend now. | Does not converge to "clean"; will limp with degraded data on lag spikes. Not recommended. |

**Suggested spec for options 1–2** (current-forward, no deep genesis history):

| | This VM | Suggested |
|---|---|---|
| CPU | 8 cores (shared) | **16 cores** |
| RAM | 31 GB | **64 GB** |
| Disk | 1× 492 GB SATA (shared) | **2–4 TB NVMe**, explorer datastores on separate NVMe from the node |

(Full genesis history — TC's eventual "full archive" — is a separate, much larger ~27–30 TB
storage-server discussion. The above is for the current-forward `/api/v1` we've been building.)

## Decision needed from the team

1. Approve hardware (option 1 or 2) for the current-forward `/api/v1`, **or**
2. Confirm whether Hoodi needs full genesis history at all, or only current-forward
   (this changes the storage class by ~100×).

Everything is captured and reproducible; once hardware exists, standing this up is a known,
documented path — not another research effort.
