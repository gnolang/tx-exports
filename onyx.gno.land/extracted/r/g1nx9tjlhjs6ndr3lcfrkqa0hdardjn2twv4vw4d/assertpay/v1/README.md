# assertpay

Pay on pass: a sponsor funds a task on a spec (an interface and tests in a
/p/ package); the earliest-committed implementation that passes is paid
after a challenge window in which anyone can break it with a seed and take
its bond.

Calls (all from a wallet, except Reveal):

- `Fund(spec, deadlineBlocks, windowBlocks)` with the reward attached.
- `Commit(task, hash)` with the bond; `hash = HashFor(task, you, entryRealm, salt)`.
- `Reveal(task, salt, impl)` from your entry realm, within 600 blocks.
- `Challenge(task, seed)`; `OpenChallenge(task, seed)` with a bond, then anyone `RunChallenge(task)`, or `TimeoutChallenge(task)` after the grace period.
- `Claim(task)` after the window; `Refund(task)` after the deadline with nothing pending.

Pages: `:` home, `:spec/<name>?seed=N` (walletless run of a known-bad
implementation), `:task/<id>`, `:json/task/<id>`. Task logic is in
`p/.../assertpay/market/v1`; the harness is `p/.../assertpay/check/v1`.
No admin key.
