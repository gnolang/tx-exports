// Package charter is a one-round-at-a-time capital escrow for a software project.
//
// A round is denominated in ugnot. Before the deadline a contributor can cancel
// and pull their own payment. At the deadline, a total below the soft cap lets
// each contributor pull their payment plus a pro-rata share of the bond. A total
// at or above the soft cap accepts payments pro-rata up to the hard cap and
// refunds the rest. There is no bonding curve and no first-come allocation.
//
// After a successful round the beneficiary can withdraw only tap*time, and only
// ugnot that contributors can no longer exit. Raising the tap waits out the
// delay frozen at open; the higher rate accrues only after that instant.
// A contributor who has not claimed tokens can exit the still-locked part of
// their own accepted ugnot. Claiming tokens forfeits that exit. Team tokens
// vest linearly to the beneficiary. Nothing in this realm can mint twice,
// shorten the delay, or send the pot to an arbitrary address.
package charter

import (
	"chain"
	"chain/banker"
	"chain/runtime/unsafe"
	"strconv"
	"strings"
	"time"

	"gno.land/p/g1n4pl5uc4yt5r96m9w6fmdznx3x0jyg8l6arhmt/charter/book"
	"gno.land/p/demo/tokens/grc20"
	"gno.land/p/nt/avl/v0"
	"gno.land/p/nt/markdown/sanitize/v0"
)

const (
	// MinBond is the ugnot the founder must attach to OpenRound (100 GNOT).
	MinBond int64 = 100000000
	// MaxTeamBps is the largest team share of the token supply, in bps.
	MaxTeamBps int64 = 4000
	// MinDelay is the shortest wait before a higher tap accrues.
	MinDelay int64 = 86400
	// MinVest is the shortest team vest.
	MinVest int64 = 86400
	// MaxHorizon bounds a deadline, delay, and vest (ten 365-day years).
	MaxHorizon int64 = 10 * 365 * 86400
	// MaxContributors bounds a single round so a withdraw can sum exit reservations.
	MaxContributors = 200

	stRaising = iota
	stLive
	stFailed
)

type account struct {
	paid           int64
	accepted       int64
	excess         int64
	units          int64
	refunded       bool
	excessRefunded bool
	exited         bool
	claimed        bool
}

type round struct {
	founder       address
	beneficiary   address
	name          string
	symbol        string
	soft          int64
	hard          int64
	price         int64
	deadline      int64
	delay         int64
	vest          int64
	teamBps       int64
	perCap        int64
	status        int
	raised        int64
	accepted      int64
	contributors  int
	t0            int64
	tap           int64
	accrued       int64
	mark          int64
	pendingTap    int64
	pendingAt     int64
	teamWithdrawn int64
	exitedUgnot   int64
	teamUnits     int64
	teamClaimed   int64
	bondReturned  bool
	token         *grc20.Token
	ledger        *grc20.PrivateLedger
	accounts      *avl.Tree
}

var (
	rounds  = avl.NewTree()
	symbols = avl.NewTree()
	nextID  int64
)

func resetForTest() {
	rounds = avl.NewTree()
	symbols = avl.NewTree()
	nextID = 0
}

