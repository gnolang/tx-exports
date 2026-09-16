package probe2

import (
	campaign "gno.land/r/g1gn6t0q9wenwhdda47rkrpfd63kcxjvyp7eqwku/gems6v2/campaign"
)

func Render(path string) string {
	bps, _, ok := campaign.Peek("g1gn6t0q9wenwhdda47rkrpfd63kcxjvyp7eqwku")
	if ok && bps > 0 {
		return "x"
	}
	return ""
}
