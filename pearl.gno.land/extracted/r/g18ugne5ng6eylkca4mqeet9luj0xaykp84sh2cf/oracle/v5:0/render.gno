package oracle

import (
	"strconv"

	poracle "gno.land/p/g18ugne5ng6eylkca4mqeet9luj0xaykp84sh2cf/oracle/v5"
)

func Render(_ string) string {
	out := "# Oracle\n\n"
	out += "Fail-closed USD quote registry. **Informational only. Not credit-grade.** "
	out += "`RequireCredit` / `RequireUsdCredit` panic until a future feed assigns `GradeOracle`.\n\n"
	out += "- admin: `" + admin.String() + "`\n"
	out += "- feeds: " + strconv.Itoa(len(feeds)) + "/" + strconv.Itoa(maxFeeds) + "\n\n"
	out += "## Manual ticks\n\n"
	if len(feeds) == 0 {
		out += "_No manual feeds._\n\n"
	} else {
		out += "| pair | tick | window | maxAge | grade |\n|---|---|---|---|---|\n"
		for i := 0; i < len(feeds); i++ {
			f := feeds[i]
			q := Consult(f.pair)
			out += "| `" + f.pair + "` | " + strconv.Itoa(int(f.tick)) +
				" | " + strconv.Itoa(int(f.windowSec)) +
				" | " + strconv.Itoa(int(f.maxAgeSec)) +
				" | " + q.Grade().String() + " |\n"
		}
		out += "\n"
	}
	out += "## USD push (external)\n\n"
	out += "micro-USD scale " + strconv.Itoa(int(poracle.UsdScale)) + ". Median of fresh publishers. **Informational only.**\n\n"
	if len(usdFeeds) == 0 {
		out += "_No USD feeds._\n"
		return out
	}
	out += "| symbol | pubs | minFresh | maxAge | maxDevBps | usdMicro | grade |\n|---|---|---|---|---|---|---|\n"
	for i := 0; i < len(usdFeeds); i++ {
		f := usdFeeds[i]
		u := ConsultUsd(f.symbol)
		out += "| `" + f.symbol + "` | " + strconv.Itoa(len(f.pubs)) +
			" | " + strconv.Itoa(f.minFresh) +
			" | " + strconv.Itoa(int(f.maxAgeSec)) +
			" | " + strconv.Itoa(int(f.maxDevBps)) +
			" | " + strconv.Itoa(int(u.UsdMicro())) +
			" | " + u.Grade().String() + " |\n"
	}
	out += "\n## USD publishers (last post)\n\n"
	out += "| symbol | publisher | usdMicro | observedAt |\n|---|---|---|---|\n"
	for i := 0; i < len(usdFeeds); i++ {
		sym := usdFeeds[i].symbol
		n := UsdPublisherCount(sym)
		for j := 0; j < n; j++ {
			who, micro, obs := UsdPublisherLast(sym, j)
			out += "| `" + sym + "` | `" + who.String() + "` | " +
				strconv.Itoa(int(micro)) + " | " +
				strconv.Itoa(int(obs)) + " |\n"
		}
	}
	return out
}