// OpenRound freezes terms and takes exactly MinBond ugnot from the caller.
// The caller is the founder. The bond comes back to the founder only through
// ReturnBond, or to contributors through Refund when the round fails.
func OpenRound(cur realm, name, symbol string, beneficiary address, soft, hard, price, deadline, tapPerSecond, delay, vestDuration, teamBps, perAddressCap int64) int64 {
	amt := mustPay(cur)
	if amt != MinBond {
		panic("bond")
	}
	now := time.Now().Unix()
	if !beneficiary.IsValid() || beneficiary == cur.Address() {
		panic("bad beneficiary")
	}
	if soft <= 0 || hard < soft || hard > book.MaxPot {
		panic("bad cap")
	}
	if price <= 0 || price > book.MaxPot {
		panic("bad price")
	}
	if deadline <= now || deadline-now > MaxHorizon {
		panic("deadline")
	}
	if tapPerSecond <= 0 || tapPerSecond > hard {
		panic("bad tap")
	}
	if delay < MinDelay || delay > MaxHorizon {
		panic("bad delay")
	}
	if vestDuration < MinVest || vestDuration > MaxHorizon {
		panic("bad vest")
	}
	if teamBps < 0 || teamBps > MaxTeamBps {
		panic("bad team")
	}
	if perAddressCap < 0 || (perAddressCap > 0 && perAddressCap > hard) {
		panic("bad address cap")
	}
	validName(name)
	validSymbol(symbol)
	if symbols.Has(symbol) {
		panic("symbol taken")
	}
	nextID++
	id := nextID
	rd := &round{
		founder:     cur.Previous().Address(),
		beneficiary: beneficiary,
		name:        name,
		symbol:      symbol,
		soft:        soft,
		hard:        hard,
		price:       price,
		deadline:    deadline,
		delay:       delay,
		vest:        vestDuration,
		teamBps:     teamBps,
		perCap:      perAddressCap,
		status:      stRaising,
		tap:         tapPerSecond,
		accounts:    avl.NewTree(),
	}
	rounds.Set(idKey(id), rd)
	symbols.Set(symbol, id)
	chain.Emit("Open", "id", strconv.FormatInt(id, 10), "symbol", symbol)
	return id
}

// Commit adds ugnot to the caller's contribution while the round is open.
func Commit(cur realm, id int64) {
	amt := mustPay(cur)
	rd := mustRound(id)
	if rd.status != stRaising {
		panic("not raising")
	}
	if time.Now().Unix() >= rd.deadline {
		panic("closed")
	}
	if amt > book.MaxPot-rd.raised {
		panic("pot cap")
	}
	caller := cur.Previous().Address()
	key := caller.String()
	acct, existing := lookup(rd, key)
	if !existing && rd.contributors >= MaxContributors {
		panic("full")
	}
	next := acct.paid + amt
	if rd.perCap > 0 && next > rd.perCap {
		panic("address cap")
	}
	if !existing {
		rd.accounts.Set(key, acct)
		rd.contributors++
	}
	acct.paid = next
	rd.raised += amt
	chain.Emit("Commit", "id", strconv.FormatInt(id, 10), "from", key, "amount", strconv.FormatInt(amt, 10))
}

// Cancel pulls the caller's full contribution before the deadline.
func Cancel(cur realm, id int64) {
	mustUser(cur)
	rd := mustRound(id)
	if rd.status != stRaising {
		panic("not raising")
	}
	if time.Now().Unix() >= rd.deadline {
		panic("closed")
	}
	caller := cur.Previous().Address()
	key := caller.String()
	v, ok := take(rd.accounts, key)
	if !ok {
		panic("nothing")
	}
	acct := v.(*account)
	amt := acct.paid
	if amt <= 0 {
		panic("nothing")
	}
	rd.raised -= amt
	rd.accounts.Remove(key)
	rd.contributors--
	send(cur, caller, amt)
	chain.Emit("Cancel", "id", strconv.FormatInt(id, 10), "from", key, "amount", strconv.FormatInt(amt, 10))
}

// Finalize closes the round. Anyone may call it after the deadline.
// Below the soft cap, or when pro-rata floors to less than the soft cap,
// the only later ugnot path is Refund. Otherwise the round is live.
func Finalize(cur realm, id int64) {
	rd := mustRound(id)
	if rd.status != stRaising {
		panic("not raising")
	}
	now := time.Now().Unix()
	if now < rd.deadline {
		panic("early")
	}
	if rd.raised < rd.soft {
		rd.status = stFailed
		chain.Emit("Finalize", "id", strconv.FormatInt(id, 10), "status", "failed")
		return
	}
	var sum int64
	rd.accounts.Iterate("", "", func(_ string, v any) bool {
		acct := v.(*account)
		acc, _ := book.Accepted(acct.paid, rd.hard, rd.raised)
		sum += acc
		return false
	})
	if sum < rd.soft {
		rd.status = stFailed
		chain.Emit("Finalize", "id", strconv.FormatInt(id, 10), "status", "failed")
		return
	}
	var units int64
	rd.accounts.Iterate("", "", func(_ string, v any) bool {
		acct := v.(*account)
		acc, ex := book.Accepted(acct.paid, rd.hard, rd.raised)
		acct.accepted = acc
		acct.excess = ex
		acct.units = book.ContributorUnits(acc, rd.price)
		units += acct.units
		return false
	})
	rd.accepted = sum
	rd.teamUnits = book.TeamUnits(units, rd.teamBps)
	rd.t0 = now
	rd.mark = now
	rd.status = stLive
	tok, led := grc20.NewToken(rd.name, rd.symbol, 0, 0, cur)
	rd.token = tok
	rd.ledger = led
	mustMint(led, cur.Address(), units+rd.teamUnits)
	chain.Emit("Finalize", "id", strconv.FormatInt(id, 10), "status", "live")
}

