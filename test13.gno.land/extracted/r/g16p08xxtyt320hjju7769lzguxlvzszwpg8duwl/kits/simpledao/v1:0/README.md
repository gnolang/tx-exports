# Kit: Simple DAO

Minimal proposal + voting DAO with role-gated voters.

## Functions

| Function | Who | Description |
|----------|-----|-------------|
| `InitDAO(name, passThreshold)` | first caller | Bootstrap |
| `AddVoter(addr)` | admin | Grant vote rights |
| `Propose(title, description, action)` | voter | New proposal |
| `Vote(proposalID, support)` | voter | Yes/No once |
| `Finalize(proposalID)` | admin | Close active proposal |
| `MarkExecuted(proposalID)` | admin | Mark passed as done |

## Notes

- v0 threshold = absolute yes-count (not % of voters). Fork for quadratic / token voting.
- `Action` is metadata for off-chain or future on-chain executors.
