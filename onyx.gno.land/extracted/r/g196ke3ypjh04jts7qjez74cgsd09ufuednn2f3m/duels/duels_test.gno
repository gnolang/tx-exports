package duels

import (
	"chain"
	"crypto/sha256"
	"encoding/hex"
	"strconv"
	"strings"
	"testing"

	"gno.land/p/nt/avl/v0"
	"gno.land/p/nt/testutils/v0"
	"gno.land/p/nt/uassert/v0"
)

// realmAddr is the address this realm controls on chain.
var realmAddr = chain.PackageAddress("gno.land/r/g196ke3ypjh04jts7qjez74cgsd09ufuednn2f3m/duels")

const testStake int64 = 10_000_000 // 0.01 GNOT

func testCommit(move int, salt string) string {
	sum := sha256.Sum256([]byte(strconv.Itoa(move) + ":" + salt))
	return hex.EncodeToString(sum[:])
}

func stakes(amount int64) chain.Coins {
	return chain.Coins{{Denom: "ugnot", Amount: amount}}
}

// resetAll clears realm state between tests.
func resetAll() {
	duels = avl.Tree{}
	stats = avl.Tree{}
	nextID = 0
	joinWindow = int64(defaultJoinWindow)
	revealWindow = int64(defaultRevealWindow)
	rakeBps = int64(defaultRakeBps)
	escrow = 0
	treasury = 0
	volume = 0
	duelsPlayed = 0
	admin = address("")
	hasAdmin = false
}

// initRealm runs Init as the deployer and funds the realm for payouts.
func initRealm(cur realm, t *testing.T) address {
	deployer := testutils.TestAddress("deployer")
	testing.SetRealm(testing.NewUserRealm(deployer))
	Init(cross(cur))
	uassert.Equal(t, deployer, Admin(), "admin should be the initializer")
	testing.IssueCoins(realmAddr, stakes(1_000_000_000))
	return deployer
}

// openDuel creates a duel as creator, committed to (move, salt).
func openDuel(cur realm, t *testing.T, creator address, move int, salt string, amount int64) uint64 {
	testing.SetRealm(testing.NewUserRealm(creator))
	testing.SetOriginSend(stakes(amount))
	return CreateDuel(cross(cur), testCommit(move, salt))
}

// joinDuel joins an open duel as joiner, committed to (move, salt).
func joinDuel(cur realm, joiner address, id uint64, move int, salt string, amount int64) {
	testing.SetRealm(testing.NewUserRealm(joiner))
	testing.SetOriginSend(stakes(amount))
	JoinDuel(cross(cur), id, testCommit(move, salt))
}

func TestFullFlowCreatorWins(cur realm, t *testing.T) {
	defer resetAll()
	initRealm(cur, t)
	alice := testutils.TestAddress("alice")
	bob := testutils.TestAddress("bob")

	id := openDuel(cur, t, alice, MoveAle, "salt-a", testStake)
	d := GetDuel(id)
	uassert.Equal(t, PhaseOpen, d.phase, "duel should start open")
	uassert.Equal(t, testStake, escrow, "escrow should hold alice's stake")

	joinDuel(cur, bob, id, MoveBroom, "salt-b", testStake)
	d = GetDuel(id)
	uassert.Equal(t, PhaseReveal, d.phase, "duel should move to reveal")
	uassert.Equal(t, int64(2*testStake), escrow, "escrow should hold both stakes")

	// alice reveals only; nothing pays out yet.
	testing.SetRealm(testing.NewUserRealm(alice))
	RevealDuel(cross(cur), id, MoveAle, "salt-a")
	d = GetDuel(id)
	uassert.Equal(t, PhaseReveal, d.phase, "duel waits for the second reveal")
	uassert.Equal(t, int64(2*testStake), escrow, "no payout before both reveals")

	// bob reveals; alice wins (Ale beats Broom).
	testing.SetRealm(testing.NewUserRealm(bob))
	RevealDuel(cross(cur), id, MoveBroom, "salt-b")

	pot := 2 * testStake
	rake := pot * defaultRakeBps / 10_000
	prize := pot - rake

	d = GetDuel(id)
	uassert.Equal(t, PhaseDone, d.phase, "duel should be resolved")
	uassert.Equal(t, ResultCreator, d.result, "creator should win")
	uassert.Equal(t, prize, d.payout, "payout should be pot minus rake")
	uassert.Equal(t, rake, d.rake, "rake should be booked")
	uassert.Equal(t, int64(0), escrow, "escrow should be empty after payout")
	uassert.Equal(t, rake, treasury, "rake should sit in the treasury")
	uassert.Equal(t, pot, volume, "volume should count the pot")
	uassert.Equal(t, uint64(1), duelsPlayed, "one duel resolved")

	as := GetPlayerStats(alice)
	bs := GetPlayerStats(bob)
	uassert.Equal(t, int64(1), as.wins, "alice should have one win")
	uassert.Equal(t, prize, as.won, "alice's winnings should match the payout")
	uassert.Equal(t, int64(1), bs.losses, "bob should have one loss")
	uassert.Equal(t, int64(1), as.duels, "alice's duel recorded")
	uassert.Equal(t, int64(1), bs.duels, "bob's duel recorded")
}

