package cutpurse

import (
	"chain"
	"chain/banker"
	"sort"
	"strconv"
	"strings"
)

// Tick is the only transition driver. Permissionless, any phase, no-op while
// the phase deadline is still open (§5, §6).
func Tick(cur realm, id int64) {
	if !cur.IsCurrent() {
		panic(ErrSpoofed)
	}
	j := mustJob(id)

	if j.Phase >= PhaseSettled {
		return
	}

	height := mustHeight()
	if height <= j.Deadline {
		return
	}

	switch j.Phase {
	case PhaseOpen:
		if j.NSeats >= 2 {
			j.Phase = PhaseCommit
			j.Round = 1
			j.Deadline = height + CommitBlocks
			return
		}
		// never filled: disband, everyone is refunded by Settle
		j.Phase = PhaseSettled
		j.Deadline = height
	case PhaseCommit:
		closeCommitRound(j)
	case PhaseReveal:
		closeRevealRound(j, true)
	}
}

// sealSeed is the deterministic seed from §6: it is a pure function of public
// data, so anyone can recompute it after the round closes.
func sealSeed(j *Job) string {
	hashes := make([]string, 0, Seats)
	for i := 0; i < int(j.NSeats); i++ {
		if j.Seats[i].Committed && j.Seats[i].CommitHash != "" {
			hashes = append(hashes, j.Seats[i].CommitHash)
		}
	}
	sort.Strings(hashes)

	return sha256Hex(j.Seed + "|" +
		strconv.FormatInt(j.ID, 10) + "|" +
		strconv.FormatInt(mustHeight(), 10) + "|" +
		strings.Join(hashes, ""))
}

// closeCommitRound ends the commit phase: silent seats fall back to Watch, the
// seed is sealed on round 1 and the snitch seat is drawn from it.
func closeCommitRound(j *Job) {
	for i := 0; i < int(j.NSeats); i++ {
		if !j.Seats[i].Committed {
			j.Seats[i].Action = ActWatch
			j.Seats[i].Auto = true
		}
	}

	if j.Round == 1 && j.Seed == "" {
		j.Seed = sealSeed(j)
		if j.NSeats > 0 {
			j.Traitor = int8(int64(j.Seed[0]) % int64(j.NSeats))
		}
	}

	j.Phase = PhaseReveal
	j.Deadline = mustHeight() + RevealBlocks
}

// closeRevealRound ends the reveal phase: silent seats fall back to Watch and,
// when the deadline forced the close, lose one reputation point.
func closeRevealRound(j *Job, penalize bool) {
	for i := 0; i < int(j.NSeats); i++ {
		if j.Seats[i].Action == ActNone {
			j.Seats[i].Action = ActWatch
			j.Seats[i].Auto = true
			if penalize {
				repDown(j.Seats[i].Addr)
			}
		}
	}
	resolveRound(j)
}

// resolveRound applies §6 exactly: alarm, secured, loot, contributions, then
// either terminal phase or the next round.
func resolveRound(j *Job) {
	n := int(j.NSeats)
	var np, nc, ns, nw int64

	for i := 0; i < n; i++ {
		switch j.Seats[i].Action {
		case ActPick:
			np++
		case ActCarry:
			nc++
		case ActScout:
			ns++
		case ActWatch:
			nw++
		}
	}

	j.Alarm += maxInt64(0, np-nw)
	j.Secured += 2 * nc
	loot := 3*np + 2*nc + 2*ns + nw
	if np == 0 && nw > 0 {
		loot += nw
	}
	j.Loot += loot

	for i := 0; i < n; i++ {
		switch j.Seats[i].Action {
		case ActPick, ActCarry:
			j.Seats[i].Contribution += 3
		case ActScout:
			j.Seats[i].Contribution += 2
		case ActWatch:
			j.Seats[i].Contribution += 1 + np
		}
	}

	if j.Alarm >= BustAlarm {
		j.Phase = PhaseBusted
		return
	}
	if j.Round >= Rounds {
		j.Phase = PhaseSettled
		return
	}

	j.Round++
	j.Phase = PhaseCommit
	j.Deadline = mustHeight() + CommitBlocks
	for i := 0; i < n; i++ {
		j.Seats[i].Committed = false
		j.Seats[i].CommitHash = ""
		j.Seats[i].Action = ActNone
		j.Seats[i].Auto = false
	}
}

