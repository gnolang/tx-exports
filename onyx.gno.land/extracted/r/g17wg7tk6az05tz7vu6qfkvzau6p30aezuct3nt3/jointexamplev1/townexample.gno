package jointexamplev1

import (
	"strings"

	"gno.land/p/nt/ufmt/v0"
	town "gno.land/r/g17wg7tk6az05tz7vu6qfkvzau6p30aezuct3nt3/jointv1"
)

// Render is a small supplier dashboard that only reads the town realm.
// It shows the four market prices. A bech32 address, or tavern/<address>,
// says whether that pub's menu price is above, below or equal to the ale
// market. A farm is not a pub. Nothing here is written and no coins move.
func Render(path string) string {
	s := "# Supplier dashboard\n\n"
	goods := []int{town.GoodAle, town.GoodGrain, town.GoodHops, town.GoodMead}
	names := []string{"ale", "grain", "hops", "mead"}
	for i := 0; i < len(goods); i++ {
		s += ufmt.Sprintf("%s %d\n", names[i], town.GoodPriceCg(goods[i]))
	}
	addr := path
	if strings.HasPrefix(path, "tavern/") {
		addr = path[len("tavern/"):]
	}
	if !looksAddr(addr) {
		return s
	}
	t := town.GetTavern(addr)
	if t == nil {
		s += "No joint at this address.\n"
		return s
	}
	if t.Role != town.RolePub {
		s += "not a pub\n"
		return s
	}
	ale := town.GoodPriceCg(town.GoodAle)
	s += ufmt.Sprintf("menu %d cg, ale market %d cg: ", t.PriceCg, ale)
	switch {
	case t.PriceCg > ale:
		s += "above\n"
	case t.PriceCg < ale:
		s += "below\n"
	default:
		s += "equal\n"
	}
	return s
}

// looksAddr is a shape check (g1…, lowercase), not a checksum check.
func looksAddr(s string) bool {
	if len(s) < 39 || len(s) > 45 || s[0] != 'g' || s[1] != '1' {
		return false
	}
	for i := 0; i < len(s); i++ {
		c := s[i]
		if (c < '0' || c > '9') && (c < 'a' || c > 'z') {
			return false
		}
	}
	return true
}