func TestTieRefundsBothStakes(cur realm, t *testing.T) {
	defer resetAll()
	initRealm(cur, t)
	alice := testutils.TestAddress("alice")
	bob := testutils.TestAddress("bob")

	id := openDuel(cur, t, alice, MoveDagger, "x", testStake)
	joinDuel(cur, bob, id, MoveDagger, "y", testStake)

	testing.SetRealm(testing.NewUserRealm(alice))
	RevealDuel(cross(cur), id, MoveDagger, "x")
	testing.SetRealm(testing.NewUserRealm(bob))
	RevealDuel(cross(cur), id, MoveDagger, "y")

	d := GetDuel(id)
	uassert.Equal(t, ResultTie, d.result, "same moves should tie")
	uassert.Equal(t, int64(0), d.payout, "no payout on a tie")
	uassert.Equal(t, int64(0), escrow, "escrow empty after refunds")
	uassert.Equal(t, int64(0), treasury, "no rake on a tie")
	uassert.Equal(t, int64(1), GetPlayerStats(alice).draws, "alice drew")
	uassert.Equal(t, int64(1), GetPlayerStats(bob).draws, "bob drew")
}

func TestFullFlowJoinerWins(cur realm, t *testing.T) {
	defer resetAll()
	initRealm(cur, t)
	alice := testutils.TestAddress("alice")
	bob := testutils.TestAddress("bob")

	id := openDuel(cur, t, alice, MoveAle, "x", testStake)
	joinDuel(cur, bob, id, MoveDagger, "y", testStake)

	testing.SetRealm(testing.NewUserRealm(alice))
	RevealDuel(cross(cur), id, MoveAle, "x")
	testing.SetRealm(testing.NewUserRealm(bob))
	RevealDuel(cross(cur), id, MoveDagger, "y")

	d := GetDuel(id)
	uassert.Equal(t, ResultJoiner, d.result, "dagger should beat ale")
	uassert.Equal(t, int64(1), GetPlayerStats(bob).wins, "joiner should win")
}

func TestUnjoinedDuelRefundsCreator(cur realm, t *testing.T) {
	defer resetAll()
	initRealm(cur, t)
	alice := testutils.TestAddress("alice")

	id := openDuel(cur, t, alice, MoveAle, "x", testStake)
	testing.SkipHeights(joinWindow + 1)

	testing.SetRealm(testing.NewUserRealm(alice))
	ClaimForfeit(cross(cur), id)

	d := GetDuel(id)
	uassert.Equal(t, ResultExpired, d.result, "unjoined duel should expire")
	uassert.Equal(t, int64(0), escrow, "creator refunded")
	uassert.Equal(t, int64(0), treasury, "no rake")
}

