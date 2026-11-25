# grc1155 — a GRC1155-compatible multi-token package for Gno.land

`gno.land/p/g1j9c3manpp89kdyhjjqqyugty70kjy5w4sw9y0m/grc1155/v0` is a
multi-token (ERC1155-style) token package for Gno.land realms. One `Token`
issues many `TokenID`s, each with its own balance, total supply, and optional
URI override, and movements go through capability `Teller`s rather than raw
caller identity — the same security model as `gno.land/p/nt/grc721/v0`,
extended to batches.

## Why not the quarantined `p/nt/grc1155`

`examples/quarantined/gno.land/p/nt/grc1155/v0` (issue gnolang/gno#6202) had
five gaps. This package fixes each:

| # | Quarantined gap | Fix here |
|---|---|---|
| 1 | Events were constructed then dropped | Every state change emits via `chain.Emit`: `NewToken`, `TransferSingle`, `TransferBatch`, `ApprovalForAll`, `URI` |
| 2 | "Safe" receiver checks were `return true` stubs | `safeTransferFrom`/`safeBatchTransferFrom` are deliberately omitted — a receiver-acceptance check needs a registry, and aliasing it would imply false safety |
| 3 | Authorised with `unsafe.OriginCaller()`, so any realm a user called could move their tokens | Writes resolve the actor per frame (`cur.Previous()` via `CallerTeller`) and `guardHome` confines frame-relative tellers to the token's own realm; a leaked `CallerTeller` returns `ErrForeignCallerTeller` abroad |
| 4 | Impl type unexported, could not be extended | `Token` is exported with unexported fields; realms compose through `Teller`, `PrivateLedger`, and the `Extension` hook interface |
| 5 | One global URI, no per-token supply or enumeration | Per-token `TotalSupply(tid)`, `Exists(tid)`, `URI(tid)` (per-id override over a `{id}` template), `HoldingsOf`, `TokenIDs` |

## Usage in a realm

```go
package forge

import (
	"gno.land/p/g1j9c3manpp89kdyhjjqqyugty70kjy5w4sw9y0m/grc1155/v0"
)

var (
	token     *grc1155.Token
	ledger    *grc1155.PrivateLedger
	userTeller grc1155.Teller
)

func init(cur realm) {
	token, ledger = grc1155.NewToken("Tavern Forge", "FORGE",
		"/r/g1j9c3manpp89kdyhjjqqyugty70kjy5w4sw9y0m/forge/v0:item/{id}", 0, cur)
	userTeller = ledger.CallerTeller()
}

// Crossing wrappers hand the frame's cur to the teller; the teller resolves
// the acting account as cur.Previous() and is home-guarded.
func Transfer(cur realm, to address, tid grc1155.TokenID, amount int64) error {
	return userTeller.TransferFrom(0, cur, cur.Previous().Address(), to, tid, amount)
}
```

Issuer-side operations (`Mint`, `MintBatch`, `Burn`, `BurnBatch`,
`SetURI`, `SetDefaultURI`, `RegisterExtension`) live on `*PrivateLedger`,
which only the creating realm ever holds. Holder-side operations go through
a `Teller`: `CallerTeller` (per-caller, home-guarded), `ReadonlyTeller`
(reads only), `RealmTeller`/`RealmSubTeller` (bound to the calling realm's
own address), and `ImpersonateTeller` (admin-grade, ledger-holder only).

Two identity details worth knowing before building on the package:

- `Token.ID()` is `pkgPath + "." + symbol` with no per-creation
  discriminator — a realm must not create two tokens with the same symbol,
  or their IDs collide in indexers and registries.
- `URI(tid)` substitutes `{id}` on-chain with the raw `TokenID` string,
  unlike EIP-1155 where clients fill in a 64-hex id themselves. Ids outside
  the write-path charset (`[A-Za-z0-9_.-]`) make `URI` return `""` rather
  than echoing unvalidated input.

## Events

Every state change emits via `chain.Emit`. `TransferSingle`/`TransferBatch`
carry EIP-1155 attributes — `token`, `operator`, `from`, `to`, `id`/`ids`,
`value`/`values` (batch ids and values comma-joined). `operator` is the
spender for `TransferFrom`/`BatchTransferFrom` and empty for mint/burn,
which have no spender. `Mint`/`MintBatch` emit with empty `from`,
`Burn`/`BurnBatch` with empty `to`. `ApprovalForAll` uses `owner`/`to`/
`approved`; `URI` carries `id` for per-token overrides and omits it for
the default template. A batch that returns an error emits nothing.

## Deliberate omissions

- **No `Safe*` functions.** EIP-1155's receiver-acceptance check
  (`onERC1155Received`) needs a registry of receiver contracts; providing a
  "safe" alias without one would imply safety that does not exist.
- **No per-token approvals.** EIP-1155 has none either — operator approval
  (`SetApprovalForAll`) covers all token ids.

## Import footprint

Deployed imports: `gno.land/p/nt/avl/v0` plus stdlibs (`chain`,
`math/overflow`, `strconv`, `strings`, `errors`). No `ufmt`, no `seqid`, no
other `/p/` or `/r/` packages — the transitive closure stays minimal so
chain-level package approval stays cheap.
