package connect4_v3

import (
	"chain"
	"chain/banker"
	"chain/runtime"
	"strconv"
	"testing"

	"gno.land/p/nt/avl/v0"
	"gno.land/p/nt/ownable/v0"
	"gno.land/p/nt/testutils/v0"
	"gno.land/p/nt/uassert/v0"
)

const stake = int64(10_000_000)

var (
	alice   = testutils.TestAddress("alice")
	bob     = testutils.TestAddress("bob")
	carol   = testutils.TestAddress("carol")
	admin   = address("g1cvr48r7l7lkmvp77cr6zg2zhu26jgfwr0y8pew")
	pkgAddr = chain.PackageAddress("gno.land/r/samcrew/connect4")
)

func reset() {
	games, active, stats = avl.Tree{}, avl.Tree{}, avl.Tree{}
	nextID, fee, feesCollected = 0, 100_000, 0
	topWins, topGnot = nil, nil
	owner = ownable.NewWithAddress(admin)
	testSession = false
}

// pay sets the ugnot sent with the next call and credits the realm with it,
// mirroring what the chain does. testing.SetRealm must be called in the same
// frame that makes the cross call, so tests call it inline rather than here.
func pay(amount int64) {
	if amount == 0 {
		testing.SetOriginSend(nil)
		return
	}
	coins := chain.Coins{{"ugnot", amount}}
	testing.SetOriginSend(coins)
	testing.IssueCoins(pkgAddr, coins)
}

func balance(addr address) int64 {
	return banker.NewReadonlyBanker().GetCoin(addr, "ugnot")
}

// phrase returns a passphrase unique to the next game id.
func phrase() string { return "four random words " + strconv.Itoa(nextID+1) }

// commit returns the commitment for phrase().
func commit() string { return sha256Hex(phrase()) }

// accepted returns a game between alice (creator) and bob awaiting Reveal,
// and its passphrase.
func accepted(cur realm) (*Game, string) {
	p := phrase()
	testing.SetRealm(testing.NewUserRealm(alice))
	pay(stake)
	id := Offer(cross(cur), "", 10, sha256Hex(p))
	testing.SetRealm(testing.NewUserRealm(bob))
	pay(stake)
	Accept(cross(cur), id)
	return mustGet(id), p
}

// started returns a revealed Playing game between alice (creator) and bob.
func started(cur realm) *Game {
	g, p := accepted(cur)
	testing.SetRealm(testing.NewUserRealm(alice))
	pay(0)
	Reveal(cross(cur), g.ID, p)
	return g
}

// move plays column for whoever is on turn.
func move(cur realm, g *Game, column int) {
	testing.SetRealm(testing.NewUserRealm(g.player(g.Turn)))
	pay(0)
	Play(cross(cur), g.ID, column, g.Moves)
}

// expireClock advances block time past the 90s move clock (SkipHeights is 5s/block).
func expireClock() { testing.SkipHeights(19) }

func TestWinPaysPotMinusFee(cur realm, t *testing.T) {
	reset()
	g := started(cur)
	first := g.player(g.Turn)
	before := balance(first)
	for _, c := range []int{1, 2, 1, 2, 1, 2, 1} { // first mover stacks column 1
		move(cur, g, c)
	}
	uassert.Equal(t, "won", g.Status.String())
	uassert.Equal(t, first, g.Winner)
	uassert.Equal(t, 2*stake-100_000, balance(first)-before)
	uassert.Equal(t, int64(100_000), feesCollected)
	uassert.Equal(t, 1, statsOf(first).Wins)
	uassert.Equal(t, 2*stake-100_000, statsOf(first).GnotWon)
	uassert.Equal(t, 1, statsOf(g.player(3-g.Turn)).Games)
	uassert.Equal(t, 0, active.Size())
}

