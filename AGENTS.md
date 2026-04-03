# AGENTS.md

This file provides guidance to autonomous AI agents when working with code in this repository.

## Purpose

This repository archives raw blockchain transaction data exported from Gno.land test and live chains (test5.gno.land, staging.gno.land, and historical testnets test1–test4). It also contains Go tools that extract deployed Gno source code (packages and realms) from those backups.

## Common Commands

Each testnet directory has its own `Makefile` that includes `../rules.mk`. Run these from within the testnet directory (e.g., `cd test5.gno.land`):

```sh
make fetch        # Download new transactions from the chain RPC
make fetch-all    # Fetch all blocks in MAX_INTERVAL chunks up to current height
make stats        # Regenerate README.md statistics from backup files
make extractor    # Run the Go extractor to parse deployed packages/realms
make loop         # Continuous loop: fetch → stats → commit → push (for CI)
```

`staging.gno.land` uses a custom `export.sh` script instead of `make fetch` — the CI workflow calls it directly.

### Running the extractor

```sh
# From repo root
go run ./extractor --input-dir test5.gno.land --output-dir test5.gno.land/extracted
# For test4/test3 data (v0.1.1 Amino format):
go run ./extractor-0.1.1 --input-dir test4.gno.land --output-dir test4.gno.land/extracted
```

### tx-archive (the upstream backup tool)

The `make fetch` target invokes this tool at a pinned version:
```sh
go run github.com/gnolang/tx-archive/cmd@v0.4.2 backup \
  --remote <RPC_URL> --from-block <N> --to-block <M> --output backup_N-M.jsonl
```

## Architecture

### Directory layout

Each `<chain>.gno.land/` directory is self-contained:
- `Makefile` — sets `REMOTE`, `SHORTNAME`, `MAX_INTERVAL`, `FROM_BLOCK`, and includes `../rules.mk`
- `backup_*.jsonl` — exported transaction data, one JSON object per line, in block-number order
- `metadata.json` — tracks `latest_block_height` so incremental fetches know where to resume
- `README.md` — auto-generated stats (tx counts, top deployers, faucet requesters)
- `extracted/` — output of the extractor tool (Gno source files organised by package path)

### Transaction data format

**Current format** (test5, test2, test1 — post-test4 tx-archive):
```json
{"tx": {"msg": [...], "fee": {...}, "signatures": [...], "memo": ""}, "metadata": {"timestamp": "..."}}
```

**Legacy format** (staging, test4, test3 — plain `std.Tx`):
```json
{"msg": [...], "fee": {...}, "signatures": [...], "memo": ""}
```

Both use Amino JSON encoding (Tendermint2 wire format). The extractor versions correspond to these two formats — use `extractor-0.1.1` for legacy data.

### Transaction message types relevant to extraction

- `/vm.m_addpkg` (`MsgAddPackage`) — deploys a new package or realm; this is what the extractor captures
- `/vm.m_call` (`MsgCall`) — calls a function on an existing realm
- `/vm.m_run` (`MsgRun`) — executes ephemeral code
- `/bank.MsgSend` — token transfer

### Extractor

`extractor/main.go` reads `backup_*.jsonl`, filters for `MsgAddPackage` messages, and writes the embedded Gno source files to `extracted/p/` (libraries) or `extracted/r/` (stateful realms), mirroring the on-chain package path. A `pkg_metadata.json` beside each package records the deployer address and deposit.

**Known issue:** the current `extractor/` is broken for data produced after test4 due to a change in how `MsgAddPackage` is encoded. `extractor-0.1.1/` handles the older format correctly and is what CI uses for test3/test4.

### staging.gno.land specifics

Uses `export.sh` instead of tx-archive. It calls `gnogenesis txs export` and `gnogenesis balances export` against the Portal Loop RPC, chunks output into 1000-line JSONL segments, and downloads `genesis.json`. The CI workflow (`staging-txs-exporter.yml`) runs hourly.

### CI

- `.github/workflows/txs-exporter.yml` — runs every 4 hours for test5.gno.land
- `.github/workflows/staging-txs-exporter.yml` — runs hourly for staging.gno.land

Both workflows auto-commit updated backup files using `git-auto-commit-action`.

## Key external tools (from the gno monorepo)

| Tool | Location in gno repo | Role here |
|---|---|---|
| `tx-archive` | `contribs/tx-archive` | Powers `make fetch` / `make fetch-all` |
| `gnogenesis` | `contribs/gnogenesis` | Used by `staging.gno.land/export.sh` |
| `gnoland` | `gno.land/cmd/gnoland` | The chain node (not used directly here) |
| `gnokey` | `gno.land/cmd/gnokey` | Key management (addresses are `g1…` bech32) |
