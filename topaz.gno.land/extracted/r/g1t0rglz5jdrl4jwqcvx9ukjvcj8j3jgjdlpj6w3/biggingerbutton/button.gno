// Package biggingerbutton is "LordGs big Ginger BUTTon" — a hot-potato
// game for gno.land. Anyone can press the button by sending a small amount
// of GNOT. Each press resets the countdown. If the countdown ever reaches
// zero, the LAST person who pressed wins the whole pot.
//
// Safety rules baked into the code:
//   - Coins only ever move two ways: into the pot on Press, out to the
//     winner on settlement. There is no owner withdrawal and no admin.
//   - Settlement is permissionless: once the timer expires, ANYONE can
//     trigger the payout with Claim(). Coins can never be locked behind
//     a single person's inaction.
//   - A Press after expiry auto-settles the old round first, so pressing
//     late never loses the previous winner's pot.
package biggingerbutton

import (
	"chain"
	"chain/banker"
	"chain/runtime/unsafe"
	"strings"
	"time"

	"gno.land/p/nt/ufmt/v0"
)

// Game configuration.
var (
	// pressWindow is how long the countdown lasts after each press.
	// It is a var (not a const) only so tests can shorten/expire it;
	// on-chain it stays at 24 hours.
	pressWindow = 24 * time.Hour
	// minPressUgnot is the minimum press fee: 0.1 GNOT.
	minPressUgnot int64 = 100_000
)

// Round state.
var (
	round        int            // current round number (0 = no round played yet)
	active       bool           // a round is running right now
	holder       address        // last presser
	deadline     time.Time      // when the countdown hits zero
	pot          int64          // ugnot currently at stake
	totalPresses int            // presses in the current round
	presses      map[string]int // lifetime presses per address
	lastWinner   address
	lastPot      int64
	lastRound    int
)

// Press the big ginger button. Send at least minPressUgnot ugnot with the
// call. The presser becomes the holder and the countdown resets to 24h.
// If the previous round already expired, it is settled first (previous
// holder gets paid) and a new round starts with this press.
func Press(cur realm) {
	// Origin calls only: no intermediary realm may press on a user's
	// behalf (it would become the holder and could steal the pot).
	require(cur.Previous().IsUser(), "Press from a user wallet only, no intermediary realms.")
	caller := cur.Previous().Address()
	sent := unsafe.OriginSend()
	amount := int64(sent.AmountOf("ugnot"))
	require(len(sent) == 1 && amount >= minPressUgnot,
		ufmt.Sprintf("Press needs at least %d ugnot (0.1 GNOT), nothing else.", minPressUgnot))

	now := time.Now()
	settleIfExpired(cur, now)

	if !active {
		round++
		totalPresses = 0
		pot = 0
	}
	active = true
	holder = caller
	deadline = now.Add(pressWindow)
	pot += amount
	totalPresses++
	if presses == nil {
		presses = map[string]int{}
	}
	presses[caller.String()]++
}

// Claim pays the pot to the last presser once the countdown has reached
// zero. Anyone may call it — the payout always goes to the holder, never
// to the caller. If the timer has not expired yet, Claim panics.
func Claim(cur realm) {
	require(cur.Previous().IsUser(), "Claim from a user wallet only, no intermediary realms.")
	require(active, "No round is running. Press the button to start one!")
	now := time.Now()
	require(!now.Before(deadline),
		ufmt.Sprintf("Button is still hot! %s left on the clock.", formatDuration(deadline.Sub(now))))
	settle(cur)
}

// settleIfExpired pays out and resets the round if the deadline has passed.
func settleIfExpired(cur realm, now time.Time) {
	if active && !now.Before(deadline) {
		settle(cur)
	}
}

// settle sends the whole pot to the holder and closes the round.
// This is the ONLY place coins leave the realm.
func settle(cur realm) {
	winner := holder
	winnings := pot
	lastWinner = winner
	lastPot = winnings
	lastRound = round
	active = false
	holder = ""
	deadline = time.Time{}
	pot = 0
	totalPresses = 0

	if winnings > 0 {
		b := banker.NewBanker(banker.BankerTypeRealmSend, cur)
		b.SendCoins(cur.Address(), winner, chain.Coins{{"ugnot", winnings}})
	}
}

// --- read-only helpers (usable via query/eval) ---

// Pot returns the current pot in ugnot.
func Pot() int64 { return pot }

// Round returns the current round number.
func Round() int { return round }

// Holder returns the address of the last presser (empty if no round).
func Holder() address { return holder }

// IsActive reports whether a round is currently running.
func IsActive() bool { return active }