func TestOfferRejects(cur realm, t *testing.T) {
	reset()
	testing.SetRealm(testing.NewUserRealm(alice))
	pay(minStake - 1)
	uassert.AbortsContains(t, cur, "stake below minimum", func() { Offer(cross(cur), "", 10, commit()) })
	testing.SetRealm(testing.NewUserRealm(alice))
	pay(stake)
	uassert.AbortsContains(t, cur, "validFor", func() { Offer(cross(cur), "", 0, commit()) })
	testing.SetRealm(testing.NewUserRealm(alice))
	pay(stake)
	uassert.AbortsContains(t, cur, "validFor", func() { Offer(cross(cur), "", 61, commit()) })
	testing.SetRealm(testing.NewUserRealm(alice))
	pay(stake)
	uassert.AbortsContains(t, cur, "yourself", func() { Offer(cross(cur), alice, 10, commit()) })
	testing.SetRealm(testing.NewUserRealm(alice))
	pay(0)
	uassert.AbortsContains(t, cur, "send exactly one", func() { Offer(cross(cur), "", 10, commit()) })
	testing.SetRealm(testing.NewUserRealm(alice))
	testing.SetOriginSend(chain.Coins{{"ugnot", stake}, {"foo", 1}})
	uassert.AbortsContains(t, cur, "send exactly one", func() { Offer(cross(cur), "", 10, commit()) })
}

func TestAcceptRejects(cur realm, t *testing.T) {
	reset()
	testing.SetRealm(testing.NewUserRealm(alice))
	pay(stake)
	id := Offer(cross(cur), bob, 1, commit())
	testing.SetRealm(testing.NewUserRealm(alice))
	pay(stake)
	uassert.AbortsContains(t, cur, "own offer", func() { Accept(cross(cur), id) })
	testing.SetRealm(testing.NewUserRealm(carol))
	pay(stake)
	uassert.AbortsContains(t, cur, "reserved", func() { Accept(cross(cur), id) })
	testing.SetRealm(testing.NewUserRealm(bob))
	pay(stake - 1)
	uassert.AbortsContains(t, cur, "must send exactly", func() { Accept(cross(cur), id) })
	testing.SetRealm(testing.NewUserRealm(bob))
	pay(stake + 1)
	uassert.AbortsContains(t, cur, "must send exactly", func() { Accept(cross(cur), id) })
	testing.SkipHeights(13) // 65s > 1 minute
	testing.SetRealm(testing.NewUserRealm(bob))
	pay(stake)
	uassert.AbortsContains(t, cur, "expired", func() { Accept(cross(cur), id) })
	testing.SetRealm(testing.NewUserRealm(bob))
	pay(stake)
	uassert.AbortsContains(t, cur, "not found", func() { Accept(cross(cur), 99) })
}

func TestPlayRejects(cur realm, t *testing.T) {
	reset()
	g := started(cur)
	testing.SetRealm(testing.NewUserRealm(g.player(3 - g.Turn)))
	pay(0)
	uassert.AbortsContains(t, cur, "not your turn", func() { Play(cross(cur), g.ID, 1, g.Moves) })
	testing.SetRealm(testing.NewUserRealm(carol))
	pay(0)
	uassert.AbortsContains(t, cur, "not your turn", func() { Play(cross(cur), g.ID, 1, g.Moves) })
	testing.SetRealm(testing.NewUserRealm(g.player(g.Turn)))
	pay(0)
	uassert.AbortsContains(t, cur, "column must be", func() { Play(cross(cur), g.ID, 0, g.Moves) })
	testing.SetRealm(testing.NewUserRealm(g.player(g.Turn)))
	pay(0)
	uassert.AbortsContains(t, cur, "column must be", func() { Play(cross(cur), g.ID, 8, g.Moves) })
	expireClock()
	testing.SetRealm(testing.NewUserRealm(g.player(g.Turn)))
	pay(0)
	uassert.AbortsContains(t, cur, "clock ran out", func() { Play(cross(cur), g.ID, 1, g.Moves) })
}

