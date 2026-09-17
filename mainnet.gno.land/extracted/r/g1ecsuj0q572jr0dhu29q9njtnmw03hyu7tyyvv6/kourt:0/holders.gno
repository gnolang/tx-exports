package kourt
const topHoldersMax = 50
func HolderCount(courtSlug string) int {
	c := mustCourt(courtSlug)
	esc := c.escrow
	n := 0
	c.coin.WalkAccounts(func(who address, bal int64) bool {
		if bal > 0 && who != esc {
			n++
		}
		return false
	})
	return n
}
func TopHolders(courtSlug string, limit int) string {
	if limit <= 0 || limit > topHoldersMax {
		limit = topHoldersMax
	}
	c := mustCourt(courtSlug)
	esc := c.escrow
	who := make([]address, 0, limit)
	bal := make([]int64, 0, limit)
	c.coin.WalkAccounts(func(a address, b int64) bool {
		if b <= 0 || a == esc {
			return false
		}
		pos := len(who)
		for pos > 0 && b > bal[pos-1] {
			pos--
		}
		if pos >= limit {
			return false
		}
		if len(who) < limit {
			who = append(who, address(""))
			bal = append(bal, 0)
		}
		for i := len(who) - 1; i > pos; i-- {
			who[i], bal[i] = who[i-1], bal[i-1]
		}
		who[pos], bal[pos] = a, b
		return false
	})
	out := ""
	for i := range who {
		if bal[i] <= 0 {
			continue
		}
		out += ";" + string(who[i]) + ":" + itoa(bal[i])
	}
	if out == "" {
		return ""
	}
	return out[1:]
}
func TopHoldersNote() string {
	return "Ranked by coin held. Coin staked on a claim sits in the court's custody until the claim resolves, so it is not counted here."
}