func TestSilentRevealerForfeitsPot(cur realm, t *testing.T) {
	defer resetAll()
	initRealm(cur, t)
	alice := testutils.TestAddress("alice")
	bob := testutils.TestAddress("bob")

	id := openDuel(cur, t, alice, MoveAle, "x", testStake)
	joinDuel(cur, bob, id, MoveBroom, "y", testStake)

	testing.SetRealm(testing.NewUserRealm(alice))
	RevealDuel(cross(cur), id, MoveAle, "x")

	// bob never reveals; the window closes.
	testing.SkipHeights(revealWindow + 1)

	pot := 2 * testStake
	rake := pot * defaultRakeBps / 10_000
	testing.SetRealm(testing.NewUserRealm(alice))
	ClaimForfeit(cross(cur), id)

	d := GetDuel(id)
	uassert.Equal(t, ResultCreator, d.result, "revealer should win by forfeit")
	uassert.Equal(t, pot-rake, d.payout, "payout should be pot minus rake")
	uassert.Equal(t, int64(1), GetPlayerStats(alice).wins, "alice wins by forfeit")
	uassert.Equal(t, int64(1), GetPlayerStats(bob).losses, "bob loses by forfeit")
	uassert.Equal(t, int64(0), escrow, "escrow cleared")
}

func TestNobodyRevealedRefundsBoth(cur realm, t *testing.T) {
	defer resetAll()
	initRealm(cur, t)
	alice := testutils.TestAddress("alice")
	bob := testutils.TestAddress("bob")

	id := openDuel(cur, t, alice, MoveAle, "x", testStake)
	joinDuel(cur, bob, id, MoveBroom, "y", testStake)
	testing.SkipHeights(revealWindow + 1)

	testing.SetRealm(testing.NewUserRealm(alice))
	ClaimForfeit(cross(cur), id)

	d := GetDuel(id)
	uassert.Equal(t, ResultExpired, d.result, "nobody revealed -> expired")
	uassert.Equal(t, int64(0), escrow, "both refunded")
	uassert.Equal(t, int64(0), treasury, "no rake")
}

func TestRevealProtectsAgainstCopying(cur realm, t *testing.T) {
	defer resetAll()
	initRealm(cur, t)
	alice := testutils.TestAddress("alice")
	bob := testutils.TestAddress("bob")

	id := openDuel(cur, t, alice, MoveAle, "secret-salt", testStake)
	joinDuel(cur, bob, id, MoveBroom, "y", testStake)

	// alice reveals only after both are committed: bob cannot react,
	// his commitment was fixed at join time.
	testing.SetRealm(testing.NewUserRealm(alice))
	RevealDuel(cross(cur), id, MoveAle, "secret-salt")

	d := GetDuel(id)
	uassert.Equal(t, MoveAle, d.creatorMove, "creator move recorded")
	uassert.Equal(t, -1, d.joinerMove, "joiner has not revealed yet")

	// a wrong salt cannot pass the commitment check.
	testing.SetRealm(testing.NewUserRealm(bob))
	uassert.AbortsWithMessage(t, cur, "commitment mismatch",
		func() { RevealDuel(cross(cur), id, MoveBroom, "wrong-salt") })
}

func TestWrongMoveForCommitment(cur realm, t *testing.T) {
	defer resetAll()
	initRealm(cur, t)
	alice := testutils.TestAddress("alice")
	bob := testutils.TestAddress("bob")

	id := openDuel(cur, t, alice, MoveAle, "x", testStake)
	joinDuel(cur, bob, id, MoveBroom, "y", testStake)

	testing.SetRealm(testing.NewUserRealm(alice))
	uassert.AbortsWithMessage(t, cur, "commitment mismatch",
		func() { RevealDuel(cross(cur), id, MoveDagger, "x") })
}

