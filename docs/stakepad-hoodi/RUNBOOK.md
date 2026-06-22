# Hoodi beaconcha.in (v1 `/api/v1`) — Path A Corrected Runbook

> **For agentic workers:** This is an **ops runbook**, not a TDD plan. Each task has explicit commands and an **expected result** that acts as its verification gate. Do not advance past a task whose verification fails. Steps use `- [ ]` checkboxes for tracking.

**Goal:** Stand up gobitfly's **v1** `eth2-beaconchain-explorer` serving `/api/v1` for Hoodi (chain 560048) on this VM (`GS-Prod-VA1-VM218`), **current-forward data only** (no genesis backfill), as a free internal replacement for the paid hosted beaconcha.in API for stakepad.

**Architecture:** Reuse the already-synced `geth-hoodi` + `lighthouse-hoodi` (checkpoint-synced, non-archive). Explorer = **Postgres** (relational, goose migrations) **+ a Bigtable-API store** (the `little_bigtable_postgres` emulator, *not* GCP Bigtable) **+ Redis**. Index head-forward only; tolerate historical-backfill noise that the non-archive nodes can't satisfy.

**Tech stack:** Go (explorer `make all`), PostgreSQL 16, Redis, `gobitfly/little_bigtable_postgres`, systemd.

**Why the original runbook failed:** its step 6 ran only `psql -f tables.sql` (the Postgres half) and never initialized the **Bigtable** half. The real init commands are `applyDbSchema` + **`initBigtableSchema`** (both in `cmd/misc/main.go`). The root README and `config-example.yml` are stale (2023); trust `types/config.go` / `db/db.go` instead.

---

## 🆕 STARTING ON A FRESH MACHINE — read this first

This runbook was written against the existing VM (nodes already synced, repos already cloned). On a brand-new box, do **Step 0** below first, THEN follow the Tasks. **Clone OUR FORKS — not gobitfly upstream — or you lose every fix.**

### Step 0a — base packages, user, dirs
```bash
sudo apt update && sudo apt -y upgrade
sudo apt install -y build-essential git curl jq wget ca-certificates postgresql postgresql-contrib redis-server golang-go
# explorer needs Go >=1.23; if distro Go is older, install from go.dev/dl instead.
sudo useradd --system --home /var/lib/beaconcha --shell /usr/sbin/nologin beaconcha || true
sudo mkdir -p /opt/beaconcha /etc/beaconcha /var/lib/beaconcha
```

### Step 0b — clone YOUR forks + the fix branches
```bash
cd /opt/beaconcha
sudo chown $USER:$USER /opt/beaconcha
git clone -b path-a/hoodi-v1.59.0 https://github.com/1to3for5vi7ate9x/eth2-beaconchain-explorer.git
git clone -b path-a/hoodi-scale   https://github.com/1to3for5vi7ate9x/little_bigtable_postgres.git
```

### Step 0c — (nothing to do; all fixes are in the forks)
The previously-outstanding emulator `BYTEA` row-key fix is now **committed on `path-a/hoodi-scale`** (commit `a371024`). As long as you cloned the branches in 0b, the code is complete — there are no manual patches to apply.

### Step 0d — set up the nodes (these parts of Will's ORIGINAL runbook were correct)
Install geth + lighthouse binaries, JWT at `/etc/ethereum/<net>/jwt.hex`, datadirs under `/var/lib/ethereum/<net>/{execution,consensus}`, and the `geth-<net>.service` + `lighthouse-<net>.service` units **— BUT with two corrections from this runbook:**
- Lighthouse: **add `--semi-supernode`** (Hoodi PeerDAS — see R7). For mainnet, add it once Fulu activates there.
- **Disk layout:** put Postgres (`/var/lib/postgresql`) and the explorer datastores on **separate NVMe** from the node datadirs.