func TestFullColumnRejected(cur realm, t *testing.T) {
	reset()
	g := started(cur)
	for i := 0; i < rows; i++ {
		move(cur, g, 4) // alternating players never make 4 in a column
	}
	testing.SetRealm(testing.NewUserRealm(g.player(g.Turn)))
	pay(0)
	uassert.AbortsContains(t, cur, "column is full", func() { Play(cross(cur), g.ID, 4, g.Moves) })
}

// The creator revealed, then the first mover never moved.
func TestTimeoutBeforeFirstMoveIsVoid(cur realm, t *testing.T) {
	reset()
	g := started(cur)
	testing.SetRealm(testing.NewUserRealm(carol))
	pay(0)
	uassert.AbortsContains(t, cur, "has not run out", func() { ClaimTimeout(cross(cur), g.ID) })
	a, b := balance(alice), balance(bob)
	expireClock()
	testing.SetRealm(testing.NewUserRealm(carol))
	pay(0) // anyone may settle
	ClaimTimeout(cross(cur), g.ID)
	uassert.Equal(t, "void", g.Status.String())
	uassert.Equal(t, stake, balance(alice)-a)
	uassert.Equal(t, stake, balance(bob)-b)
	uassert.Equal(t, int64(0), feesCollected)
	uassert.Equal(t, 0, stats.Size())
}

func TestTimeoutAfterMoveForfeits(cur realm, t *testing.T) {
	reset()
	g := started(cur)
	mover := g.player(g.Turn)
	loser := g.player(3 - g.Turn)
	move(cur, g, 1)
	expireClock()
	before := balance(mover)
	testing.SetRealm(testing.NewUserRealm(mover))
	pay(0)
	ClaimTimeout(cross(cur), g.ID)
	uassert.Equal(t, "won", g.Status.String())
	uassert.Equal(t, mover, g.Winner)
	uassert.Equal(t, 2*stake-100_000, balance(mover)-before)
	uassert.Equal(t, int64(100_000), feesCollected)
	uassert.Equal(t, 1, statsOf(loser).Games)
}

func TestResign(cur realm, t *testing.T) {
	reset()
	g := started(cur)
	testing.SetRealm(testing.NewUserRealm(carol))
	pay(0)
	uassert.AbortsContains(t, cur, "not a player", func() { Resign(cross(cur), g.ID) })
	before := balance(bob)
	testing.SetRealm(testing.NewUserRealm(alice))
	pay(0)
	Resign(cross(cur), g.ID)
	uassert.Equal(t, "won", g.Status.String())
	uassert.Equal(t, bob, g.Winner)
	uassert.Equal(t, 2*stake-100_000, balance(bob)-before)
	uassert.Equal(t, int64(100_000), feesCollected)
	uassert.Equal(t, 1, statsOf(alice).Games)
}

func TestCancel(cur realm, t *testing.T) {
	reset()
	testing.SetRealm(testing.NewUserRealm(alice))
	pay(stake)
	id := Offer(cross(cur), "", 1, commit())
	testing.SetRealm(testing.NewUserRealm(bob))
	pay(0)
	uassert.AbortsContains(t, cur, "only the creator", func() { Cancel(cross(cur), id) })
	before := balance(alice)
	testing.SetRealm(testing.NewUserRealm(alice))
	pay(0)
	Cancel(cross(cur), id) // creator, before expiry
	uassert.Equal(t, "cancelled", mustGet(id).Status.String())
	uassert.Equal(t, stake, balance(alice)-before)

	// Once expired, anyone may cancel; the refund still goes to the creator.
	testing.SetRealm(testing.NewUserRealm(alice))
	pay(stake)
	id = Offer(cross(cur), "", 1, commit())
	testing.SkipHeights(13) // 65s > 1 minute
	before = balance(alice)
	testing.SetRealm(testing.NewUserRealm(carol))
	pay(0)
	Cancel(cross(cur), id)
	uassert.Equal(t, "cancelled", mustGet(id).Status.String())
	uassert.Equal(t, stake, balance(alice)-before)

	g := started(cur)
	testing.SetRealm(testing.NewUserRealm(alice))
	pay(0)
	uassert.AbortsContains(t, cur, "not open", func() { Cancel(cross(cur), g.ID) })
}