func TestRulesRejectBadInputs(cur realm, t *testing.T) {
	defer resetAll()
	initRealm(cur, t)
	alice := testutils.TestAddress("alice")
	bob := testutils.TestAddress("bob")

	// invalid commitment format.
	testing.SetRealm(testing.NewUserRealm(alice))
	testing.SetOriginSend(stakes(testStake))
	uassert.AbortsWithMessage(t, cur, "commitment must be 64 hex characters (sha256)",
		func() { CreateDuel(cross(cur), "deadbeef") })

	// stake below the floor.
	testing.SetRealm(testing.NewUserRealm(alice))
	testing.SetOriginSend(stakes(1))
	uassert.AbortsWithMessage(t, cur, "stake out of bounds",
		func() { CreateDuel(cross(cur), testCommit(MoveAle, "x")) })

	id := openDuel(cur, t, alice, MoveAle, "x", testStake)

	// cannot duel yourself.
	testing.SetRealm(testing.NewUserRealm(alice))
	testing.SetOriginSend(stakes(testStake))
	uassert.AbortsWithMessage(t, cur, "cannot duel yourself",
		func() { JoinDuel(cross(cur), id, testCommit(MoveBroom, "y")) })

	// stake must match exactly.
	testing.SetRealm(testing.NewUserRealm(bob))
	testing.SetOriginSend(stakes(testStake + 1))
	uassert.AbortsWithMessage(t, cur, "stake must match the creator's exactly",
		func() { JoinDuel(cross(cur), id, testCommit(MoveBroom, "y")) })

	// unknown id.
	testing.SetRealm(testing.NewUserRealm(bob))
	testing.SetOriginSend(stakes(testStake))
	uassert.AbortsWithMessage(t, cur, "unknown duel id",
		func() { JoinDuel(cross(cur), 999, testCommit(MoveBroom, "y")) })

	// join only while the window is open.
	testing.SkipHeights(joinWindow + 1)
	testing.SetRealm(testing.NewUserRealm(bob))
	testing.SetOriginSend(stakes(testStake))
	uassert.AbortsWithMessage(t, cur, "join window closed",
		func() { JoinDuel(cross(cur), id, testCommit(MoveBroom, "y")) })

	// a fresh duel: the creator can only reclaim it once the window closes.
	id2 := openDuel(cur, t, alice, MoveBroom, "z", testStake)
	testing.SetRealm(testing.NewUserRealm(alice))
	uassert.AbortsWithMessage(t, cur, "join window still open",
		func() { ClaimForfeit(cross(cur), id2) })
	testing.SkipHeights(joinWindow + 1)
	ClaimForfeit(cross(cur), id2)
	uassert.Equal(t, ResultExpired, GetDuel(id2).result, "expired after windows")
}

func TestDoubleRevealAndLateReveal(cur realm, t *testing.T) {
	defer resetAll()
	initRealm(cur, t)
	alice := testutils.TestAddress("alice")
	bob := testutils.TestAddress("bob")

	id := openDuel(cur, t, alice, MoveAle, "x", testStake)
	joinDuel(cur, bob, id, MoveBroom, "y", testStake)

	testing.SetRealm(testing.NewUserRealm(alice))
	RevealDuel(cross(cur), id, MoveAle, "x")
	uassert.AbortsWithMessage(t, cur, "already revealed",
		func() { RevealDuel(cross(cur), id, MoveBroom, "x") })

	testing.SetRealm(testing.NewUserRealm(bob))
	RevealDuel(cross(cur), id, MoveBroom, "y")
	uassert.Equal(t, PhaseDone, GetDuel(id).phase, "resolved after both reveals")

	// late reveal is rejected: the duel is resolved.
	testing.SetRealm(testing.NewUserRealm(bob))
	uassert.AbortsWithMessage(t, cur, "duel already resolved",
		func() { ClaimForfeit(cross(cur), id) })
}

