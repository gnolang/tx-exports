# guard

The one-line checks Assayer's rules ask for. Each helper panics with a short,
stable message when the check fails.

| Rule | Helper |
|---|---|
| AS-S01, AS-S02, AS-S06 | `OnlyOwner(caller, owner)`, `OnlyOneOf(caller, allowed...)` |
| AS-S03 | `SafeSub(balance, amount)`, `SafeAdd(a, b)` |
| AS-S09 | `RequireValidAddr(addr, "to")` |
| AS-T02 | `RequireMaxLen(s, max, "body")`, `RequireNonEmpty(s, "body")` |
| AS-T04 | `RequireMaxItems(len(ids), max, "ids")` |
| deposits | `RequirePositive(amount, "amount")` |

```go
func Withdraw(cur realm, to address, amount int64) {
	caller := cur.Previous().Address()
	guard.RequireValidAddr(to, "to")
	balances.Set(caller.String(), guard.SafeSub(balanceOf(caller), amount))
	// …
}
```
