# tx exports

This repository archives raw blockchain transaction data from Gno.land chains.

## Active chains (backed up continuously)

| Chain                                             | Directory           | Frequency     |
| ------------------------------------------------- | ------------------- | ------------- |
| [topaz.gno.land (test14)](https://topaz.gno.land) | `topaz.gno.land/`   | every 4 hours |
| [test13.gno.land](https://test13.gno.land)        | `test13.gno.land/`  | every 4 hours |
| [gnoland1 (betanet)](https://betanet.gno.land)    | `gnoland1/`         | every 4 hours |
| [staging.gno.land](https://staging.gno.land)      | `staging.gno.land/` | every hour    |

## Historical chains (archived, no longer updated)

- `test11.gno.land/` — test11.gno.land
- `test5.gno.land/` — test5.gno.land
- `test4.gno.land/` — test4.gno.land
- `test3.gno.land/` — test3.gno.land
- `test2.gno.land/` — test2.gno.land
- `test1.gno.land/` — test1.gno.land

## Tools

- **`rules.mk`** — shared Makefile rules used by all chain directories (`fetch`, `stats`, `loop`)
- Backup is powered by [tx-archive](https://github.com/gnolang/gno/tree/master/contribs/tx-archive) (lives in the `gnolang/gno` monorepo)
- `staging.gno.land/export.sh` — custom export script using `gnogenesis` (Portal Loop has no standard RPC tx export)