// splitByContribution divides amount by accumulated contribution; the rounding
// dust goes to the top contributor, and an all-zero table splits equally.
func splitByContribution(j *Job, amount int64, pay *[Seats]int64) {
	n := int(j.NSeats)
	if amount <= 0 || n == 0 {
		return
	}

	var total int64
	top := 0
	for i := 0; i < n; i++ {
		c := j.Seats[i].Contribution
		if c < 0 {
			c = 0
		}
		total += c
		if c > j.Seats[top].Contribution {
			top = i
		}
	}

	if total == 0 {
		each := amount / int64(n)
		for i := 0; i < n; i++ {
			pay[i] += each
		}
		pay[0] += amount - each*int64(n)
		return
	}

	var given int64
	for i := 0; i < n; i++ {
		c := j.Seats[i].Contribution
		if c < 0 {
			c = 0
		}
		part := amount * c / total
		pay[i] += part
		given += part
	}
	if rest := amount - given; rest > 0 {
		pay[top] += rest
	}
}

func archiveResult(j *Job, pay *[Seats]int64) {
	r := &Result{
		JobID:  j.ID,
		Name:   j.Name,
		Busted: j.Phase == PhaseBusted,
		Loot:   j.Loot,
		At:     mustHeight(),
	}
	if j.Traitor >= 0 && int(j.Traitor) < int(j.NSeats) {
		r.Traitor = j.Seats[j.Traitor].Addr
	}

	parts := make([]string, 0, Seats)
	for i := 0; i < int(j.NSeats); i++ {
		if pay[i] > 0 {
			parts = append(parts, j.Seats[i].Addr.String()+":"+strconv.FormatInt(pay[i], 10))
		}
	}
	r.Payouts = strings.Join(parts, ",")

	for i := 0; i < int(j.NSeats); i++ {
		pushHist(j.Seats[i].Addr, *r)
	}

	ledger[ledgerHead] = r
	ledgerHead = (ledgerHead + 1) % LedgerMax
	if ledgerLen < LedgerMax {
		ledgerLen++
	}
}

// Settle pushes the single payout, archives the result and frees the seats.
// All state is written before any coin leaves the realm (§10 R4).
func Settle(cur realm, id int64) {
	if !cur.IsCurrent() {
		panic(ErrSpoofed)
	}
	j := mustJob(id)

	if j.SettledAt != 0 {
		panic(ErrAlreadySettled)
	}
	if j.Phase < PhaseSettled {
		panic(ErrNotReady)
	}

	n := int(j.NSeats)
	busted := j.Phase == PhaseBusted
	pay := [Seats]int64{}

	if n > 0 && j.Pot > 0 {
		if busted {
			share := j.Pot * TraitorBustShare / 100
			if j.Traitor >= 0 && int(j.Traitor) < n {
				pay[j.Traitor] = share
				splitByContribution(j, j.Pot-share, &pay)
			} else {
				splitByContribution(j, j.Pot, &pay)
			}
			j.Revealed = true
		} else {
			// §6 says cut = Secured*Bps/10000, but Secured counts 2 per carry
			// while the pot is in ugnot — the raw product rounds to zero at
			// MinFee. Scale Secured against the best possible secure
			// (2*Seats*Rounds) so the 5% is 5% of the pot, capped there.
			cut := j.Pot * j.Secured * TreasuryBps / (10000 * MaxSecured)
			if cut > j.Pot {
				cut = j.Pot
			}
			treasury += cut
			splitByContribution(j, j.Pot-cut, &pay)
		}
	}

	// --- state before coins ---
	height := mustHeight()
	j.SettledAt = height
	for i := 0; i < n; i++ {
		s := statFor(j.Seats[i].Addr)
		s.Jobs++
		if busted {
			s.Busts++
		} else {
			s.Escapes++
		}
		s.Loot += pay[i]
		if active[j.Seats[i].Addr] == j.ID {
			delete(active, j.Seats[i].Addr)
		}
	}
	archiveResult(j, &pay)
	if liveCount > 0 {
		liveCount--
	}
	purgeOld()

	// --- then coins ---
	realmAddr := cur.Address()
	bank := banker.NewBanker(banker.BankerTypeRealmSend, cur)
	for i := 0; i < n; i++ {
		if pay[i] > 0 {
			bank.SendCoins(realmAddr, j.Seats[i].Addr, chain.NewCoins(chain.NewCoin(Denom, pay[i])))
		}
	}
}