func TestDrawRefundsBoth(cur realm, t *testing.T) {
	reset()
	g := started(cur)
	// Fill every cell but the top of column 7 with a pattern that has no
	// four in a row; player 1 owns the last cell.
	for c := 0; c < cols; c++ {
		for r := 0; r < rows; r++ {
			g.Board[c][r] = byte(1 + (c/2+r)%2)
		}
	}
	g.Board[6][5] = 0
	g.Moves, g.Turn = cols*rows-1, 1
	a, b := balance(alice), balance(bob)
	move(cur, g, 7)
	uassert.Equal(t, "draw", g.Status.String())
	uassert.Equal(t, stake, balance(alice)-a)
	uassert.Equal(t, stake, balance(bob)-b)
	uassert.Equal(t, 1, statsOf(alice).Draws)
}

func TestFeeSnapshotAndWithdraw(cur realm, t *testing.T) {
	reset()
	testing.SetRealm(testing.NewUserRealm(carol))
	pay(0)
	uassert.AbortsContains(t, cur, "not owner", func() { SetFee(cross(cur), 0) })
	testing.SetRealm(testing.NewUserRealm(carol))
	pay(0)
	uassert.AbortsContains(t, cur, "not owner", func() { WithdrawFees(cross(cur), carol) })
	g := started(cur) // offered at the default 0.1 GNOT fee
	testing.SetRealm(testing.NewUserRealm(admin))
	pay(0)
	uassert.AbortsContains(t, cur, "negative", func() { SetFee(cross(cur), -1) })
	SetFee(cross(cur), 5_000_000)
	testing.SetRealm(testing.NewUserRealm(alice))
	pay(0)
	Resign(cross(cur), g.ID)
	uassert.Equal(t, int64(100_000), feesCollected)

	before := balance(carol)
	testing.SetRealm(testing.NewUserRealm(admin))
	pay(0)
	WithdrawFees(cross(cur), carol)
	uassert.Equal(t, int64(100_000), balance(carol)-before)
	uassert.Equal(t, int64(0), feesCollected)

	// A raised fee applies to new offers, which must stake more than it.
	testing.SetRealm(testing.NewUserRealm(alice))
	pay(5_000_000)
	uassert.AbortsContains(t, cur, "exceed the house fee", func() { Offer(cross(cur), "", 10, commit()) })
}

func TestFinishedGameRejects(cur realm, t *testing.T) {
	reset()
	g := started(cur)
	testing.SetRealm(testing.NewUserRealm(alice))
	pay(0)
	Resign(cross(cur), g.ID)
	testing.SetRealm(testing.NewUserRealm(bob))
	pay(0)
	uassert.AbortsContains(t, cur, "not in progress", func() { Play(cross(cur), g.ID, 1, g.Moves) })
	uassert.AbortsContains(t, cur, "not in progress", func() { Resign(cross(cur), g.ID) })
	expireClock()
	testing.SetRealm(testing.NewUserRealm(bob))
	pay(0)
	uassert.AbortsContains(t, cur, "not in progress", func() { ClaimTimeout(cross(cur), g.ID) })
	testing.SetRealm(testing.NewUserRealm(carol))
	pay(stake)
	uassert.AbortsContains(t, cur, "not open", func() { Accept(cross(cur), g.ID) })
	testing.SetRealm(testing.NewUserRealm(carol))
	pay(stake)
	uassert.AbortsContains(t, cur, "invalid opponent", func() { Offer(cross(cur), "notanaddress", 10, commit()) })
}

