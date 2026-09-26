package bubble

import (
	"strconv"
	"strings"

	governor "gno.land/p/g1leu8d2vsplhehcfkjg50mwgdpxdkt8tztu95wr/governor/v0"
)

// This realm's own powers, installed at init under the engine's reserved prefix (Offer refuses it, so nothing
// can impersonate one). Each is a setting the admin holds (admin.gno) put under the holders too, so the admin's
// every power can be taken away by vote — and one that is nobody's but theirs: the reserve.
//
//	govern:admin    "g1…" | "none"    hand the settings to that address, or destroy the admin for good
//	govern:minter   "g1…" | "none"    name who mints referrals, or nobody
//	govern:pause    "on" | "off"      stop or resume the referral mint
//	govern:daycap   N                 the daily ceiling, in whole BUBBLE
//	govern:reserve  "g1… N"           mint N whole BUBBLE from the reserve to that address (the only way it moves)
//	govern:signal   text              a question with no effect: the sense of the holders
//
// Describe reads the payload alone (two voters at different heights must see the same question); Check reads
// the world; Do changes it. A Do that returns an error finishes the proposal as failed; one that panics aborts
// the transaction and leaves it executable again.

const none = "none"

// The money kinds (everything but the signal) pass on kourt's own terms (Jae, room 201: "use the system from
// kourt.xyz … it should auto adjust"): a fifth of the supply turning out, two thirds of yes+no, a week to vote, two
// days' delay, a fortnight's grace — and the turnout bar ADJUSTS: it is the greater of that fifth and the mean
// turnout of the last few money votes (never above a third of the supply), kourt's min(X̄, votable/3) with the
// bootstrap fifth as the base. Nobody sets it; the holders' own habit does. A signal decides nothing and asks less.
const (
	ReserveMaxPer = 2_000_000 * one          // per proposal
	ReserveGap    = int64(90 * 24 * 60 * 60) // seconds between two reserve mints: a full drain is 25 votes over 6 years
	turnoutKeep   = 8                        // money votes the mean remembers
)

var (
	reserveLast int64   // block time of the last reserve mint
	turnouts    []int64 // the last turnoutKeep money votes' turnout (yes+no+abstain), newest last
	noted       = map[int64]bool{}
)

func installKinds() {
	money := governor.BootstrapRules()
	engine.InstallBuiltin(adminKind{}, money)
	engine.InstallBuiltin(minterKind{}, money)
	engine.InstallBuiltin(pauseKind{}, money)
	engine.InstallBuiltin(daycapKind{}, money)
	engine.InstallBuiltin(reserveKind{}, money)
	// A signal decides nothing: a lighter bar, so the holders can be asked often.
	engine.InstallBuiltin(signalKind{}, governor.NewRules(500, 5000, 3*24*60*60/5, 0, 14*24*60*60/5, 0))
}

func isMoneyKind(kind string) bool {
	switch kind {
	case governor.Reserved + "reserve", governor.Reserved + "admin", governor.Reserved + "minter", governor.Reserved + "pause", governor.Reserved + "daycap":
		return true
	}
	return false
}

// quorumFloor is the absolute turnout a money kind needs at the last sealed epoch: max(supply/5, min(X̄, supply/3)),
// X̄ the mean turnout of the last money votes. Zero for the rest (the rules' fraction alone).
func quorumFloor(kind string) int64 {
	if !isMoneyKind(kind) {
		return 0
	}
	at := ledger.Epoch() - 1
	if at == 0 {
		return 0 // the engine refuses the proposal itself: no sealed epoch yet
	}
	supply := ledger.PastTotal(at)
	floor := supply / 5
	if x := meanTurnout(); x > floor {
		if third := supply / 3; x > third {
			x = third
		}
		if x > floor {
			floor = x
		}
	}
	return floor
}

func meanTurnout() int64 {
	if len(turnouts) == 0 {
		return 0
	}
	var sum int64
	for _, t := range turnouts {
		sum += t
	}
	return sum / int64(len(turnouts))
}

// noteTurnout remembers a decided money vote's turnout, once, when it is settled or executed.
func noteTurnout(id int64) {
	if noted[id] {
		return
	}
	switch engine.State(id) {
	case "active", "canceled":
		return
	}
	yes, no, abstain, _ := engine.Tally(id)
	noted[id] = true
	turnouts = append(turnouts, yes+no+abstain)
	if len(turnouts) > turnoutKeep {
		turnouts = turnouts[len(turnouts)-turnoutKeep:]
	}
	if len(noted) > 256 { // the map is a guard, not a record: a fresh one loses nothing that matters
		noted = map[int64]bool{}
	}
}

// MeanTurnout is what the bar follows, for the page and the box.
func MeanTurnout() int64 { return meanTurnout() }

type bubbleErr struct{ msg string }

func (e *bubbleErr) Error() string { return "bubble: " + e.msg }
func errf(s string) error          { return &bubbleErr{s} }

func addrOrNone(payload, what string) error {
	if payload == none {
		return nil
	}
	if !address(payload).IsValid() {
		return errf("not an address, and not \"" + none + "\"")
	}
	return nil
}

// ---- govern:admin

type adminKind struct{}