### Step 0e — which history scope? (sets `startSlot` + node type)
| Scope | Node | `indexer.startSlot` (Task 7) |
|---|---|---|
| **Hoodi / current-forward** (this runbook as written) | checkpoint-synced, non-archive | current head slot |
| **Mainnet from Jan 2024 → now** | **CONSENSUS ARCHIVE** (Lighthouse tree-states / `--reconstruct-historic-states`) covering Jan 2024; **EL archive** (Erigon/Reth) if EL data wanted | the **slot at Jan-2024 epoch** (not head) — and the non-fatal-404 fixes (already in our branch) stop pruning stalls. Spec: 32 core / 128 GB / 8–16 TB NVMe. |

After Step 0, continue with the Tasks below (skip the "already done" pre-flight notes — they're VM-specific).

---

## 🎯 MODE FOR THIS DEPLOYMENT: FULL HISTORY FROM GENESIS (beefy box: 64-core / 2 TB RAM / 100 TB)

This box has no resource constraints, so we index **all of Hoodi from genesis** (not current-forward). The Tasks below were written for current-forward; apply these **deltas**:

**D1 — Nodes must be ARCHIVE (this is the critical difference).** The explorer needs every epoch's beacon state, so a checkpoint-synced node will NOT work.
- **Lighthouse:** sync **from genesis** (omit `--checkpoint-sync-url`) so tree-states retains all historic states, AND keep `--semi-supernode` (Hoodi PeerDAS). If you must checkpoint-sync for speed, instead add `--reconstruct-historic-states` to backfill states. Verify before indexing: `curl -s localhost:5052/eth/v1/beacon/states/1024/root` returns a root (not 404).
- **Execution:** run **archive** (Geth `--gcmode=archive`, or Erigon/Reth archive). Needed for deposits/withdrawals/execution-rewards across all of history.
- Expect genesis sync + state availability to take a while; the hardware handles it.

**D2 — Index from genesis: do NOT set `indexer.startSlot`.** Skip Task 7's anchor entirely. With `startSlot` unset (or `0`), the explorer's stock behavior indexes from the genesis slot forward — exactly what we want. (The `startSlot` knob is only for the current-forward stopgap on under-spec'd boxes.) Likewise set `indexer.eth1DepositContractFirstBlock: 0` to index all deposits.

**D3 — R2/R3 do NOT apply here.** Those risks (non-archive can't serve old states; no genesis knob) were current-forward concerns. With an archive node + genesis indexing, the participation/proposer/assignment lookups all resolve — our non-fatal-404 fixes remain as a safety net but shouldn't trigger.

**D4 — Run ALL services (no contention worry on this box).** After the main `explorer` service (Task 8) is healthy, also stand up:
```bash
# frontend-data-updater — populates the redis caches that /api/v1/epoch/latest, /validator need
sudo tee /etc/systemd/system/beaconcha-frontend-updater-hoodi.service >/dev/null <<'EOF'
[Unit]
Description=beaconcha.in frontend-data-updater - Hoodi
After=network-online.target postgresql.service redis-server.service beaconcha-hoodi.service
[Service]
User=beaconcha
Group=beaconcha
WorkingDirectory=/opt/beaconcha/eth2-beaconchain-explorer
ExecStart=/opt/beaconcha/eth2-beaconchain-explorer/bin/frontend-data-updater -config /etc/beaconcha/hoodi.yml
Restart=always
RestartSec=10
[Install]
WantedBy=multi-user.target
EOF
# statistics — daily validator/chart stats (needed for /validator history + charts)
sudo tee /etc/systemd/system/beaconcha-statistics-hoodi.service >/dev/null <<'EOF'
[Unit]
Description=beaconcha.in statistics - Hoodi
After=network-online.target postgresql.service redis-server.service beaconcha-hoodi.service
[Service]
User=beaconcha
Group=beaconcha
WorkingDirectory=/opt/beaconcha/eth2-beaconchain-explorer
ExecStart=/opt/beaconcha/eth2-beaconchain-explorer/bin/statistics -config /etc/beaconcha/hoodi.yml -charts.enabled -validators.enabled -deposits.enabled -graffiti.enabled
Restart=always
RestartSec=30
[Install]
WantedBy=multi-user.target
EOF
sudo systemctl daemon-reload
sudo systemctl enable --now beaconcha-frontend-updater-hoodi beaconcha-statistics-hoodi
```

**D5 — Postgres tuning for 2 TB RAM** (both the explorer DB and the emulator's `little_bigtable` DB live in Postgres). In `postgresql.conf`: `shared_buffers=128GB`, `effective_cache_size=512GB`, `work_mem=512MB`, `max_wal_size=64GB`, `maintenance_work_mem=8GB`. Keep `ALTER DATABASE little_bigtable SET synchronous_commit=off` (Task — reconstructible store). With this much RAM the whole working set stays cached and the per-epoch writes are trivial.

**D6 — Expect a long genesis backfill.** Indexing all of Hoodi from genesis (~100k+ epochs × ~1.4M validators) is a multi-hour-to-day job even on this hardware. It's a one-time cost; watch `select max(epoch) from epochs;` climb. This is the dress-rehearsal for the mainnet-from-Jan-2024 archive deployment.

---

## 🛟 FALLBACK MODE: CURRENT-FORWARD (use if the archive node strains)

If the archive route is fighting you — Lighthouse genesis sync / `--reconstruct-historic-states` is too slow, EL archive is too heavy, disk/IO strain, or states still come back 404 — **don't get stuck. Fall back to current-forward and get a live `/api/v1` of recent data, then revisit history later.** This is the exact path we validated end-to-end; it's lower-risk and stands up in hours, not days. The base Tasks below already implement it.

**To switch from full-history → current-forward, reverse the deltas:**

| Delta | Full history | Fallback: current-forward |
|---|---|---|
| **Node** | archive (genesis-synced LH + EL archive) | **checkpoint-synced** Lighthouse (`--checkpoint-sync-url https://checkpoint-sync.hoodi.ethpandaops.io`) + `--semi-supernode`; normal `--syncmode snap` Geth. Fast to sync, light on disk. |
| **Anchor** | `startSlot` unset (genesis) | **Do Task 7:** set `indexer.startSlot` = **current head slot** (`startSlot = floor(head_slot)`), so it indexes from now forward. |
| **eth1 deposits** | `eth1DepositContractFirstBlock: 0` | set to a **recent EL block** (≈ geth head − 50000) so it doesn't backfill the whole deposit history. |
| **Data scope** | all of Hoodi | recent/current only (no deep history; charts/history endpoints sparse until enough time passes) |
| **404 safety net** | rarely triggers | the non-fatal-participation/proposer fixes (already in the branch) let it ride out lag spikes without stalling |

**Everything else is identical** (build, both schema inits, emulator, config, the D4 services, D5 Postgres tuning). On this hardware current-forward will keep up trivially (the old VM's sawtooth/lag problems were a resource ceiling we no longer have).

**Switching back later:** once the archive node is healthy, you can move to full history by wiping the two DBs (`beaconchain_hoodi` + `little_bigtable`), re-running both schema inits, unsetting `startSlot`, and restarting — it re-indexes from genesis. (No code changes; just config + a fresh datastore.)

**Rule of thumb:** spend at most ~a day fighting archive sync. If it's not healthy by then, flip to current-forward (≈30 min of config changes), ship the live API, and treat full history as a follow-up. A working current-data `/api/v1` beats a stalled full-history one.

---

## ⚠️ Known risks — read before starting

| # | Risk | Mitigation in this runbook |
|---|---|---|
| R1 | **4 MB gRPC limit** rejects Hoodi-scale messages (lastAttestationSlot row AND ~10 MB per-slot attestation mutations). | Task 2b: emulator-path patch in `db/bigtable.go` — the bigtable lib **ignores dial options on the emulator path**, so dial the emulator conn ourselves with `MaxCallRecv/SendMsgSize(256MiB)` and inject via `WithGRPCConn`. (A plain `WithGRPCDialOption` does NOT work for the emulator.) Emulator server already allows 256 MiB. |
| R7 | **PeerDAS/Fulu active on Hoodi**: non-supernode Lighthouse custodies only 4/64 data columns → can't serve `blob_sidecars`, which the explorer fetches fatally per slot. | Task 7b: add `--semi-supernode` to lighthouse-hoodi, restart, wait ~5 min for peering (custody_group_count→64, peers climb), verify `blob_sidecars` returns 200 on fresh slots, THEN anchor startSlot at current head. |
| R2 | **No "start from epoch N" config knob** exists. Stock explorer wants genesis. | Task 7: head-forward indexing + accept backfill errors; optional DB pre-seed. **This is the iterate-live step.** |
| R3 | **Non-archive Lighthouse** can't serve states older than ~current finalized. | Anchor everything at/after finalized epoch (~102731 as of 2026-06-16). Backfill of old epochs will log errors — expected. |
| R4 | `little_bigtable_postgres` **Postgres DSN flag is under-documented** (README inherited from SQLite fork; shows `-db-file`, default port 9000). | Task 4: inspect its `main.go` for the real DSN flag before writing the unit; verify with a `cbt` round-trip. |
| R5 | At Hoodi scale the emulator path is **dev/test-grade**, not gobitfly's production design (they use real GCP Bigtable). | Accepted per team decision (current subset OK now). Full-archive = separate Path B box. |
| R6 | Repo `/opt/beaconcha/...` is owned `beaconcha:beaconcha` and has **stale hand-patches** (incl. a `MaxCAllRecvMsgSize` typo that breaks the build). | Task 2: hard-reset to clean `v1.59.0` before patching. |

---

## Pre-flight — what is already done (do NOT redo)

- [ ] **Verify nodes are synced** (no action if green)

```bash
curl -s http://127.0.0.1:15052/eth/v1/node/syncing | jq -c .data
curl -s http://127.0.0.1:15052/eth/v1/beacon/states/head/finality_checkpoints | jq -c '.data.finalized'
curl -s -X POST http://127.0.0.1:18545 -H 'content-type: application/json' \
  -d '{"jsonrpc":"2.0","method":"eth_syncing","params":[],"id":1}' | jq -c .result
```
Expected: `is_syncing:false`; a finalized epoch ≈ 102731+; geth `eth_syncing` → `false`.
Already present: Postgres 16 (`5432`), Redis (`6379`), repo at `/opt/beaconcha/eth2-beaconchain-explorer`.

Record the **anchor epoch** = current finalized epoch (used in Task 7): `ANCHOR_EPOCH=$(curl -s http://127.0.0.1:15052/eth/v1/beacon/states/head/finality_checkpoints | jq -r .data.finalized.epoch)`

---

## Task 1: Clean slate for the old broken datastore

**Files:** none (DB + service teardown)

- [ ] **Step 1: Stop & disable the old broken units** (idempotent)

```bash
sudo systemctl disable --now beaconcha-hoodi.service little-bigtable.service 2>/dev/null || true
```
Expected: no error (units already stopped/disabled from the June pivot).

- [ ] **Step 2: Drop the old half-populated Postgres DB** (it was indexed by the broken SQLite emulator)

```bash
sudo -u postgres psql -c "DROP DATABASE IF EXISTS beaconchain_hoodi;"
sudo -u postgres psql -c "DROP DATABASE IF EXISTS beaconchain_hoodi_test;"
```
Expected: `DROP DATABASE`.

- [ ] **Step 3: Remove the old SQLite little_bigtable data**

```bash
sudo rm -f /var/lib/beaconcha/hoodi/little_bigtable.db
```
Expected: gone (`ls` returns no such file).

---

## Task 2: Reset explorer to clean v1.59.0 and apply the 4 MB patch

**Files:**
- Modify: `/opt/beaconcha/eth2-beaconchain-explorer/db/bigtable.go:123`

- [ ] **Step 1: Take ownership for the build user & mark git safe**

```bash
sudo chown -R ankit-gs:ankit-gs /opt/beaconcha/eth2-beaconchain-explorer
git config --global --add safe.directory /opt/beaconcha/eth2-beaconchain-explorer
```
Expected: no output.

- [ ] **Step 2: Hard-reset to the pinned release (discards all stale hand-patches incl. the typo)**

```bash
cd /opt/beaconcha/eth2-beaconchain-explorer
git fetch --tags
git stash clear 2>/dev/null || true
git checkout -f v1.59.0
git reset --hard v1.59.0
git status --short      # must be EMPTY
```
Expected: `HEAD is now at … v1.59.0`; `git status --short` prints nothing.

- [ ] **Step 3 (R1 fix): Add `MaxCallRecvMsgSize` to the Bigtable client**

In `db/bigtable.go`, the client is created (~line 123):
```go
btClient, err := gcp_bigtable.NewClient(ctx, project, instance, option.WithGRPCConnectionPool(poolSize))
```
Change it to:
```go
btClient, err := gcp_bigtable.NewClient(ctx, project, instance,
    option.WithGRPCConnectionPool(poolSize),
    option.WithGRPCDialOption(grpc.WithDefaultCallOptions(grpc.MaxCallRecvMsgSize(256<<20))),
)
```
Ensure the imports block has:
```go
"google.golang.org/grpc"
```
(`option` is already imported.) This applies to the emulator path too, because the emulator dials through the same `NewClient`.

- [ ] **Step 4: Build** (two prerequisites — the Makefile `go install`s `swag` then calls it by bare name, and `swag init` needs the full module cache present)

```bash
cd /opt/beaconcha/eth2-beaconchain-explorer
export PATH="$PATH:$(go env GOPATH)/bin"   # else: "swag: No such file or directory" (Makefile:27)
go mod download all                         # else swag fails: "handlers cannot find all dependencies, <nil>"
make all
ls -la bin/explorer bin/misc
```
Expected: exit 0; both binaries present (~118 MB / ~60 MB). Benign `ld: missing .note.GNU-stack` warnings from blst CGO are fine. (If `grpc` import is missing you'll get a compile error — add it and rebuild.)
Verify: `bin/misc --help 2>&1 | grep -oE 'applyDbSchema|initBigtableSchema'` lists both.

- [ ] **Step 5: Commit the patch on a local branch (traceability)**

```bash
git checkout -b path-a/hoodi-v1.59.0
# VM has no global git identity — set repo-local once or the commit aborts:
git config user.email "ops@stakepad.local"; git config user.name "stakepad-ops"
git add db/bigtable.go
git commit -m "fix(bigtable): raise gRPC MaxCallRecvMsgSize to 256MiB for Hoodi-scale rows"
```
Expected: one commit recorded. (`go.sum` may show modified from the build — leave it.)

---

## Task 3: Fresh Postgres database

**Files:** none

- [ ] **Step 1: (Re)create role & DB**

```bash
sudo -u postgres psql -c "DO \$\$ BEGIN IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname='beaconchain') THEN CREATE ROLE beaconchain LOGIN PASSWORD 'change-me'; END IF; END \$\$;"
sudo -u postgres createdb -O beaconchain beaconchain_hoodi
```
Expected: `CREATE DATABASE`. (Replace `change-me` with a real secret; store it root-0600 like `/etc/beaconcha/db.pass`.)

- [ ] **Step 2: Verify connectivity**

```bash
psql "postgres://beaconchain:change-me@127.0.0.1:5432/beaconchain_hoodi?sslmode=disable" -c '\conninfo'
```
Expected: `You are connected to database "beaconchain_hoodi"`.

---

## Task 4: little_bigtable_postgres emulator (replaces the SQLite one)

**Files:**
- Create: `/opt/beaconcha/little_bigtable_postgres/` (clone)
- Create: `/etc/systemd/system/little-bigtable-pg.service`

- [ ] **Step 1: Clone & build**

```bash
cd /opt/beaconcha
sudo -u ankit-gs git clone https://github.com/gobitfly/little_bigtable_postgres.git
cd little_bigtable_postgres
go build -o little_bigtable_postgres .
```
Expected: binary built, exit 0.

- [ ] **Step 2 (R4 — RESOLVED): the REAL flags** (README is inherited from the SQLite fork and is WRONG — there is no `-db-file`)

Verified from `./little_bigtable_postgres -h` and `little_bigtable.go`:
```
-host         bind address (default localhost)
-port         bind port (default 9000)        ← we use 19000
-db-host      postgres host (default localhost)
-db-port      postgres port (default 5432)
-db-name      postgres db name (default "bigtable")
-db-username  postgres user
-db-password  postgres password
```
It opens `postgres://<user>:<pass>@<host>:<port>/<db>?sslmode=disable` (pgx) — so it needs its own backing DB:
```bash
sudo -u postgres createdb -O beaconchain little_bigtable
```
Note: source dir lives under `/opt/beaconcha` (owned `beaconcha`); create the clone dir with `sudo mkdir` + `chown ankit-gs` to build, then `chown -R beaconcha` before running as the service user. The built binary is `little_bigtable_postgres` (rename from any `-o` output name).

- [ ] **Step 3: systemd unit** (real flags; `0640` to limit cleartext-password exposure)

```bash
sudo tee /etc/systemd/system/little-bigtable-pg.service >/dev/null <<'EOF'
[Unit]
Description=little_bigtable_postgres (Bigtable emulator, postgres-backed) - Hoodi
After=network-online.target postgresql.service
Wants=network-online.target
[Service]
User=beaconcha
Group=beaconcha
ExecStart=/opt/beaconcha/little_bigtable_postgres/little_bigtable_postgres \
  -host 127.0.0.1 -port 19000 \
  -db-host 127.0.0.1 -db-port 5432 -db-name little_bigtable \
  -db-username beaconchain -db-password change-me
Restart=always
RestartSec=5
LimitNOFILE=1048576
[Install]
WantedBy=multi-user.target
EOF
sudo chmod 0640 /etc/systemd/system/little-bigtable-pg.service
sudo chown -R beaconcha:beaconcha /opt/beaconcha/little_bigtable_postgres
sudo systemctl daemon-reload
sudo systemctl enable --now little-bigtable-pg
```
Expected: `systemctl is-active little-bigtable-pg` → `active`; `ss -ltnp | grep 19000` shows it listening. Startup log: `"little" Bigtable emulator running. DB:postgres://…/little_bigtable …`.

- [ ] **Step 4: Smoke test** — `cbt` is NO LONGER `go install`-able (removed from the bigtable module ≥ v1.49; it's a `gcloud components install cbt` tool now). **Skip cbt; the real integration test is Task 6 `initBigtableSchema`**, which drives the actual explorer Bigtable client (with the 4 MB patch) against this emulator. If it creates tables without a `ResourceExhausted`/4 MB error, the emulator + patch + client are all proven together.

---

## Task 5: Explorer config `/etc/beaconcha/hoodi.yml`

**Files:**
- Create: `/etc/beaconcha/hoodi.yml`

- [ ] **Step 1: Write the corrected config** (modern keys from `types/config.go`, NOT the stale `config-example.yml`)

```bash
sudo tee /etc/beaconcha/hoodi.yml >/dev/null <<'EOF'
chain:
  configPath: '/opt/beaconcha/eth2-beaconchain-explorer/config/hoodi.chain.yml'
  name: hoodi

readerDatabase:
  name: beaconchain_hoodi
  host: 127.0.0.1
  port: "5432"
  user: beaconchain
  password: "change-me"
writerDatabase:
  name: beaconchain_hoodi
  host: 127.0.0.1
  port: "5432"
  user: beaconchain
  password: "change-me"

bigtable:
  project: explorer
  instance: explorer
  emulator: true
  emulatorHost: 127.0.0.1
  emulatorPort: 19000

eth1GethEndpoint: 'http://127.0.0.1:18545'
eth1ErigonEndpoint: 'http://127.0.0.1:18545'

redisCacheEndpoint: '127.0.0.1:6379'
redisSessionStoreEndpoint: '127.0.0.1:6379'
tieredCacheProvider: 'redis'

indexer:
  enabled: true
  node:
    host: 127.0.0.1
    port: '15052'
    type: lighthouse

frontend:
  enabled: true
  server:
    host: '127.0.0.1'
    port: '18080'
  readerDatabase:
    name: beaconchain_hoodi
    host: 127.0.0.1
    port: "5432"
    user: beaconchain
    password: "change-me"
  writerDatabase:
    name: beaconchain_hoodi
    host: 127.0.0.1
    port: "5432"
    user: beaconchain
    password: "change-me"
EOF
sudo mkdir -p /etc/beaconcha && sudo chown -R beaconcha:beaconcha /etc/beaconcha
sudo chmod 0640 /etc/beaconcha/hoodi.yml
```
Expected: file written. (Keep the real password out of world-readable space; `0640 beaconcha:beaconcha`.)

---

## Task 6: Initialize BOTH schemas — the step the old runbook was missing

**Files:** none (uses `bin/misc`)

- [ ] **Step 1: Apply Postgres schema via embedded goose migrations** (NOT `psql -f tables.sql`)

```bash
cd /opt/beaconcha/eth2-beaconchain-explorer
./bin/misc -config /etc/beaconcha/hoodi.yml -command applyDbSchema -target-version -2
```
Expected: goose runs migrations `20230330…` → `20250930…`; exit 0.
Verify: `psql "postgres://beaconchain:change-me@127.0.0.1:5432/beaconchain_hoodi?sslmode=disable" -c '\dt' | head` shows many tables incl. `validators`, `blocks`, `epochs`.

- [ ] **Step 2: Initialize the Bigtable schema (THE missing command)**

```bash
./bin/misc -config /etc/beaconcha/hoodi.yml -command initBigtableSchema
```
Expected: creates the Bigtable tables (validators, validators_history, blocks, data, metadata, …); exit 0.
Verify: `BIGTABLE_EMULATOR_HOST=127.0.0.1:19000 cbt -project explorer -instance explorer ls` lists those tables.

---

## Task 7: Current-forward indexing (R2 — the iterate-live step)

**Files:** possibly `/etc/beaconcha/hoodi.yml` (no stock knob exists; this is empirical)

There is **no `startEpoch` config field** in v1.59.0. The exporter indexes the **head forward** automatically (good) but its historical exporters will try to walk back toward genesis and fail on the non-archive Lighthouse (R3). Approach, in order of preference:

- [ ] **Step 1: Run head-forward and observe** — start the service (Task 8) and watch whether head epochs export cleanly while only *historical* backfill errors. For a current-data `/api/v1`, head-forward is sufficient.

- [ ] **Step 2 (fallback, only if genesis churn blocks head progress): pre-seed `epochs` as already-exported** up to the anchor, so the backfiller has nothing old to chase:

```bash
ANCHOR_EPOCH=$(curl -s http://127.0.0.1:15052/eth/v1/beacon/states/head/finality_checkpoints | jq -r .data.finalized.epoch)
# Insert lightweight 'finalized' marker rows for epochs 0..ANCHOR-1 so the exporter skips them.
# EXACT columns must be read from the migration that creates `epochs` before running —
# verify with: psql ... -c '\d epochs'   then craft the INSERT accordingly.
```
Expected: after seeding, exporter logs target only epochs ≥ anchor. **Do not run this blind — inspect `\d epochs` first** (R2/R3). Record the exact SQL used back into this runbook.

- [ ] **Step 3: Confirm head epochs land**

```bash
psql "postgres://beaconchain:change-me@127.0.0.1:5432/beaconchain_hoodi?sslmode=disable" \
  -c "select max(epoch) from epochs;"
```
Expected: `max(epoch)` climbs toward the live finalized epoch within a few minutes.

---

## Task 8: Explorer systemd service

**Files:**
- Create: `/etc/systemd/system/beaconcha-hoodi.service`

- [ ] **Step 1: Write & start the unit**

```bash
sudo tee /etc/systemd/system/beaconcha-hoodi.service >/dev/null <<'EOF'
[Unit]
Description=beaconcha.in v1 explorer/indexer - Hoodi
After=network-online.target postgresql.service redis-server.service lighthouse-hoodi.service little-bigtable-pg.service
Wants=network-online.target
[Service]
User=beaconcha
Group=beaconcha
WorkingDirectory=/opt/beaconcha/eth2-beaconchain-explorer
ExecStart=/opt/beaconcha/eth2-beaconchain-explorer/bin/explorer -config /etc/beaconcha/hoodi.yml
Restart=always
RestartSec=10
LimitNOFILE=1048576
[Install]
WantedBy=multi-user.target
EOF
sudo chown -R beaconcha:beaconcha /opt/beaconcha/eth2-beaconchain-explorer
sudo systemctl daemon-reload
sudo systemctl enable --now beaconcha-hoodi
```
Expected: `systemctl is-active beaconcha-hoodi` → `active`.

- [ ] **Step 2: Watch logs for clean head export**

```bash
journalctl -u beaconcha-hoodi -f --no-pager
```
Expected: head epoch/slot export messages; Bigtable connects (no 4 MB error → R1 fixed); only *historical* backfill warnings (R3, benign).

---

## Task 9: Health checks (correct endpoints)

- [ ] **Run the gates** (note: health path is `/api/healthz-loadbalancer`, NOT `/healthz`)

```bash
curl -s http://127.0.0.1:18080/api/healthz-loadbalancer
curl -s http://127.0.0.1:18080/api/v1/epoch/finalized | jq -c '.data | {epoch, finalized, validatorscount}'
curl -s http://127.0.0.1:18080/api/v1/slot/$(curl -s http://127.0.0.1:15052/eth/v1/beacon/headers/head | jq -r .data.header.message.slot) | jq -c '.status'
```
Expected: healthz OK; `/api/v1/epoch/finalized` returns a recent epoch with `validatorscount≈1.06M`; slot lookup `status:"OK"`.
Note: `/api/v1/epoch/{N}` for the **cold-start anchor epoch** or for `latest` right after a boundary may divide-by-zero (upstream bug) — consumers should use `finalized` or explicit epochs ≥ anchor+1.

---

## Task 10: Reverse proxy (optional, for other internal hosts)

- [ ] Same nginx block as the original runbook §9, proxying `:80 → 127.0.0.1:18080`. Add internal auth/allowlist before exposing.

---

## Definition of done (Path A)

- [ ] `beaconcha-hoodi` + `little-bigtable-pg` services `active`.
- [ ] `/api/v1/epoch/finalized` returns live data with full validator count.
- [ ] `max(epoch)` in Postgres tracks the live finalized epoch (current-forward working).
- [ ] No 4 MB gRPC errors in logs (R1 closed).
- [ ] Documented: the exact Task 7 mechanism actually used, and the real Task 4 flags, written back into this file.

## Explicitly NOT in Path A (defer to Path B)
- Genesis / historical backfill (needs EL archive + Lighthouse tree-states archive on a 4 TB / 64 GB box).
- Real GCP Bigtable (production-grade store).
- TC's "full archive eventually" — separate hardware procurement.