// Refund pulls a failed contribution plus that account's bond share,
// or the unfilled excess after a successful pro-rata round.
func Refund(cur realm, id int64) {
	mustUser(cur)
	rd := mustRound(id)
	caller := cur.Previous().Address()
	acct := mustAccount(rd, caller)
	var amt int64
	if rd.status == stFailed {
		if acct.refunded || acct.paid <= 0 || rd.raised <= 0 {
			panic("nothing")
		}
		amt = acct.paid + book.BondShare(MinBond, acct.paid, rd.raised)
		acct.refunded = true
		acct.paid = 0
	} else if rd.status == stLive {
		if acct.excessRefunded || acct.excess <= 0 {
			panic("nothing")
		}
		amt = acct.excess
		acct.excessRefunded = true
		acct.excess = 0
	} else {
		panic("not final")
	}
	send(cur, caller, amt)
	chain.Emit("Refund", "id", strconv.FormatInt(id, 10), "to", caller.String(), "amount", strconv.FormatInt(amt, 10))
}

// Exit pulls the still-locked part of the caller's accepted ugnot and burns
// their unclaimed tokens. Claiming tokens first forfeits this path.
func Exit(cur realm, id int64) {
	mustUser(cur)
	rd := mustRound(id)
	if rd.status != stLive {
		panic("not live")
	}
	now := time.Now().Unix()
	rd.sync(now)
	caller := cur.Previous().Address()
	acct := mustAccount(rd, caller)
	if acct.exited {
		panic("exited")
	}
	if acct.claimed {
		panic("claimed")
	}
	if acct.accepted <= 0 {
		panic("nothing")
	}
	locked := book.AccountLocked(acct.accepted, rd.budget(now), rd.accepted)
	if locked <= 0 {
		panic("nothing")
	}
	acct.exited = true
	rd.exitedUgnot += locked
	if acct.units > 0 {
		mustBurn(rd.ledger, cur.Address(), acct.units)
	}
	send(cur, caller, locked)
	chain.Emit("Exit", "id", strconv.FormatInt(id, 10), "to", caller.String(), "amount", strconv.FormatInt(locked, 10))
}

// ClaimTokens moves this contributor's frozen token amount out of the realm.
// The ugnot they paid stays under the tap. This cannot be combined with Exit.
func ClaimTokens(cur realm, id int64) {
	mustUser(cur)
	rd := mustRound(id)
	if rd.status != stLive {
		panic("not live")
	}
	caller := cur.Previous().Address()
	acct := mustAccount(rd, caller)
	if acct.claimed {
		panic("claimed")
	}
	if acct.exited {
		panic("exited")
	}
	if acct.units <= 0 {
		panic("nothing")
	}
	acct.claimed = true
	mustTransfer(rd.ledger, cur.Address(), caller, acct.units)
	chain.Emit("Claim", "id", strconv.FormatInt(id, 10), "to", caller.String(), "amount", strconv.FormatInt(acct.units, 10))
}

// WithdrawTap sends the beneficiary whatever the tap has unlocked and that
// no active contributor can still exit. The caller does not receive the coins.
func WithdrawTap(cur realm, id int64) {
	rd := mustRound(id)
	if rd.status != stLive {
		panic("not live")
	}
	now := time.Now().Unix()
	rd.sync(now)
	budget := rd.budget(now)
	if budget < rd.teamWithdrawn {
		panic("nothing")
	}
	room := budget - rd.teamWithdrawn
	pot := rd.accepted - rd.teamWithdrawn - rd.exitedUgnot
	reserved := reservedLocked(rd, budget)
	if pot < reserved || room <= 0 {
		panic("nothing")
	}
	amt := room
	if avail := pot - reserved; avail < amt {
		amt = avail
	}
	if amt <= 0 {
		panic("nothing")
	}
	rd.teamWithdrawn += amt
	send(cur, rd.beneficiary, amt)
	chain.Emit("Withdraw", "id", strconv.FormatInt(id, 10), "to", rd.beneficiary.String(), "amount", strconv.FormatInt(amt, 10))
}

