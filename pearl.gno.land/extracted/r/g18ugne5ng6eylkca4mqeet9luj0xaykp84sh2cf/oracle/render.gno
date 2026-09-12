package oracle

import "strconv"

func Render(_ string) string {
	out := "# Lend oracle v1\n\n"
	out += "Fail-closed quote registry. **No credit-grade quotes.** "
	out += "Liquidation must call `RequireCredit` and will panic until a future feed assigns `GradeOracle`.\n\n"
	out += "- admin: `" + admin.String() + "`\n"
	out += "- feeds: " + strconv.Itoa(len(feeds)) + "/" + strconv.Itoa(maxFeeds) + "\n\n"
	if len(feeds) == 0 {
		out += "_No feeds._\n"
		return out
	}
	out += "| pair | tick | window | maxAge | grade |\n|---|---|---|---|---|\n"
	for i := 0; i < len(feeds); i++ {
		f := feeds[i]
		q := Consult(f.pair)
		out += "| `" + f.pair + "` | " + strconv.Itoa(int(f.tick)) +
			" | " + strconv.Itoa(int(f.windowSec)) +
			" | " + strconv.Itoa(int(f.maxAgeSec)) +
			" | " + q.Grade().String() + " |\n"
	}
	return out
}
