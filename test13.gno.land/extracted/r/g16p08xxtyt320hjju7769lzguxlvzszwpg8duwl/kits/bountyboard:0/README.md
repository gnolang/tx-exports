# Kit: Bounty Board

Post / fund / release / refund bounties using the escrow state machine.

## Important

v0 tracks **state + amounts as metadata**. It does **not** move coins yet.
Fork and integrate `std.Banker` / send patterns when your target network has stable transfers.

## Functions

| Function | Who | Description |
|----------|-----|-------------|
| `InitBoard(title)` | first caller | Bootstrap |
| `PostBounty(worker, amountUgnot, title)` | client | Open deal |
| `FundBounty(id)` | client | Open → Funded |
| `ReleaseBounty(id)` | client | Funded → Released |
| `RefundBounty(id)` | client | Funded → Refunded |
| `CancelBounty(id)` | client/worker | Cancel open |
| `DisputeBounty(id)` | client/worker | Flag dispute |