// ClaimVested sends the beneficiary the linear team vest. It does not change the tap.
func ClaimVested(cur realm, id int64) {
	rd := mustRound(id)
	if rd.status != stLive {
		panic("not live")
	}
	now := time.Now().Unix()
	vested := book.Vested(rd.teamUnits, now-rd.t0, rd.vest)
	amt := vested - rd.teamClaimed
	if amt <= 0 {
		panic("nothing")
	}
	rd.teamClaimed += amt
	mustTransfer(rd.ledger, cur.Address(), rd.beneficiary, amt)
	chain.Emit("Vest", "id", strconv.FormatInt(id, 10), "to", rd.beneficiary.String(), "amount", strconv.FormatInt(amt, 10))
}

// QueueTapRaise records a higher tap. It starts accruing only after the frozen delay.
func QueueTapRaise(cur realm, id int64, newTap int64) {
	rd := mustRound(id)
	mustFounder(cur, rd)
	if rd.status != stLive {
		panic("not live")
	}
	if rd.pendingTap != 0 {
		panic("raise pending")
	}
	if newTap <= rd.tap {
		panic("tap up")
	}
	now := time.Now().Unix()
	rd.pendingTap = newTap
	rd.pendingAt = now + rd.delay
	chain.Emit("TapRaise", "id", strconv.FormatInt(id, 10), "tap", strconv.FormatInt(newTap, 10))
}

// CancelTapRaise drops a raise that is not yet due.
func CancelTapRaise(cur realm, id int64) {
	rd := mustRound(id)
	mustFounder(cur, rd)
	if rd.pendingTap == 0 {
		panic("no raise")
	}
	if time.Now().Unix() >= rd.pendingAt {
		panic("raise due")
	}
	rd.pendingTap = 0
	rd.pendingAt = 0
}

// LowerTap slows the tap immediately, after applying any raise that is already due.
func LowerTap(cur realm, id int64, newTap int64) {
	rd := mustRound(id)
	mustFounder(cur, rd)
	if rd.status != stLive {
		panic("not live")
	}
	now := time.Now().Unix()
	rd.sync(now)
	if newTap <= 0 || newTap >= rd.tap {
		panic("tap down")
	}
	rd.accrued = book.Accrued(rd.accrued, rd.tap, rd.mark, now, rd.accepted)
	rd.mark = now
	rd.tap = newTap
	if rd.pendingTap > 0 && rd.pendingTap <= newTap {
		rd.pendingTap = 0
		rd.pendingAt = 0
	}
	chain.Emit("TapLower", "id", strconv.FormatInt(id, 10), "tap", strconv.FormatInt(newTap, 10))
}

// ReturnBond sends the bond to the founder after the team vest ends,
// or immediately when a round failed with no contributions.
// A failed round that took contributions returns the bond through Refund.
func ReturnBond(cur realm, id int64) {
	rd := mustRound(id)
	if rd.bondReturned {
		panic("bond returned")
	}
	if rd.status == stFailed && rd.raised == 0 {
		rd.bondReturned = true
		send(cur, rd.founder, MinBond)
		return
	}
	if rd.status != stLive {
		panic("bond")
	}
	if time.Now().Unix() < rd.t0+rd.vest {
		panic("early")
	}
	rd.bondReturned = true
	send(cur, rd.founder, MinBond)
	chain.Emit("Bond", "id", strconv.FormatInt(id, 10), "to", rd.founder.String())
}

// Sync applies a tap raise that has come due. It does not move coins.
func Sync(cur realm, id int64) {
	rd := mustRound(id)
	if rd.status != stLive {
		panic("not live")
	}
	rd.sync(time.Now().Unix())
}

// RoundCount is the number of rounds opened in this realm. Ids are 1..RoundCount.
func RoundCount() int64 { return nextID }

