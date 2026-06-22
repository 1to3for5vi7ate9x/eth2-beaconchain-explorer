# Beaconcha.in Self-Host — Tech Call Prep (1-pager)

**2026-06-17** · VM: GS-Prod-VA1-VM218 · For: Will / TC / Jessica call

---

## ⚠️ Decision to force FIRST — drives everything

**"Mainnet from Jan 2024 → now" = historical backfill, NOT current-forward.** To index any
past epoch the explorer needs that epoch's beacon state → **requires an ARCHIVE node**
(consensus archive back to Jan 2024; execution archive too if EL/wallet data is wanted).
Our `startSlot` fix already lets us start at the Jan-2024 slot instead of genesis — software
is ready; the cost is **nodes + storage**.

**Sub-decision (the ~10–100× storage swing) — get this confirmed:**
> Full execution-layer / wallet data (every tx, address, ERC-20/721, contract)
> **— OR —** validator/consensus data + light EL (validators, balances, rewards,
> deposits, withdrawals)?

For stakepad: argue for **validator + light EL**, NOT the full wallet indexer (~45 TB beast).

---

## Hardware specs to demand

**Hoodi testnet (current-forward / recent)** — current 8-core/31 GB/1 shared disk is too weak:

| CPU | RAM | Disk |
|---|---|---|
| **16 cores** | **64 GB** | **2 TB NVMe** (explorer datastore on separate NVMe from node) |

**Mainnet, Jan 2024 → now, validator + light EL** (realistic stakepad scope):

| CPU | RAM | Disk |
|---|---|---|
| **32 cores** | **128 GB** | **8–16 TB NVMe** |

Disk breakdown: CL archive ~0.5–1 TB · EL archive (Erigon/Reth) ~2–3 TB · explorer Postgres
~1–2 TB · **per-epoch balance/attestation history store ~3–8 TB (swing factor)**.
Layout: **node disks SEPARATE from explorer-datastore disks** (they contend hard otherwise).

**Full EL/wallet data (only if product truly needs it):** 32+ cores, 256 GB RAM, **60 TB+** —
push back unless justified.

**Set expectations out loud:** (1) backfilling 2.5 yr takes days-to-weeks regardless of CPU;
(2) do NOT put mainnet on a shared/under-spec box — that's exactly what failed on Hoodi.

---

## Where Will's runbook failed

A node runbook with a stale 2023 explorer section bolted on — got the node up, could not
get the explorer working.

**Missing:**
1. **The entire Bigtable datastore layer** — explorer needs Postgres **AND** a Bigtable-API
   store; runbook's `psql -f tables.sql` did only the Postgres half, never mentioned
   Bigtable. **This is why it was stuck.**
2. **The Bigtable schema init** (`initBigtableSchema` command) — absent.
3. **The Bigtable emulator** (`little_bigtable_postgres`, the free store) — absent.

**Stale / wrong:**
4. Dead Prysm `--archive` flag (removed years ago).
5. No PeerDAS/blob handling — Hoodi needs `--semi-supernode` or blob reads 404.
6. 2023 `config-example.yml` missing all modern datastore keys.
7. Floating `master` instead of pinned release (`v1.59.0`).
8. Never flagged that historical indexing needs an **archive node** (critical for mainnet
   Jan-2024 plan).

**What's needed to go (done / documented):**
- Corrected runbook: `/home/ankit-gs/hoodi-beaconcha-path-a-runbook.md`
- All fixes on our GitHub forks: branches `path-a/hoodi-v1.59.0` (explorer) &
  `path-a/hoodi-scale` (emulator), at `github.com/1to3for5vi7ate9x/...`
- Mainnet: proper hardware (above) + archive nodes covering Jan 2024 + `startSlot` at the
  Jan-2024 slot + one outstanding emulator `BYTEA` fix.

---

## Soundbites

- "Explorer software is solved — the original runbook was outdated and skipped the entire
  Bigtable datastore layer. That's fixed and on our GitHub."
- "Hoodi is heavier than mainnet by validator count (~1.42M vs ~1.1M). 'Just a testnet' is
  misleading — our 8-core shared VM can't keep up; we need real hardware."
- "Mainnet from Jan 2024 = archive nodes, not a normal node — that's the main cost. Confirm:
  validator data only, or full wallet/tx history? Decides ~10 TB vs ~60 TB."
- "Specs: Hoodi — 16 core / 64 GB / 2 TB NVMe. Mainnet — 32 core / 128 GB / 8–16 TB NVMe,
  node and explorer storage on separate disks."
- "Avoiding Google Bigtable cost is fine — we proved the free self-hosted emulator works at
  Hoodi scale; it just needs adequate hardware."