// TimeLeft returns seconds left on the countdown (0 if expired/inactive).
func TimeLeft() int64 {
	if !active {
		return 0
	}
	s := int64(time.Until(deadline).Seconds())
	if s < 0 {
		return 0
	}
	return s
}

// TotalPresses returns the number of presses in the current round.
func TotalPresses() int { return totalPresses }

// LastWinner returns winner and pot of the last settled round.
func LastWinner() (address, int64, int) { return lastWinner, lastPot, lastRound }

// --- rendering ---

// Render implements the gnoweb-facing markdown page.
func Render(path string) string {
	if path != "" {
		return "404 — try the home page."
	}
	var sb strings.Builder
	sb.WriteString("# LordGs big Ginger BUTTon\n\n")
	sb.WriteString("```\n")
	sb.WriteString("        .-\"\"\"\"\"-.\n")
	sb.WriteString("       /  GINGER  \\\n")
	sb.WriteString("      |   ______   |\n")
	sb.WriteString("      |  ( STOP )  |\n")
	sb.WriteString("      |  (  OR  )  |\n")
	sb.WriteString("      |  (  GO! )  |\n")
	sb.WriteString("       \\  BUTTON /\n")
	sb.WriteString("        '-......-'\n")
	sb.WriteString("```\n\n")

	sb.WriteString("## How to play (super simple)\n\n")
	sb.WriteString("1. **Press the button.** Call `Press()` and attach at least **0.1 GNOT**.\n")
	sb.WriteString("2. **The 24 hour countdown resets** and your address becomes the holder.\n")
	sb.WriteString("3. **If the countdown hits zero and you pressed last, you win the WHOLE pot.**\n")
	sb.WriteString("4. After it hits zero, anyone can call `Claim()` — the pot always goes to the last presser.\n\n")
	sb.WriteString("Every press adds your GNOT to the pot, so the longer the game runs, the bigger the prize.\n\n")

	sb.WriteString("## Game status\n\n")
	now := time.Now()
	if active {
		if now.Before(deadline) {
			sb.WriteString(ufmt.Sprintf("- Round: **%d**\n", round))
			sb.WriteString(ufmt.Sprintf("- Time left: **%s**\n", formatDuration(deadline.Sub(now))))
			sb.WriteString(ufmt.Sprintf("- Current holder (winning right now): `%s`\n", holder.String()))
			sb.WriteString(ufmt.Sprintf("- Pot: **%s GNOT**\n", formatGnot(pot)))
			sb.WriteString(ufmt.Sprintf("- Presses this round: **%d**\n", totalPresses))
			sb.WriteString("\nSomeone can still steal the pot — press the button before the clock runs out!\n")
		} else {
			sb.WriteString(ufmt.Sprintf("- Round **%d** is OVER — the countdown hit zero!\n", round))
			sb.WriteString(ufmt.Sprintf("- Winner: `%s`\n", holder.String()))
			sb.WriteString(ufmt.Sprintf("- Prize waiting: **%s GNOT**\n", formatGnot(pot)))
			sb.WriteString("\nCall `Claim()` to send the pot to the winner and clear the table.\n")
		}
	} else {
		sb.WriteString("The button is cold. Nobody is holding it.\n\n")
		sb.WriteString(ufmt.Sprintf("Be the first to press and start round %d!\n", round+1))
	}

	if lastPot > 0 {
		sb.WriteString("\n## Last round\n\n")
		sb.WriteString(ufmt.Sprintf("- Round %d winner: `%s`\n", lastRound, lastWinner.String()))
		sb.WriteString(ufmt.Sprintf("- Won: **%s GNOT**\n", formatGnot(lastPot)))
	}

	sb.WriteString("\n---\n")
	sb.WriteString("*All rules live in this realm's public source. Coins only ever move from pressers into the pot, and from the pot to the winner. No owner, no fees, no tricks.*\n")
	return sb.String()
}

// formatDuration renders d as "23h 59m 12s".
func formatDuration(d time.Duration) string {
	if d < 0 {
		d = 0
	}
	total := int64(d / time.Second)
	h := total / 3600
	m := (total % 3600) / 60
	s := total % 60
	return ufmt.Sprintf("%dh %dm %ds", h, m, s)
}

// formatGnot renders ugnot as a decimal GNOT string, e.g. 1234567 -> "1.234567".
func formatGnot(ugnot int64) string {
	whole := ugnot / 1_000_000
	frac := ugnot % 1_000_000
	if frac == 0 {
		return ufmt.Sprintf("%d", whole)
	}
	fs := ufmt.Sprintf("%06d", frac)
	for strings.HasSuffix(fs, "0") {
		fs = fs[:len(fs)-1]
	}
	return ufmt.Sprintf("%d.%s", whole, fs)
}

func require(cond bool, msg string) {
	if !cond {
		panic(msg)
	}
}
