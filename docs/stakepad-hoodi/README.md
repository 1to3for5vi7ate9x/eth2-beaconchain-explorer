# Stakepad self-hosted beaconcha.in — Hoodi (and mainnet) deployment docs

**START HERE → [`RUNBOOK.md`](./RUNBOOK.md)** — the complete, self-contained deployment guide.
On a fresh machine, do its **Step 0** first, then pick the mode:
- **Full history from genesis** (primary on the big box) — archive nodes, index from genesis.
- **Current-forward fallback** — if the archive node strains; live in hours, recent data only.

This branch (`path-a/hoodi-v1.59.0`) and the emulator branch
(`little_bigtable_postgres` @ `path-a/hoodi-scale`) already contain ALL fixes —
clone the branches and build; no manual patches needed.

Other docs:
- [`STATUS-FOR-TEAM.md`](./STATUS-FOR-TEAM.md) — what was fixed, why the original runbook failed, hardware recommendation.
- [`CALL-PREP.md`](./CALL-PREP.md) — one-page specs + talking points (testnet & mainnet).

Companion repo (Bigtable emulator): https://github.com/1to3for5vi7ate9x/little_bigtable_postgres (branch `path-a/hoodi-scale`)