func TestRevealPhase(cur realm, t *testing.T) {
	reset()
	g, p := accepted(cur)
	uassert.Equal(t, byte(0), g.Turn)
	for _, who := range []address{alice, bob} {
		testing.SetRealm(testing.NewUserRealm(who))
		pay(0)
		uassert.AbortsContains(t, cur, "waiting for the creator", func() { Play(cross(cur), g.ID, 1, g.Moves) })
	}
	testing.SetRealm(testing.NewUserRealm(bob))
	pay(0)
	uassert.AbortsContains(t, cur, "only the creator", func() { Reveal(cross(cur), g.ID, p) })
	testing.SetRealm(testing.NewUserRealm(alice))
	pay(0)
	uassert.AbortsContains(t, cur, "does not match", func() { Reveal(cross(cur), g.ID, p+"x") })
	testing.SetRealm(testing.NewUserRealm(alice))
	pay(0)
	Reveal(cross(cur), g.ID, p)
	uassert.True(t, g.Turn == 1 || g.Turn == 2)
	testing.SetRealm(testing.NewUserRealm(alice))
	pay(0)
	uassert.AbortsContains(t, cur, "not awaiting a reveal", func() { Reveal(cross(cur), g.ID, p) })
	move(cur, g, 1) // the picked first mover can play
	uassert.Equal(t, 1, g.Moves)
}

func TestLateRevealForfeits(cur realm, t *testing.T) {
	reset()
	g, p := accepted(cur)
	expireClock()
	testing.SetRealm(testing.NewUserRealm(alice))
	pay(0)
	uassert.AbortsContains(t, cur, "reveal clock ran out", func() { Reveal(cross(cur), g.ID, p) })
	before := balance(bob)
	testing.SetRealm(testing.NewUserRealm(carol))
	pay(0)
	ClaimTimeout(cross(cur), g.ID)
	uassert.Equal(t, "won", g.Status.String())
	uassert.Equal(t, bob, g.Winner)
	uassert.Equal(t, 2*stake-100_000, balance(bob)-before)
	uassert.Equal(t, int64(100_000), feesCollected)
	uassert.Equal(t, 1, statsOf(bob).Wins)
	uassert.Equal(t, 1, statsOf(alice).Games)
}

func TestCommitmentRejects(cur realm, t *testing.T) {
	reset()
	good := commit()
	for _, bad := range []string{"", good[:63], good + "0", "G" + good[1:], "A" + good[1:]} {
		testing.SetRealm(testing.NewUserRealm(alice))
		pay(stake)
		uassert.AbortsContains(t, cur, "64 lowercase hex", func() { Offer(cross(cur), "", 10, bad) })
	}
	testing.SetRealm(testing.NewUserRealm(alice))
	pay(stake)
	Offer(cross(cur), "", 10, good)
	testing.SetRealm(testing.NewUserRealm(carol))
	pay(stake)
	Offer(cross(cur), "", 10, good) // the same commitment may be offered again
}

func TestPaymentsRequireUserCall(cur realm, t *testing.T) {
	reset()
	testing.SetRealm(testing.NewCodeRealm("gno.land/r/demo/somerealm"))
	pay(stake)
	uassert.AbortsContains(t, cur, "only user-call", func() { Offer(cross(cur), "", 10, commit()) })
	testing.SetRealm(testing.NewUserRealm(alice))
	pay(stake)
	id := Offer(cross(cur), "", 10, commit())
	testing.SetRealm(testing.NewCodeRealm("gno.land/r/demo/somerealm"))
	pay(stake)
	uassert.AbortsContains(t, cur, "only user-call", func() { Accept(cross(cur), id) })
}

func TestNonPayableRejectsCoins(cur realm, t *testing.T) {
	reset()
	g, p := accepted(cur)
	calls := map[string]func(){
		"Reveal":            func() { Reveal(cross(cur), g.ID, p) },
		"Play":              func() { Play(cross(cur), g.ID, 1, g.Moves) },
		"ClaimTimeout":      func() { ClaimTimeout(cross(cur), g.ID) },
		"Resign":            func() { Resign(cross(cur), g.ID) },
		"Cancel":            func() { Cancel(cross(cur), g.ID) },
		"SetFee":            func() { SetFee(cross(cur), 0) },
		"WithdrawFees":      func() { WithdrawFees(cross(cur), admin) },
		"TransferOwnership": func() { TransferOwnership(cross(cur), carol) },
	}
	for name, call := range calls {
		testing.SetRealm(testing.NewUserRealm(admin))
		pay(1)
		uassert.AbortsContains(t, cur, "does not accept coins", call, name)
	}
}