func TestAdminControls(cur realm, t *testing.T) {
	defer resetAll()
	deployer := initRealm(cur, t)
	outsider := testutils.TestAddress("outsider")

	// admin tunes windows and rake.
	testing.SetRealm(testing.NewUserRealm(deployer))
	SetWindows(cross(cur), 50, 60)
	SetRakeBps(cross(cur), 500)
	min, max, join, reveal, rake := Params()
	uassert.Equal(t, MinStake, min, "min stake unchanged")
	uassert.Equal(t, MaxStake, max, "max stake unchanged")
	uassert.Equal(t, int64(50), join, "join window updated")
	uassert.Equal(t, int64(60), reveal, "reveal window updated")
	uassert.Equal(t, int64(500), rake, "rake updated")

	// outsiders cannot.
	testing.SetRealm(testing.NewUserRealm(outsider))
	uassert.AbortsWithMessage(t, cur, "only the realm admin",
		func() { SetWindows(cross(cur), 10, 10) })
	uassert.AbortsWithMessage(t, cur, "only the realm admin",
		func() { SetRakeBps(cross(cur), 0) })
	uassert.AbortsWithMessage(t, cur, "only the realm admin",
		func() { WithdrawTreasury(cross(cur), outsider, 1) })

	// admin cannot withdraw more than the treasury.
	testing.SetRealm(testing.NewUserRealm(deployer))
	uassert.AbortsWithMessage(t, cur, "amount exceeds treasury",
		func() { WithdrawTreasury(cross(cur), deployer, 1) })

	// accumulate rake and withdraw it.
	alice := testutils.TestAddress("alice")
	bob := testutils.TestAddress("bob")
	id := openDuel(cur, t, alice, MoveAle, "x", testStake)
	joinDuel(cur, bob, id, MoveBroom, "y", testStake)
	testing.SetRealm(testing.NewUserRealm(alice))
	RevealDuel(cross(cur), id, MoveAle, "x")
	testing.SetRealm(testing.NewUserRealm(bob))
	RevealDuel(cross(cur), id, MoveBroom, "y")

	pot := 2 * testStake
	expectedRake := pot * 500 / 10_000
	uassert.Equal(t, expectedRake, treasury, "rake accrues at the new rate")

	testing.SetRealm(testing.NewUserRealm(deployer))
	WithdrawTreasury(cross(cur), deployer, expectedRake)
	uassert.Equal(t, int64(0), treasury, "treasury emptied")
}

func TestAdminInitRules(cur realm, t *testing.T) {
	defer resetAll()
	alice := testutils.TestAddress("alice")

	// admin funcs before Init.
	testing.SetRealm(testing.NewUserRealm(alice))
	uassert.AbortsWithMessage(t, cur, "realm not initialized",
		func() { SetWindows(cross(cur), 10, 10) })

	initRealm(cur, t)
	testing.SetRealm(testing.NewUserRealm(alice))
	uassert.AbortsWithMessage(t, cur, "already initialized",
		func() { Init(cross(cur)) })
}

func TestRenderPages(cur realm, t *testing.T) {
	defer resetAll()
	initRealm(cur, t)
	alice := testutils.TestAddress("alice")
	bob := testutils.TestAddress("bob")

	id := openDuel(cur, t, alice, MoveAle, "x", testStake)
	joinDuel(cur, bob, id, MoveBroom, "y", testStake)
	testing.SetRealm(testing.NewUserRealm(alice))
	RevealDuel(cross(cur), id, MoveAle, "x")
	testing.SetRealm(testing.NewUserRealm(bob))
	RevealDuel(cross(cur), id, MoveBroom, "y")

	home := Render("")
	uassert.True(t, strings.Contains(home, "Tavern Duel Arena"), "home shows the arena")
	uassert.True(t, strings.Contains(home, "How to play"), "home explains the rules")
	uassert.True(t, strings.Contains(home, "Recent results"), "home lists recent results")

	detail := Render("duel/" + strconv.FormatUint(id, 10))
	uassert.True(t, strings.Contains(detail, "Duel #"), "duel page shows its id")
	uassert.True(t, strings.Contains(detail, "creator wins"), "duel page shows the result")

	statsPage := Render("stats/" + alice.String())
	uassert.True(t, strings.Contains(statsPage, "Player "), "stats page has a player")
	uassert.True(t, strings.Contains(statsPage, "Wins: 1"), "stats page shows the win")

	unknown := Render("duel/418")
	uassert.True(t, strings.Contains(unknown, "does not exist"), "unknown duels are handled")
}