func (adminKind) Name() string { return governor.Reserved + "admin" }
func (adminKind) Describe(p string) string {
	if p == none {
		return "destroy the admin — every setting moves only by vote from then on"
	}
	return "hand the settings (minter, pause, day cap) to " + p
}
func (adminKind) Check(p string) error {
	if err := addrOrNone(p, "admin"); err != nil {
		return err
	}
	if p != none && address(p) == admin {
		return errf("that is already the admin")
	}
	if p == none && admin == "" {
		return errf("the admin is already gone")
	}
	return nil
}
func (adminKind) Do(_ int, rlm realm, p string) error {
	if p == none {
		admin = ""
		return nil
	}
	admin = address(p)
	return nil
}

// ---- govern:minter

type minterKind struct{}

func (minterKind) Name() string { return governor.Reserved + "minter" }
func (minterKind) Describe(p string) string {
	if p == none {
		return "name nobody as minter — the referral mint stops until a vote names one"
	}
	return "name " + p + " as the minter of referral rewards"
}
func (minterKind) Check(p string) error {
	if err := addrOrNone(p, "minter"); err != nil {
		return err
	}
	if p != none && address(p) == minter {
		return errf("that is already the minter")
	}
	return nil
}
func (minterKind) Do(_ int, rlm realm, p string) error {
	if p == none {
		minter = ""
		return nil
	}
	minter = address(p)
	return nil
}

// ---- govern:pause

type pauseKind struct{}

func (pauseKind) Name() string { return governor.Reserved + "pause" }
func (pauseKind) Describe(p string) string {
	if p == "on" {
		return "pause the referral mint"
	}
	return "resume the referral mint"
}
func (pauseKind) Check(p string) error {
	if p != "on" && p != "off" {
		return errf("expected \"on\" or \"off\"")
	}
	if (p == "on") == paused {
		return errf("the mint is already " + p)
	}
	return nil
}
func (pauseKind) Do(_ int, rlm realm, p string) error {
	paused = p == "on"
	return nil
}

// ---- govern:daycap

type daycapKind struct{}

func (daycapKind) Name() string { return governor.Reserved + "daycap" }
func (daycapKind) Describe(p string) string {
	return "set the daily mint ceiling to " + p + " BUBBLE"
}
func (daycapKind) Check(p string) error {
	n, err := strconv.ParseInt(p, 10, 64)
	if err != nil || n < 0 || n > ReferralPool/one {
		return errf("expected a number of whole BUBBLE, up to the referral pool")
	}
	return nil
}
func (daycapKind) Do(_ int, rlm realm, p string) error {
	n, err := strconv.ParseInt(p, 10, 64)
	if err != nil {
		return errf("not a number")
	}
	dayCap = n * one
	return nil
}

// ---- govern:reserve

type reserveKind struct{}

func (reserveKind) Name() string { return governor.Reserved + "reserve" }
func (reserveKind) Describe(p string) string {
	to, n, err := parseReserve(p)
	if err != nil {
		return "mint from the reserve: " + p
	}
	return "mint " + strconv.FormatInt(n, 10) + " BUBBLE from the reserve to " + to.String()
}
func (reserveKind) Check(p string) error {
	_, n, err := parseReserve(p)
	if err != nil {
		return err
	}
	if reserveMinted+n*one > Reserve {
		return errf("only " + whole(Reserve-reserveMinted) + " BUBBLE are left in the reserve")
	}
	if reserveLast != 0 && ledger.Now() < reserveLast+ReserveGap {
		return errf("the reserve moved less than ninety days ago; the next mint can run after " + strconv.FormatInt(reserveLast+ReserveGap, 10))
	}
	return nil
}
func (reserveKind) Do(_ int, rlm realm, p string) error {
	to, n, err := parseReserve(p)
	if err != nil {
		return err
	}
	if reserveMinted+n*one > Reserve || (reserveLast != 0 && ledger.Now() < reserveLast+ReserveGap) {
		return errf("the reserve is not open to this mint") // Check ran just before; a batch member could have changed the world
	}
	reserveMinted += n * one
	reserveLast = ledger.Now()
	ledger.Mint(to, n*one)
	return nil
}

func parseReserve(p string) (address, int64, error) {
	parts := strings.Fields(p)
	if len(parts) != 2 {
		return "", 0, errf("expected \"g1… N\": an address and whole BUBBLE")
	}
	to := address(parts[0])
	if !to.IsValid() {
		return "", 0, errf("not an address")
	}
	n, err := strconv.ParseInt(parts[1], 10, 64)
	if err != nil || n <= 0 || n > ReserveMaxPer/one {
		return "", 0, errf("expected whole BUBBLE, between 1 and " + whole(ReserveMaxPer) + " in one proposal")
	}
	return to, n, nil
}

// ---- govern:signal

type signalKind struct{}

func (signalKind) Name() string           { return governor.Reserved + "signal" }
func (signalKind) Describe(p string) string { return "signal (no effect): " + p }
func (signalKind) Check(p string) error {
	if p == "" {
		return errf("a signal needs words")
	}
	if len(p) > 1000 {
		return errf("a signal is under a thousand characters")
	}
	return governor.TextOnly(p)
}
func (signalKind) Do(_ int, rlm realm, p string) error { return nil }
