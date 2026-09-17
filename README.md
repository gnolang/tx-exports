# tx exports

This repository archives raw blockchain transaction data from Gno.land chains.

## Active chains (backed up continuously)

| Chain                                                   | Directory            | Frequency        |
| ------------------------------------------------------- | -------------------- | ---------------- |
| [gno.land (mainnet)](https://gno.land)                  | `mainnet.gno.land/`  | every 4 hours    |
| [pearl.gno.land (test16)](https://pearl.gno.land)       | `pearl.gno.land/`    | every 4 hours    |
| [staging.gno.land](https://staging.gno.land)            | `staging.gno.land/`  | daily, 18:00 UTC |

> **`gnoland1` is not `gnoland-1`.** Without the dash it is the retired betanet,
> archived under `gnoland1/`. With the dash it is mainnet, archived under
> `mainnet.gno.land/`. Two different chains — check which directory you are in.

## Historical chains (archived, no longer updated)

- `gnoland1/` — betanet (chain id `gnoland1`), halted at block 3796411 on 2026-09-14
- `sapphire.gno.land/` — sapphire.gno.land (test15)
- `topaz.gno.land/` — topaz.gno.land (test14)
- `test13.gno.land/` — test13.gno.land
- `test11.gno.land/` — test11.gno.land
- `test5.gno.land/` — test5.gno.land
- `test4.gno.land/` — test4.gno.land
- `test3.gno.land/` — test3.gno.land
- `test2.gno.land/` — test2.gno.land
- `test1.gno.land/` — test1.gno.land

## Known gaps

These networks were deployed but have never been exported here. They are shut
down with no reachable RPC, so the data can now only come from a node data
directory or an operator snapshot:

`test6.gno.land`, `test7.gno.land`, `test8.gno.land`, `test9.gno.land`,
`test10.gno.land`, `test12.gno.land`

Their genesis and node configuration are preserved in the monorepo under
[`misc/deployments/`](https://github.com/gnolang/gno/tree/master/misc/deployments).

## Tools

- **`rules.mk`** — shared Makefile rules used by all chain directories (`fetch`, `stats`, `loop`)
- Backup is powered by [tx-archive](https://github.com/gnolang/gno/tree/master/contribs/tx-archive) (lives in the `gnolang/gno` monorepo)
- `staging.gno.land/export.sh` — custom export script using `gnogenesis` (Portal Loop has no standard RPC tx export)