func TestFirstMoverDependsOnAcceptHeight(cur realm, t *testing.T) {
	// The same passphrase, ids and players drawn at two accept heights: the
	// creator can't fix the outcome when committing.
	firsts := map[byte]bool{}
	for i := 0; i < 16 && len(firsts) < 2; i++ {
		reset()
		testing.SkipHeights(1)
		g, p := accepted(cur)
		uassert.Equal(t, runtime.ChainHeight(), g.AcceptHeight)
		testing.SetRealm(testing.NewUserRealm(alice))
		pay(0)
		Reveal(cross(cur), g.ID, p)
		firsts[g.Turn] = true
	}
	uassert.Equal(t, 2, len(firsts))
}

func TestPlayRefusesStaleMove(cur realm, t *testing.T) {
	reset()
	g := started(cur)
	stale := g.Moves
	move(cur, g, 1)
	testing.SetRealm(testing.NewUserRealm(g.player(g.Turn)))
	pay(0)
	uassert.AbortsContains(t, cur, "stale move: the game is at move 1", func() { Play(cross(cur), g.ID, 2, stale) })
	uassert.AbortsContains(t, cur, "stale move", func() { Play(cross(cur), g.ID, 2, g.Moves+1) })
	Play(cross(cur), g.ID, 2, g.Moves)
	uassert.Equal(t, 2, g.Moves)
}

func TestSessionKeysCannotResignStakeOrOwn(cur realm, t *testing.T) {
	reset()
	g := started(cur)
	testSession = true
	testing.SetRealm(testing.NewUserRealm(g.player(g.Turn)))
	pay(0)
	uassert.AbortsContains(t, cur, "Resign needs the account's own key", func() { Resign(cross(cur), g.ID) })
	testing.SetRealm(testing.NewUserRealm(alice))
	pay(stake)
	uassert.AbortsContains(t, cur, "Offer needs the account's own key", func() { Offer(cross(cur), "", 10, commit()) })
	testing.SetRealm(testing.NewUserRealm(admin))
	pay(0)
	uassert.AbortsContains(t, cur, "SetFee needs", func() { SetFee(cross(cur), 0) })
	uassert.AbortsContains(t, cur, "WithdrawFees needs", func() { WithdrawFees(cross(cur), admin) })
	uassert.AbortsContains(t, cur, "TransferOwnership needs", func() { TransferOwnership(cross(cur), carol) })
	// Moves stay open to sessions: that is what Quick play is for.
	move(cur, g, 1)
	uassert.Equal(t, 1, g.Moves)
}

func TestSessionKeysCannotAccept(cur realm, t *testing.T) {
	reset()
	testing.SetRealm(testing.NewUserRealm(alice))
	pay(stake)
	id := Offer(cross(cur), "", 10, commit())
	testSession = true
	testing.SetRealm(testing.NewUserRealm(bob))
	pay(stake)
	uassert.AbortsContains(t, cur, "Accept needs the account's own key", func() { Accept(cross(cur), id) })
}

func TestBump(t *testing.T) {
	var b []leader
	for i := 0; i < 12; i++ {
		b = bump(b, testutils.TestAddress(strconv.Itoa(i)), int64(i))
	}
	uassert.Equal(t, topN, len(b))
	uassert.Equal(t, int64(11), b[0].Score)
	uassert.Equal(t, int64(2), b[9].Score)
	b = bump(b, testutils.TestAddress("5"), 20) // already listed: moves up, not duplicated
	uassert.Equal(t, topN, len(b))
	uassert.Equal(t, testutils.TestAddress("5"), b[0].Addr)
	b = bump(b, testutils.TestAddress("late"), 11) // ties keep the earlier holder first
	uassert.Equal(t, testutils.TestAddress("11"), b[1].Addr)
	uassert.Equal(t, testutils.TestAddress("late"), b[2].Addr)
}