// Summary is one round as newline-separated fields, in this order:
// name, symbol, status, founder, beneficiary, soft, hard, price, deadline,
// delay, vest, teamBps, perCap, raised, accepted, tap, pendingTap, pendingAt,
// unlocked, withdrawn, exited, t0, contributors, teamUnits, teamClaimed, bondReturned.
// bondReturned is 0 or 1. Name and symbol cannot contain newlines.
func Summary(id int64) string {
	rd := mustRound(id)
	unlocked := int64(0)
	if rd.status == stLive {
		unlocked = book.Budget(rd.accrued, rd.tap, rd.mark, time.Now().Unix(), rd.accepted, rd.pendingTap, rd.pendingAt)
	}
	bond := "0"
	if rd.bondReturned {
		bond = "1"
	}
	return strings.Join([]string{
		rd.name,
		rd.symbol,
		statusName(rd.status),
		rd.founder.String(),
		rd.beneficiary.String(),
		strconv.FormatInt(rd.soft, 10),
		strconv.FormatInt(rd.hard, 10),
		strconv.FormatInt(rd.price, 10),
		strconv.FormatInt(rd.deadline, 10),
		strconv.FormatInt(rd.delay, 10),
		strconv.FormatInt(rd.vest, 10),
		strconv.FormatInt(rd.teamBps, 10),
		strconv.FormatInt(rd.perCap, 10),
		strconv.FormatInt(rd.raised, 10),
		strconv.FormatInt(rd.accepted, 10),
		strconv.FormatInt(rd.tap, 10),
		strconv.FormatInt(rd.pendingTap, 10),
		strconv.FormatInt(rd.pendingAt, 10),
		strconv.FormatInt(unlocked, 10),
		strconv.FormatInt(rd.teamWithdrawn, 10),
		strconv.FormatInt(rd.exitedUgnot, 10),
		strconv.FormatInt(rd.t0, 10),
		strconv.Itoa(rd.contributors),
		strconv.FormatInt(rd.teamUnits, 10),
		strconv.FormatInt(rd.teamClaimed, 10),
		bond,
	}, "\n")
}

// AccountLine is the caller's seat in a round, newline-separated:
// paid, accepted, excess, units, refunded, excessRefunded, exited, claimed.
// Flags are 0 or 1. An address with no seat is all zeros.
func AccountLine(id int64, addr address) string {
	rd := mustRound(id)
	paid, accepted, excess, units := int64(0), int64(0), int64(0), int64(0)
	refunded, excessRefunded, exited, claimed := "0", "0", "0", "0"
	if v, ok := take(rd.accounts, addr.String()); ok {
		acct := v.(*account)
		paid = acct.paid
		accepted = acct.accepted
		excess = acct.excess
		units = acct.units
		if acct.refunded {
			refunded = "1"
		}
		if acct.excessRefunded {
			excessRefunded = "1"
		}
		if acct.exited {
			exited = "1"
		}
		if acct.claimed {
			claimed = "1"
		}
	}
	return strings.Join([]string{
		strconv.FormatInt(paid, 10),
		strconv.FormatInt(accepted, 10),
		strconv.FormatInt(excess, 10),
		strconv.FormatInt(units, 10),
		refunded,
		excessRefunded,
		exited,
		claimed,
	}, "\n")
}

// Status is "raising", "live", or "failed".
func Status(id int64) string {
	switch mustRound(id).status {
	case stRaising:
		return "raising"
	case stLive:
		return "live"
	default:
		return "failed"
	}
}

// Raised is the ugnot committed and not cancelled.
func Raised(id int64) int64 { return mustRound(id).raised }

// AcceptedOf is the ugnot kept from this address after a successful finalize.
func AcceptedOf(id int64, addr address) int64 {
	rd := mustRound(id)
	v, ok := take(rd.accounts, addr.String())
	if !ok {
		return 0
	}
	return v.(*account).accepted
}

// Unlock is the ugnot the tap has unlocked, including a due raise that is not yet synced.
func Unlock(id int64) int64 {
	rd := mustRound(id)
	if rd.status != stLive {
		return 0
	}
	return book.Budget(rd.accrued, rd.tap, rd.mark, time.Now().Unix(), rd.accepted, rd.pendingTap, rd.pendingAt)
}

