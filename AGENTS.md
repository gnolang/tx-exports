# AGENTS.md

This file provides guidance to autonomous AI agents when working with code in this repository.

## Purpose

This repository archives raw blockchain transaction data exported from Gno.land chains:

- **Active**: mainnet.gno.land (`gnoland-1`), onyx.gno.land (test17), staging.gno.land
- **Historical**: test1–test5, test11, test13, topaz (test14), sapphire (test15), betanet, pearl (test16) (archived, no longer updated)
- **Never exported**: test6–test10, test12 — deployed, shut down, no reachable RPC

`gnoland1` (no dash) is the retired betanet's chain id, archived under
`betanet.gno.land/`. `gnoland-1` (with a dash) is mainnet, under
`mainnet.gno.land/`. They are different chains.

Directory names follow the chain's **hostname**, not its chain id — the one
exception was `gnoland1/`, renamed to `betanet.gno.land/` for exactly that reason.

## Common Commands

Each chain directory has its own `Makefile` that includes `../rules.mk`. Run these from within the chain directory (e.g., `cd onyx.gno.land`; `make fetch` refuses to run where the Makefile declares no `CHAIN_ID`):

```sh
make fetch        # Download new transactions from the chain RPC
make fetch-all    # Fetch all blocks in MAX_INTERVAL chunks up to current height
make stats        # Regenerate README.md statistics from backup files
make extractor    # Run the Go extractor to parse deployed packages/realms
make loop         # Continuous loop: fetch → stats → commit → push (for CI)
```

`staging.gno.land` uses a custom `export.sh` script instead of `make fetch` — the CI workflow calls it directly.

### Running the backup tool directly

tx-archive lives in gnolang/gno at `contribs/tx-archive`, whose `go.mod` replaces gno with `../..`, so it only builds from a gno checkout (no remote `go run …@version`). `make tx-archive-ensure` clones gno at the dir's `GNO_REF` into `~/.cache/tx-exports/gno-<GNO_REF, / as ->`; run it from there:

```sh
cd ~/.cache/tx-exports/gno-v1.6.0-rc.1/contribs/tx-archive   # onyx's GNO_REF
go run ./cmd backup --remote <RPC_URL> --from-block <N> --to-block <M> --output-path backup_N-M.jsonl
```

### Running the extractor

```sh
# From repo root (the extractor is its own Go module), into a fresh dir;
# `make -C test11.gno.land extractor` writes test11.gno.land/extracted instead
go run -C extractor . -source-path ../test11.gno.land -output-dir /tmp/test11-extracted
# test1 stores plain std.Tx lines in txexport-*.log: add -legacy-mode -file-type .log
```

## Architecture

### Directory layout

Each chain directory is self-contained:

- `Makefile` — sets `REMOTE`, `SHORTNAME`, `MAX_INTERVAL`, and includes `../rules.mk`. Active chains also set `CHAIN_ID` (the chain id `make fetch` requires the RPC to report) and `GNO_REF` (the gno release tag their nodes run, bumped with every node upgrade); archived dirs keep the `chain/*` `GNO_REF` they were exported with, or none (`master`)
- `backup_*.jsonl` — exported transaction data, one JSON object per line, in block-number order (staging also has `backup_staging_balances.jsonl`: `addr=amountugnot` lines, hence its `BACKUP_FILES`)
- `metadata.json` — tracks `latest_block_height` so incremental fetches know where to resume
- `README.md` — auto-generated stats (tx count, deployed packages, top realm calls, top faucet requesters)

### Transaction data format

Every `backup_*.jsonl` tx line wraps one `std.Tx` under `tx`:

```json
{"tx": {"msg": [...], "fee": {...}, "signatures": [...], "memo": ""}, "metadata": {"timestamp": "..."}}
```

test2–test4 carry `"blockNum": "<n>"` instead of `metadata`; the first 291 lines of staging's `backup_staging_txs_1-1000.jsonl` carry neither. test1 predates the wrapper: plain `std.Tx` lines in `txexport-*.log`, which the extractor reads with `-legacy-mode`.

It is Amino JSON (Tendermint2 wire format). test1–test3 predate gnolang/gno#2019's snake_case JSON tags, so their `/vm.m_addpkg` package and file keys are capitalized (`Name`, `Path`, `Files`, `Body`); every other chain uses lowercase.

### Transaction message types relevant to extraction

- `/vm.m_addpkg` (`MsgAddPackage`) — deploys a new package or realm
- `/vm.m_call` (`MsgCall`) — calls a function on an existing realm
- `/vm.m_run` (`MsgRun`) — executes ephemeral code
- `/bank.MsgSend` — token transfer
- `/vm.m_enable_pkg` (`MsgEnablePackage`) — activates a parked package (mainnet and onyx)

### staging.gno.land specifics

Uses `export.sh` instead of tx-archive. It calls `gnogenesis txs export` and `gnogenesis balances export` against the Portal Loop RPC, chunks output into 1000-line JSONL segments, and downloads `genesis.json`. The CI workflow (`staging-txs-exporter.yml`) runs daily at 18:00 UTC.

### mainnet.gno.land specifics

Mainnet (`gnoland-1`) launched 2026-09-12 as a fresh chain, not a hardfork of
betanet, so its export starts at block 1.

Two ways it differs from the recent testnets:

- **No `USE_WS=1`.** `rpc.gno.land` does not WAF-block high-volume HTTP batch
  fetches the way the `*.testnets.gno.land` endpoints do, and HTTP is faster
  (tx results are batched over HTTP, not over WS).
- **`/vm.m_enable_pkg` messages.** Mainnet runs `code_submission_policy = "inert"`,
  so an added package stays parked until an approver sends `MsgEnablePackage`.
  Those messages are in the export, but the extractor's pinned gno dependency
  predates the type and logs `unrecognized concrete type full name
  vm.m_enable_pkg`, skipping the transaction. Non-fatal (the extractor still
  exits 0, and `m_enable_pkg` carries no package source, so nothing is missing
  from `extracted/`) but noisy — it needs a dependency bump in `extractor/go.mod`.

### CI

- `.github/workflows/txs-exporter.yml` — runs every 4 hours for mainnet.gno.land and onyx.gno.land
- `.github/workflows/staging-txs-exporter.yml` — runs daily at 18:00 UTC for staging.gno.land

Both workflows auto-commit updated backup files using `git-auto-commit-action`.

## Key external tools (from the gno monorepo)

| Tool         | Location in gno repo   | Role here                                   |
| ------------ | ---------------------- | ------------------------------------------- |
| `tx-archive` | `contribs/tx-archive`  | Powers `make fetch` / `make fetch-all`      |
| `gnogenesis` | `contribs/gnogenesis`  | Used by `staging.gno.land/export.sh`        |
| `gnoland`    | `gno.land/cmd/gnoland` | The chain node (not used directly here)     |
| `gnokey`     | `gno.land/cmd/gnokey`  | Key management (addresses are `g1…` bech32) |
