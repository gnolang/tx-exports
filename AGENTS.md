# AGENTS.md

This file provides guidance to autonomous AI agents when working with code in this repository.

## Purpose

This repository archives raw blockchain transaction data exported from Gno.land chains:
- **Active**: test11.gno.land, gnoland1 (betanet), staging.gno.land
- **Historical**: test1–test5 (archived, no longer updated)

## Common Commands

Each chain directory has its own `Makefile` that includes `../rules.mk`. Run these from within the chain directory (e.g., `cd test11.gno.land`):

```sh
make fetch        # Download new transactions from the chain RPC
make fetch-all    # Fetch all blocks in MAX_INTERVAL chunks up to current height
make stats        # Regenerate README.md statistics from backup files
make extractor    # Run the Go extractor to parse deployed packages/realms
make loop         # Continuous loop: fetch → stats → commit → push (for CI)
```

`staging.gno.land` uses a custom `export.sh` script instead of `make fetch` — the CI workflow calls it directly.

### Running the backup tool directly

```sh
# Powered by tx-archive v0.5.1
go run github.com/gnolang/tx-archive/cmd@v0.5.1 backup \
  --remote <RPC_URL> --from-block <N> --to-block <M> --output-path backup_N-M.jsonl
```

### Running the extractor

```sh
# From repo root
go run ./extractor-0.1.1 --input-dir test11.gno.land --output-dir test11.gno.land/extracted
```

## Architecture

### Directory layout

Each chain directory is self-contained:
- `Makefile` — sets `REMOTE`, `SHORTNAME`, `MAX_INTERVAL`, and includes `../rules.mk`
- `backup_*.jsonl` — exported transaction data, one JSON object per line, in block-number order
- `metadata.json` — tracks `latest_block_height` so incremental fetches know where to resume
- `README.md` — auto-generated stats (tx counts, top deployers, faucet requesters)

### Transaction data format

**Current format** (test11, gnoland1, test5, test2, test1):
```json
{"tx": {"msg": [...], "fee": {...}, "signatures": [...], "memo": ""}, "metadata": {"timestamp": "..."}}
```

**Legacy format** (staging, test4, test3 — plain `std.Tx`):
```json
{"msg": [...], "fee": {...}, "signatures": [...], "memo": ""}
```

Both use Amino JSON encoding (Tendermint2 wire format).

### Transaction message types relevant to extraction

- `/vm.m_addpkg` (`MsgAddPackage`) — deploys a new package or realm
- `/vm.m_call` (`MsgCall`) — calls a function on an existing realm
- `/vm.m_run` (`MsgRun`) — executes ephemeral code
- `/bank.MsgSend` — token transfer

### staging.gno.land specifics

Uses `export.sh` instead of tx-archive. It calls `gnogenesis txs export` and `gnogenesis balances export` against the Portal Loop RPC, chunks output into 1000-line JSONL segments, and downloads `genesis.json`. The CI workflow (`staging-txs-exporter.yml`) runs hourly.

### CI

- `.github/workflows/txs-exporter.yml` — runs every 4 hours for test11.gno.land and gnoland1
- `.github/workflows/staging-txs-exporter.yml` — runs hourly for staging.gno.land

Both workflows auto-commit updated backup files using `git-auto-commit-action`.

## Key external tools (from the gno monorepo)

| Tool | Location in gno repo | Role here |
|---|---|---|
| `tx-archive` | `contribs/tx-archive` | Powers `make fetch` / `make fetch-all` |
| `gnogenesis` | `contribs/gnogenesis` | Used by `staging.gno.land/export.sh` |
| `gnoland` | `gno.land/cmd/gnoland` | The chain node (not used directly here) |
| `gnokey` | `gno.land/cmd/gnokey` | Key management (addresses are `g1…` bech32) |