// Tap returns the current rate and a queued rate. The queued rate is zero when none is waiting.
func Tap(id int64) (current, pending int64) {
	rd := mustRound(id)
	return rd.tap, rd.pendingTap
}

// Balance is this address's project-token balance for the round. It is zero before a live finalize.
func Balance(id int64, addr address) int64 {
	rd := mustRound(id)
	if rd.token == nil {
		return 0
	}
	return rd.token.BalanceOf(addr)
}

// Render shows the round list, or one round when path is the decimal id.
func Render(path string) string {
	if len(path) > 0 && path[0] == '/' {
		path = path[1:]
	}
	if path == "" {
		return renderHome()
	}
	id, err := strconv.ParseInt(path, 10, 64)
	if err != nil || id <= 0 {
		return "> [!WARNING]\n> Unknown round\n"
	}
	v, ok := take(rounds, idKey(id))
	if !ok {
		return "> [!WARNING]\n> Unknown round\n"
	}
	return renderRound(id, v.(*round))
}

func renderHome() string {
	out := "# Charter\n\n"
	out += "A round escrows ugnot until its deadline. A missed soft cap refunds contributors and shares the bond. A filled round pays the team only along the published tap. A higher tap waits out its delay, and a contributor who has not claimed tokens can exit the part the tap has not unlocked.\n\n"
	out += "- Bond: " + strconv.FormatInt(MinBond, 10) + " ugnot\n"
	out += "- Max team: " + strconv.FormatInt(MaxTeamBps, 10) + " bps\n"
	out += "- Min delay and vest: " + strconv.FormatInt(MinDelay, 10) + " seconds\n\n"
	out += "## Rounds\n\n"
	if rounds.Size() == 0 {
		out += "No rounds yet.\n"
		return out
	}
	rounds.Iterate("", "", func(key string, v any) bool {
		rd := v.(*round)
		out += "- " + trimKey(key) + " " + sanitize.InlineText(rd.symbol) + " (" + statusName(rd.status) + ")\n"
		return false
	})
	return out
}

func renderRound(id int64, rd *round) string {
	now := time.Now().Unix()
	out := "# " + sanitize.InlineText(rd.name) + "\n\n"
	out += "- Symbol: " + sanitize.InlineText(rd.symbol) + "\n"
	out += "- Status: " + statusName(rd.status) + "\n"
	out += "- Founder: " + rd.founder.String() + "\n"
	out += "- Beneficiary: " + rd.beneficiary.String() + "\n"
	out += "- Soft / hard: " + strconv.FormatInt(rd.soft, 10) + " / " + strconv.FormatInt(rd.hard, 10) + " ugnot\n"
	out += "- Price: " + strconv.FormatInt(rd.price, 10) + " ugnot per token\n"
	out += "- Raised: " + strconv.FormatInt(rd.raised, 10) + " ugnot\n"
	out += "- Deadline: " + strconv.FormatInt(rd.deadline, 10) + "\n"
	out += "- Tap: " + strconv.FormatInt(rd.tap, 10) + " ugnot/sec\n"
	if rd.pendingTap > 0 {
		out += "- Queued tap: " + strconv.FormatInt(rd.pendingTap, 10) + " at " + strconv.FormatInt(rd.pendingAt, 10) + "\n"
	}
	out += "- Delay / vest: " + strconv.FormatInt(rd.delay, 10) + " / " + strconv.FormatInt(rd.vest, 10) + " seconds\n"
	out += "- Team: " + strconv.FormatInt(rd.teamBps, 10) + " bps\n"
	if rd.status == stLive {
		out += "- Accepted: " + strconv.FormatInt(rd.accepted, 10) + " ugnot\n"
		out += "- Unlocked: " + strconv.FormatInt(book.Budget(rd.accrued, rd.tap, rd.mark, now, rd.accepted, rd.pendingTap, rd.pendingAt), 10) + " ugnot\n"
		out += "- Withdrawn: " + strconv.FormatInt(rd.teamWithdrawn, 10) + " ugnot\n"
		out += "- Exited: " + strconv.FormatInt(rd.exitedUgnot, 10) + " ugnot\n"
		if rd.tap > 0 {
			out += "- Seconds to full tap: " + strconv.FormatInt((rd.accepted+rd.tap-1)/rd.tap, 10) + "\n"
		}
	}
	out += "\nRound " + strconv.FormatInt(id, 10) + ".\n"
	return out
}

