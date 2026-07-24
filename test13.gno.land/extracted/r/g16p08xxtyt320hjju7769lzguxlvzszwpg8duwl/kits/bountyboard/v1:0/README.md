# Kit: Bounty Board (hardened escrow)

Post / fund / release / refund bounties with **real ugnot** movement via `chain/banker`.

## Coin flow

| Action | Who | Coins |
|--------|-----|--------|
| `PostBounty` | client | none |
| `FundBounty` | client | must `-send` ≥ amount ugnot; locked in realm |
| `ReleaseBounty` | client | realm → worker |
| `RefundBounty` | client | realm → client |
| `TimeoutRefundBounty` | **anyone** after deadline | realm → client |
| `CancelBounty` | client/worker | only while open |
| `DisputeBounty` | client/worker | funds stay locked (v0) |

## Init

```text
InitBoard(title)
SetTimeoutSecs(secs)   # admin; default 7 days
```

## Security notes

- `FundBounty` / `ReleaseBounty` / `RefundBounty` use `runtime.AssertOriginCall()` (EOA only).
- Underfunding panics in `escrow.MarkFunded` — no silent partial fund.
- Timeout is permissionless by design (liveness over griefing lock-up).
