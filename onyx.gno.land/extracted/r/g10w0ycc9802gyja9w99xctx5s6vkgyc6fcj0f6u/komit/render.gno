package komit

import (
	"strconv"
	"strings"
)

// fmtGNOT renders a ugnot amount as a GNOT string, e.g. 5500000 -> "5.5 GNOT".
func fmtGNOT(ugnot int64) string {
	whole := ugnot / 1_000_000
	frac := ugnot % 1_000_000
	if frac == 0 {
		return strconv.FormatInt(whole, 10) + " GNOT"
	}
	fracStr := strconv.FormatInt(frac+1_000_000, 10)[1:] // zero-padded 6 digits
	fracStr = strings.TrimRight(fracStr, "0")
	return strconv.FormatInt(whole, 10) + "." + fracStr + " GNOT"
}

// sortedActive returns the active challenges ordered by streak (desc),
// then by stake (desc). Insertion sort; the set is small.
func sortedActive() []*Challenge {
	list := make([]*Challenge, 0, len(activeByOwner))
	for _, c := range activeByOwner {
		list = append(list, c)
	}
	for i := 1; i < len(list); i++ {
		for j := i; j > 0; j-- {
			a, b := list[j-1], list[j]
			if b.Streak > a.Streak || (b.Streak == a.Streak && b.Stake > a.Stake) {
				list[j-1], list[j] = b, a
			} else {
				break
			}
		}
	}
	return list
}

// Render is the realm's public gnoweb page.
func Render(path string) string {
	var sb strings.Builder

	sb.WriteString("# Komit — stake-backed habit streaks\n\n")
	sb.WriteString("Put testnet GNOT where your mouth is. Lock a stake, pick a habit, and check in **every UTC day**. ")
	sb.WriteString("Miss a day and your stake is forfeited into a shared reward pool. Finish your streak and you claim your stake back **plus a bonus of up to the same amount again**, paid from the pool.\n\n")
	sb.WriteString("No admin can touch the stakes or the pool — coins leave this realm only through `Claim`, only to the challenge owner.\n\n")

	sb.WriteString("## Live stats\n\n")
	sb.WriteString("| | |\n|---|---|\n")
	sb.WriteString("| Active challenges | " + strconv.Itoa(len(activeByOwner)) + " |\n")
	sb.WriteString("| Currently staked | " + fmtGNOT(activeStaked) + " |\n")
	sb.WriteString("| Reward pool | " + fmtGNOT(poolBalance) + " |\n")
	sb.WriteString("| Completed challenges | " + strconv.Itoa(completedCount) + " |\n")
	sb.WriteString("| Broken challenges | " + strconv.Itoa(failedCount) + " |\n")
	sb.WriteString("| Staked all-time | " + fmtGNOT(totalStaked) + " |\n\n")

	sb.WriteString("## Leaderboard — current streaks\n\n")
	list := sortedActive()
	if len(list) == 0 {
		sb.WriteString("No active challenges yet. Be the first.\n\n")
	} else {
		sb.WriteString("| # | Address | Habit | Streak | Stake |\n|---|---|---|---|---|\n")
		limit := len(list)
		if limit > 20 {
			limit = 20
		}
		for i := 0; i < limit; i++ {
			c := list[i]
			sb.WriteString("| " + strconv.Itoa(i+1) + " | `" + c.Owner.String() + "` | " +
				c.Habit + " | " + strconv.Itoa(c.Streak) + "/" + strconv.Itoa(c.TargetDays) +
				" | " + fmtGNOT(c.Stake) + " |\n")
		}
		sb.WriteString("\n")
	}

	if len(finished) > 0 {
		sb.WriteString("## Recent results\n\n")
		sb.WriteString("| Address | Habit | Result | Final streak |\n|---|---|---|---|\n")
		from := len(finished) - 10
		if from < 0 {
			from = 0
		}
		for i := len(finished) - 1; i >= from; i-- {
			c := finished[i]
			result := "✅ completed"
			if c.Status == StatusFailed {
				result = "💔 broken"
			}
			sb.WriteString("| `" + c.Owner.String() + "` | " + c.Habit + " | " + result +
				" | " + strconv.Itoa(c.Streak) + "/" + strconv.Itoa(c.TargetDays) + " |\n")
		}
		sb.WriteString("\n")
	}

	sb.WriteString("## How it works\n\n")
	sb.WriteString("1. **Start** a challenge: choose a habit and a target of 3–90 consecutive days, and send a stake of 1–100 GNOT with the call. The realm locks it.\n")
	sb.WriteString("2. **Check in** once per UTC day — your first check-in is due the *same* UTC day you start. Each check-in extends your streak by one.\n")
	sb.WriteString("3. **Don't miss a day.** Breaks are evaluated lazily: the next time any state-changing function runs after a missed day, the challenge closes as failed and the stake moves into the reward pool.\n")
	sb.WriteString("4. **Claim** once your streak reaches the target — by the day after your last check-in at the latest. You receive your stake back plus a bonus of `min(reward pool, your stake)`, so up to 2x back while the pool lasts.\n")
	sb.WriteString("5. One active challenge per address. Starting a new one first breaks a stale old one (forfeiting its stake); a live one blocks the new start.\n\n")

	sb.WriteString("## Play from the command line\n\n")
	sb.WriteString("You need a key (`gnokey add mykey`), testnet GNOT from [faucet.gno.land](https://faucet.gno.land) (pick the Onyx testnet), and the commands below. Replace `mykey` with your key name.\n\n")

	sb.WriteString("Start a 7-day challenge with a 5 GNOT stake:\n\n")
	sb.WriteString("```\n")
	sb.WriteString("gnokey maketx call \\\n")
	sb.WriteString("  -pkgpath \"" + PkgPath + "\" \\\n")
	sb.WriteString("  -func \"StartChallenge\" -args \"Read 20 pages\" -args 7 \\\n")
	sb.WriteString("  -send 5000000ugnot \\\n")
	sb.WriteString("  -gas-fee 200000ugnot -gas-wanted 20000000 \\\n")
	sb.WriteString("  -chainid onyx-1 -remote https://rpc.onyx.testnets.gno.land:443 \\\n")
	sb.WriteString("  mykey\n```\n\n")

	sb.WriteString("Check in (once per UTC day):\n\n")
	sb.WriteString("```\n")
	sb.WriteString("gnokey maketx call \\\n")
	sb.WriteString("  -pkgpath \"" + PkgPath + "\" \\\n")
	sb.WriteString("  -func \"CheckIn\" \\\n")
	sb.WriteString("  -gas-fee 200000ugnot -gas-wanted 20000000 \\\n")
	sb.WriteString("  -chainid onyx-1 -remote https://rpc.onyx.testnets.gno.land:443 \\\n")
	sb.WriteString("  mykey\n```\n\n")

	sb.WriteString("Claim after reaching your target:\n\n")
	sb.WriteString("```\n")
	sb.WriteString("gnokey maketx call \\\n")
	sb.WriteString("  -pkgpath \"" + PkgPath + "\" \\\n")
	sb.WriteString("  -func \"Claim\" \\\n")
	sb.WriteString("  -gas-fee 200000ugnot -gas-wanted 20000000 \\\n")
	sb.WriteString("  -chainid onyx-1 -remote https://rpc.onyx.testnets.gno.land:443 \\\n")
	sb.WriteString("  mykey\n```\n\n")

	sb.WriteString("---\n\nKomit runs on the Gno.land Onyx testnet (`onyx-1`). Stakes are testnet tokens with no monetary value.\n")
	return sb.String()
}