func (rd *round) sync(now int64) {
	if rd.pendingTap > 0 && now >= rd.pendingAt {
		rd.accrued = book.Accrued(rd.accrued, rd.tap, rd.mark, rd.pendingAt, rd.accepted)
		rd.tap = rd.pendingTap
		rd.mark = rd.pendingAt
		rd.pendingTap = 0
		rd.pendingAt = 0
	}
}

func (rd *round) budget(now int64) int64 {
	return book.Accrued(rd.accrued, rd.tap, rd.mark, now, rd.accepted)
}

func reservedLocked(rd *round, budget int64) int64 {
	var sum int64
	rd.accounts.Iterate("", "", func(_ string, v any) bool {
		acct := v.(*account)
		if acct.exited || acct.claimed || acct.accepted == 0 {
			return false
		}
		sum += book.AccountLocked(acct.accepted, budget, rd.accepted)
		return false
	})
	return sum
}

func mustPay(cur realm) int64 {
	mustUser(cur)
	sent := unsafe.OriginSend()
	if len(sent) != 1 || sent[0].Denom != "ugnot" || sent[0].Amount <= 0 {
		panic("ugnot only")
	}
	return sent[0].Amount
}

func mustUser(cur realm) {
	if !cur.Previous().IsUserCall() {
		panic("user call")
	}
}

func mustFounder(cur realm, rd *round) {
	if cur.Previous().Address() != rd.founder {
		panic("founder")
	}
}

func mustRound(id int64) *round {
	v, ok := take(rounds, idKey(id))
	if !ok {
		panic("unknown round")
	}
	return v.(*round)
}

func take(tree *avl.Tree, key string) (any, bool) {
	v := tree.Get(key)
	if v == nil {
		return nil, false
	}
	return v, true
}

func lookup(rd *round, key string) (*account, bool) {
	v, ok := take(rd.accounts, key)
	if !ok {
		return &account{}, false
	}
	return v.(*account), true
}

func mustAccount(rd *round, caller address) *account {
	v, ok := take(rd.accounts, caller.String())
	if !ok {
		panic("nothing")
	}
	return v.(*account)
}

func send(cur realm, to address, amt int64) {
	if amt <= 0 {
		panic("nothing")
	}
	bnk := banker.NewBanker(banker.BankerTypeRealmSend, cur)
	bnk.SendCoins(cur.Address(), to, chain.Coins{{Denom: "ugnot", Amount: amt}})
}

func mustMint(led *grc20.PrivateLedger, addr address, amt int64) {
	if amt == 0 {
		return
	}
	if err := led.Mint(addr, amt); err != nil {
		panic(err.Error())
	}
}

func mustTransfer(led *grc20.PrivateLedger, from, to address, amt int64) {
	if err := led.Transfer(from, to, amt); err != nil {
		panic(err.Error())
	}
}

func mustBurn(led *grc20.PrivateLedger, addr address, amt int64) {
	if err := led.Burn(addr, amt); err != nil {
		panic(err.Error())
	}
}

func validName(name string) {
	if name == "" || len(name) > 64 {
		panic("bad name")
	}
	for _, c := range name {
		if c < 0x20 || c == 0x7f {
			panic("bad name")
		}
	}
}

func validSymbol(symbol string) {
	if symbol == "" || len(symbol) > 11 {
		panic("bad symbol")
	}
	for _, c := range symbol {
		ok := (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') || c == '_' || c == '-'
		if !ok {
			panic("bad symbol")
		}
	}
}

func idKey(id int64) string {
	s := strconv.FormatInt(id, 10)
	for len(s) < 20 {
		s = "0" + s
	}
	return s
}

func trimKey(key string) string {
	i := 0
	for i < len(key)-1 && key[i] == '0' {
		i++
	}
	return key[i:]
}

func statusName(status int) string {
	switch status {
	case stRaising:
		return "raising"
	case stLive:
		return "live"
	default:
		return "failed"
	}
}
