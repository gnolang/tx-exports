package bubble

import (
	"strconv"
	"strings"
)

// Render: "" the front page (the token's figures, then the governor's page); "gov/…" the governor's pages alone;
// "json" the figures for the box; "me/<addr>" one holder's balance and votes.
func Render(path string) string {
	path = strings.Trim(path, "/")
	switch {
	case path == "json":
		return jsonAll()
	case strings.HasPrefix(path, "me/"):
		a := address(path[3:])
		return "{\"addr\":\"" + a.String() + "\",\"balance\":" + itoa(ledger.BalanceOf(a)) + ",\"votes\":" + itoa(ledger.VotesOf(a)) +
			",\"delegate\":\"" + ledger.DelegateOf(a).String() + "\"}"
	case strings.HasPrefix(path, "gov"):
		return engine.Render(strings.TrimPrefix(strings.TrimPrefix(path, "gov"), "/"), notes())
	default:
		return engine.Render(path, notes())
	}
}

// notes are this realm's lines on the governor's front page: the figures the engine cannot know.
func notes() string {
	var b strings.Builder
	b.WriteString("- supply: " + whole(ledger.TotalSupply()) + " of " + whole(MaxSupply) + " BUBBLE (premine " + whole(premined) +
		", referrals " + whole(referralMinted) + " of " + whole(ReferralPool) + ", reserve " + whole(reserveMinted) + " of " + whole(Reserve) + ")\n")
	minted, ceiling := MintedToday()
	b.WriteString("- today: " + whole(minted) + " of " + whole(ceiling) + " BUBBLE minted; batches " + itoa(batches) + "\n")
	if admin == "" {
		b.WriteString("- **the admin is gone** — every setting moves by vote\n")
	} else {
		b.WriteString("- admin: " + admin.String() + "\n")
	}
	if minter == "" {
		b.WriteString("- **nobody mints** — the holders can name a minter\n")
	} else {
		b.WriteString("- minter: " + minter.String() + (map[bool]string{true: " (paused)", false: ""})[paused] + "\n")
	}
	b.WriteString("- a money vote's turnout bar follows the holders: a fifth of the supply, or the mean turnout of the last money votes when that is higher (mean now " + whole(meanTurnout()) + "), never above a third; the reserve moves at most " + whole(ReserveMaxPer) + " a proposal, ninety days apart\n")
	return b.String()
}

func jsonAll() string {
	minted, ceiling := MintedToday()
	return "{\"name\":\"" + tokenName + "\",\"symbol\":\"" + tokenSymbol + "\",\"decimals\":" + strconv.Itoa(tokenDecimals) +
		",\"supply\":" + itoa(ledger.TotalSupply()) + ",\"max\":" + itoa(MaxSupply) + ",\"premine\":" + itoa(premined) +
		",\"referralMinted\":" + itoa(referralMinted) + ",\"referralPool\":" + itoa(ReferralPool) +
		",\"reserveMinted\":" + itoa(reserveMinted) + ",\"reserve\":" + itoa(Reserve) +
		",\"dayCap\":" + itoa(ceiling) + ",\"mintedToday\":" + itoa(minted) + ",\"day\":" + itoa(dayOf()) +
		",\"paused\":" + strconv.FormatBool(paused) + ",\"admin\":\"" + admin.String() + "\",\"minter\":\"" + minter.String() +
		"\",\"lastBatch\":\"" + lastBatch + "\",\"batches\":" + itoa(batches) + ",\"epoch\":" + strconv.FormatUint(uint64(ledger.Epoch()), 10) +
		",\"height\":" + itoa(ledger.Height()) + ",\"now\":" + itoa(ledger.Now()) + "}"
}

func itoa(n int64) string { return strconv.FormatInt(n, 10) }
