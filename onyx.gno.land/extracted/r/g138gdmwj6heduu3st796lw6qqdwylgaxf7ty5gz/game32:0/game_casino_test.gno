package game32

import (
	"strconv"
	"strings"
	"testing"

	"gno.land/p/nt/avl/v0"
	"gno.land/p/nt/testutils/v0"
)

func casAddr(name string) address { return testutils.TestAddress(name) }

func casSetup() address {
	adm := casAddr("cas-admin")
	admin = adm
	operator = address("")
	return adm
}

func casResetPool(coin string, amt uint64) {
	casSet(&casinoPool, coin, amt)
	casinoReserved.Remove(coin)
	casinoDay.Remove(coin)
}

func casSeedHash(seed string) string { return sha256Hex(seed) }

func casAbort(t *testing.T, what string, abort any, want string) {
	t.Helper()
	if abort == nil {
		t.Errorf("%s: expected abort, got success", what)
		return
	}
	msg := ""
	switch v := abort.(type) {
	case string:
		msg = v
	case error:
		msg = v.Error()
	}
	if want != "" && !strings.Contains(msg, want) {
		t.Errorf("%s: aborted with %q, want %q", what, msg, want)
	}
}

// casTotal = every holder of `coin` the casino can touch: the players' balances,
// the pool and the stakes of open bets. Coins only move between them.
func casTotal(coin string, addrs []address) uint64 {
	tot := casGet(&casinoPool, coin) + casJp(coin)
	for _, a := range addrs {
		tot += casBalOf(a.String(), coin)
	}
	casinoBets.Iterate("", "", func(_ string, v any) bool {
		b := v.(*casinoBet)
		if b.coin == coin && !b.settled {
			tot += b.amount
		}
		return false
	})
	return tot
}

// casJp = coins held in the coin's MAJOR + GRAND jackpot pools.
func casJp(coin string) uint64 {
	return casGet(&casinoJackpot, jpKey(coin, "major")) + casGet(&casinoJackpot, jpKey(coin, "grand"))
}

func casResetBonus() {
	casinoStats = avl.Tree{}
	casinoGrants = avl.Tree{}
	casinoJackpot = avl.Tree{}
	casinoJpDust = avl.Tree{}
	casinoJpSeed = avl.Tree{}
	casinoJpRef = avl.Tree{}
}

// casPlay runs one full round: commit (operator) → bet (player) → reveal s → reveal c.
func casPlay(cur realm, t *testing.T, op, p address, round, game, choice string, amt uint64) *casinoBet {
	t.Helper()
	seed := "s-" + round
	secret := "c-" + round
	testing.SetRealm(testing.NewUserRealm(op))
	CommitCasinoSeed(cross(cur), round, p.String(), casSeedHash(seed))
	testing.SetRealm(testing.NewUserRealm(p))
	PlaceCasinoBet(cross(cur), round, game, "grin", casU(amt), choice, sha256Hex(secret))
	testing.SetRealm(testing.NewUserRealm(op))
	RevealCasinoSeed(cross(cur), round, seed)
	testing.SetRealm(testing.NewUserRealm(casAddr("cas-relayer")))
	RevealCasinoSecret(cross(cur), round, secret)
	return casinoBets.Get(round + ":" + p.String()).(*casinoBet)
}

func TestCasino_OutcomeRules(t *testing.T) {
	for _, gc := range [][2]string{{"coin_flip", "heads"}, {"coin_flip", "tails"}, {"higher_lower", "higher"}, {"higher_lower", "lower"}} {
		n := 0
		for roll := uint64(0); roll < 100; roll++ {
			if CasinoOutcome(gc[0], roll) == gc[1] {
				n++
			}
		}
		if n != 49 {
			t.Errorf("%s/%s wins on %d of 100 rolls, want 49", gc[0], gc[1], n)
		}
	}
	w, p, l := 0, 0, 0
	for roll := uint64(0); roll < 100; roll++ {
		switch CasinoOutcome("rps", roll) {
		case "win":
			w++
		case "push":
			p++
		case "lose":
			l++
		}
	}
	// RTP = 0.33·2 + 0.32·1 = 98%
	if w != 33 || p != 32 || l != 35 {
		t.Errorf("rps table %d/%d/%d", w, p, l)
	}
	cases := [][3]string{{"rock", "win", "scissors"}, {"rock", "push", "rock"}, {"rock", "lose", "paper"},
		{"paper", "win", "rock"}, {"paper", "lose", "scissors"}, {"scissors", "win", "paper"}, {"scissors", "lose", "rock"}}
	for _, c := range cases {
		if m := rpsHouseMove(c[0], c[1]); m != c[2] {
			t.Errorf("rps house move %s/%s = %s, want %s", c[0], c[1], m, c[2])
		}
	}
}

func TestCasino_RolesAndPlayerBinding(cur realm, t *testing.T) {
	adm := casSetup()
	casResetPool("grin", 100000)
	op := casAddr("cas-op")
	p := casAddr("cas-bound")
	other := casAddr("cas-other")
	casSet(&balances, p.String()+":grin", 100)
	casSet(&balances, other.String()+":grin", 100)
	testing.SetRealm(testing.NewUserRealm(other))
	casAbort(t, "outsider commit", revive(func() { CommitCasinoSeed(cross(cur), "cr-r1", p.String(), casSeedHash("s")) }), "operator only")
	casAbort(t, "outsider sets operator", revive(func() { SetOperator(cross(cur), other.String()) }), "admin only")
	casAbort(t, "outsider seeds pool", revive(func() { SeedCasinoPool(cross(cur), "grin", "10") }), "admin only")
	testing.SetRealm(testing.NewUserRealm(adm))
	SetOperator(cross(cur), op.String())
	testing.SetRealm(testing.NewUserRealm(op))
	CommitCasinoSeed(cross(cur), "cr-r1", p.String(), casSeedHash("s"))
	casAbort(t, "recommit", revive(func() { CommitCasinoSeed(cross(cur), "cr-r1", p.String(), casSeedHash("x")) }), "already exists")
	casAbort(t, "bad hash", revive(func() { CommitCasinoSeed(cross(cur), "cr-r2", p.String(), "nothex") }), "sha256")
	casAbort(t, "bad player", revive(func() { CommitCasinoSeed(cross(cur), "cr-r2", "nope", casSeedHash("s")) }), "invalid player")
	// Only the round's player can bet in it.
	testing.SetRealm(testing.NewUserRealm(other))
	casAbort(t, "other player bets", revive(func() {
		PlaceCasinoBet(cross(cur), "cr-r1", "coin_flip", "grin", "10", "heads", sha256Hex("c"))
	}), "another player")
	testing.SetRealm(testing.NewUserRealm(p))
	casAbort(t, "clear seed instead of hash", revive(func() {
		PlaceCasinoBet(cross(cur), "cr-r1", "coin_flip", "grin", "10", "heads", "c")
	}), "client hash")
	PlaceCasinoBet(cross(cur), "cr-r1", "coin_flip", "grin", "10", "heads", sha256Hex("c"))
	casAbort(t, "second bet", revive(func() {
		PlaceCasinoBet(cross(cur), "cr-r1", "coin_flip", "grin", "10", "heads", sha256Hex("c"))
	}), "closed")
	// The secret can't be revealed before s, and only the operator reveals s.
	casAbort(t, "secret before seed", revive(func() { RevealCasinoSecret(cross(cur), "cr-r1", "c") }), "not waiting")
	casAbort(t, "player reveals seed", revive(func() { RevealCasinoSeed(cross(cur), "cr-r1", "s") }), "operator only")
	testing.SetRealm(testing.NewUserRealm(op))
	casAbort(t, "wrong seed", revive(func() { RevealCasinoSeed(cross(cur), "cr-r1", "nope") }), "does not match")
	RevealCasinoSeed(cross(cur), "cr-r1", "s")
	// Revealing s settles nothing: the operator didn't know c.
	if b := casinoBets.Get("cr-r1:" + p.String()).(*casinoBet); b.settled || casBalOf(p.String(), "grin") != 90 {
		t.Fatalf("seed reveal settled the bet")
	}
	casAbort(t, "double seed reveal", revive(func() { RevealCasinoSeed(cross(cur), "cr-r1", "s") }), "already revealed")
	casAbort(t, "wrong secret", revive(func() { RevealCasinoSecret(cross(cur), "cr-r1", "d") }), "does not match")
	testing.SetRealm(testing.NewUserRealm(p))
	casAbort(t, "refund after seed reveal", revive(func() { RefundCasinoBet(cross(cur), "cr-r1") }), "no refunds")
	RevealCasinoSecret(cross(cur), "cr-r1", "c")
	if b := casinoBets.Get("cr-r1:" + p.String()).(*casinoBet); !b.settled {
		t.Fatalf("not settled")
	}
	casAbort(t, "double secret", revive(func() { RevealCasinoSecret(cross(cur), "cr-r1", "c") }), "not waiting")
	// A round with no bet just closes on reveal.
	testing.SetRealm(testing.NewUserRealm(op))
	CommitCasinoSeed(cross(cur), "cr-r3", p.String(), casSeedHash("s3"))
	RevealCasinoSeed(cross(cur), "cr-r3", "s3")
	if getCasinoRound("cr-r3").status != "closed" {
		t.Errorf("empty round not closed")
	}
}

func TestCasino_SettlesAndPaysFromPool(cur realm, t *testing.T) {
	adm := casSetup()
	casResetPool("grin", 0)
	casSet(&balances, adm.String()+":grin", 100000)
	testing.SetRealm(testing.NewUserRealm(adm))
	casAbort(t, "seed more than owned", revive(func() { SeedCasinoPool(cross(cur), "grin", "100001") }), "insufficient")
	SeedCasinoPool(cross(cur), "grin", "100000")
	if casGet(&casinoPool, "grin") != 100000 || casBalOf(adm.String(), "grin") != 0 {
		t.Fatalf("seed: pool=%d admin=%d", casGet(&casinoPool, "grin"), casBalOf(adm.String(), "grin"))
	}
	players := []address{}
	for i := 0; i < 30; i++ {
		players = append(players, casAddr("cas-p"+strconv.Itoa(i)))
		casSet(&balances, players[i].String()+":grin", 1000)
	}
	games := [][2]string{{"coin_flip", "heads"}, {"coin_flip", "tails"}, {"higher_lower", "higher"}, {"higher_lower", "lower"}, {"rps", "rock"}, {"rps", "scissors"}}
	total0 := casTotal("grin", players)
	seen := map[string]int{}
	for i, p := range players {
		g := games[i%len(games)]
		round := "cr-settle-" + strconv.Itoa(i)
		pool0 := casGet(&casinoPool, "grin")
		b := casPlay(cur, t, adm, p, round, g[0], g[1], 100)
		roll := CasinoRoll("s-"+round, "c-"+round, round, g[0])
		want := uint64(0)
		res := CasinoOutcome(g[0], roll)
		if g[0] == "rps" {
			seen["rps-"+res]++
			if res == "win" {
				want = 200
			} else if res == "push" {
				want = 100
			}
			if b.outcome != rpsHouseMove(g[1], res) {
				t.Errorf("rps house move %s for %s/%s", b.outcome, g[1], res)
			}
		} else if res == g[1] {
			want = 200
		}
		if b.payout != want || b.roll != roll || casBalOf(p.String(), "grin") != 900+want {
			t.Errorf("%s round %d: payout %d want %d (bal %d)", g[0], i, b.payout, want, casBalOf(p.String(), "grin"))
		}
		if casGet(&casinoPool, "grin") != pool0+100-want {
			t.Errorf("pool %d → %d with payout %d", pool0, casGet(&casinoPool, "grin"), want)
		}
		if casGet(&casinoReserved, "grin") != 0 {
			t.Errorf("reservation not released")
		}
		if casTotal("grin", players) != total0 {
			t.Fatalf("conservation broken after round %d", i)
		}
		js := CasinoBet(round, p.String())
		if !strings.Contains(js, `"settled":true`) || !strings.Contains(js, `"clientSecret":"c-`+round+`"`) {
			t.Errorf("bet json %s", js)
		}
	}
}

func TestCasino_SlotsSettleOnChain(cur realm, t *testing.T) {
	adm := casSetup()
	casResetPool("grin", 10_000_000) // slots max bet = 0.004% = 400
	p := casAddr("cas-slots")
	casSet(&balances, p.String()+":grin", 1_000_000)
	players := []address{p}
	total0 := casTotal("grin", players)
	wins, paid, staked := 0, uint64(0), uint64(0)
	for i := 0; i < 60; i++ {
		round := "cr-slot-" + strconv.Itoa(i)
		pool0 := casGet(&casinoPool, "grin") + casJp("grin")
		testing.SetRealm(testing.NewUserRealm(adm))
		CommitCasinoSeed(cross(cur), round, p.String(), casSeedHash("s-"+round))
		testing.SetRealm(testing.NewUserRealm(p))
		PlaceCasinoBet(cross(cur), round, "slots", "grin", "100", "spin", sha256Hex("c-"+round))
		if casGet(&casinoReserved, "grin") != 49900 {
			t.Fatalf("slots reserve %d, want 499×100", casGet(&casinoReserved, "grin"))
		}
		testing.SetRealm(testing.NewUserRealm(adm))
		RevealCasinoSeed(cross(cur), round, "s-"+round)
		RevealCasinoSecret(cross(cur), round, "c-"+round)
		b := casinoBets.Get(round + ":" + p.String()).(*casinoBet)
		// Re-derive independently from the stream.
		s := newSlotsStream("s-"+round, "c-"+round, round)
		g := slotsSpinGrid(s)
		mult, _ := slotsLineMult(&g)
		sc := slotsCount(&g, symScatter)
		want := 4 * mult
		if sc >= 3 {
			want += 100 * slotsScatterPay[sc]
		}
		if want > 50000 {
			want = 50000
		}
		if b.grid != slotsGridString(&g) || b.payout != want || b.lineMult != mult || b.scatters != sc {
			t.Errorf("slot %d: grid %s payout %d want %d", i, b.grid, b.payout, want)
		}
		if casGet(&casinoPool, "grin")+casJp("grin")+want != pool0+100 || casGet(&casinoReserved, "grin") != 0 {
			t.Errorf("slot %d pool %d→%d payout %d", i, pool0, casGet(&casinoPool, "grin"), want)
		}
		if want > 0 {
			wins++
		}
		paid += want
		staked += 100
		if casTotal("grin", players) != total0 {
			t.Fatalf("conservation broken at slot %d", i)
		}
	}
	if wins == 0 || wins == 60 {
		t.Errorf("slots wins %d of 60", wins)
	}
	_ = paid
	_ = staked
}

func TestCasino_SlotsEngine(t *testing.T) {
	// strip composition
	cnt := [10]int{}
	for i := 0; i < len(slotsStrip); i++ {
		cnt[slotsStrip[i]-'0']++
	}
	want := [10]int{1, 3, 4, 5, 6, 6, 7, 6, 1, 1}
	if len(slotsStrip) != 40 || cnt != want {
		t.Fatalf("strip %v", cnt)
	}
	// all wilds: every line pays wild ×5
	var g [slotsCells]byte
	if m, l := slotsLineMult(&g); m != 25*1000 || l != 25 {
		t.Errorf("all wilds %d/%d", m, l)
	}
	// row 1 = seven seven wild seven coin, everything else coin/star mix that pays nothing
	for i := range g {
		g[i] = 9 // vault: never pays on a line
	}
	for c, s := range []byte{1, 1, 0, 1, 7} {
		g[c*4+1] = s
	}
	if m, l := slotsLineMult(&g); m != 150 || l != 1 {
		t.Errorf("seven×4 line: %d/%d", m, l)
	}
	// scatter / vault counting
	g[0], g[5] = symScatter, symScatter
	if slotsCount(&g, symScatter) != 2 {
		t.Errorf("scatter count")
	}
	// Vectors shared with src/lib/game/__tests__/slots-engine.test.ts
	s := newSlotsStream("seed-a", "client-a", "cr-vector")
	vg := slotsSpinGrid(s)
	vm, vl := slotsLineMult(&vg)
	if got := slotsGridString(&vg) + "|" + casU(vm) + "|" + strconv.Itoa(vl); got != slotsVectorA {
		t.Errorf("vector a: %s", got)
	}
	hg := [slotsCells]byte{}
	for i := range hg {
		hg[i] = 7
	}
	hg[0], hg[4], hg[8] = symVault, symVault, symVault
	hs := newSlotsStream("seed-h", "client-h", "cr-vector")
	tiles, played, full := slotsHoldAndSpin(hs, &hg)
	if got := hsTilesString(&tiles) + "|" + strconv.Itoa(played) + "|" + strconv.FormatBool(full); got != slotsVectorH {
		t.Errorf("vector h: %s", got)
	}
}

const (
	slotsVectorA = "64573216573221064579|0|0"
	slotsVectorH = "1.0.0.1.1.0.0.0.1.0.0.0.0.0.0.0.0.0.0.0|4|false"
)

func TestCasino_Caps(cur realm, t *testing.T) {
	casSetup()
	casResetPool("grin", 19999)
	mustPanic(t, "casino closed", func() { casinoCheckBet("grin", "coin_flip", 1) })
	casResetPool("joy", 199) // rarity 1: 199 units < 200 units
	mustPanic(t, "casino closed", func() { casinoCheckBet("joy", "coin_flip", 1) })
	casResetPool("grin", 100000)
	mustPanic(t, "bet too large", func() { casinoCheckBet("grin", "coin_flip", 501) })
	casinoCheckBet("grin", "rps", 500)
	// slots: 0.004% of 100,000 = 4 → no slots bet fits (bets are multiples of 25)
	mustPanic(t, "bet too large", func() { casinoCheckBet("grin", "slots", 25) })
	casResetPool("grin", 10_000_000) // 0.004% = 400
	casinoCheckBet("grin", "slots", 400)
	mustPanic(t, "multiple of 25", func() { casinoCheckBet("grin", "slots", 30) })
	mustPanic(t, "bet too large", func() { casinoCheckBet("grin", "slots", 425) })
	// open reservations ≤ 20% of the pool: 400×499 = 199,600 each → 10 fit in 2,000,000 … but the
	// daily 10% (1,000,000) binds first: 5 fit.
	casinoReserve("grin", 199600*5)
	mustPanic(t, "daily payout limit", func() { casinoCheckBet("grin", "slots", 350) })
	casResetPool("grin", 10_000_000)
	casinoReserve("grin", 1_990_000)
	mustPanic(t, "20 percent", func() { casinoCheckBet("grin", "coin_flip", 40_000) })
}

func TestCasino_DailyCap(cur realm, t *testing.T) {
	casResetPool("grin", 100000)
	_, snap, _, _ := casinoDayState("grin")
	setCasinoDay("grin", casDayNow(), snap, 9800, 0)
	mustPanic(t, "daily payout limit", func() { casinoCheckBet("grin", "coin_flip", 201) })
	casinoCheckBet("grin", "coin_flip", 200)
}

func TestCasino_RefundAndForfeitTimeouts(cur realm, t *testing.T) {
	adm := casSetup()
	casResetPool("grin", 100000)
	p := casAddr("cas-refund")
	casSet(&balances, p.String()+":grin", 50)
	// 1) s never revealed → refund after 30 minutes, never earlier.
	testing.SetRealm(testing.NewUserRealm(adm))
	CommitCasinoSeed(cross(cur), "cr-rf-1", p.String(), casSeedHash("r"))
	testing.SetRealm(testing.NewUserRealm(p))
	PlaceCasinoBet(cross(cur), "cr-rf-1", "coin_flip", "grin", "50", "heads", sha256Hex("c"))
	casAbort(t, "early refund", revive(func() { RefundCasinoBet(cross(cur), "cr-rf-1") }), "refund opens")
	testing.SkipHeights(361) // > 30 minutes
	testing.SetRealm(testing.NewUserRealm(casAddr("cas-stranger")))
	casAbort(t, "stranger refund", revive(func() { RefundCasinoBet(cross(cur), "cr-rf-1") }), "no bet")
	testing.SetRealm(testing.NewUserRealm(p))
	RefundCasinoBet(cross(cur), "cr-rf-1")
	if casBalOf(p.String(), "grin") != 50 || casGet(&casinoReserved, "grin") != 0 || casGet(&casinoPool, "grin") != 100000 {
		t.Errorf("refund: bal=%d reserved=%d pool=%d", casBalOf(p.String(), "grin"), casGet(&casinoReserved, "grin"), casGet(&casinoPool, "grin"))
	}
	casAbort(t, "double refund", revive(func() { RefundCasinoBet(cross(cur), "cr-rf-1") }), "already settled")
	testing.SetRealm(testing.NewUserRealm(adm))
	casAbort(t, "reveal after refund", revive(func() { RevealCasinoSeed(cross(cur), "cr-rf-1", "r") }), "closed")

	// 2) s revealed, c withheld → forfeits as a loss after 24 h (anyone can call it).
	CommitCasinoSeed(cross(cur), "cr-rf-2", p.String(), casSeedHash("r2"))
	testing.SetRealm(testing.NewUserRealm(p))
	PlaceCasinoBet(cross(cur), "cr-rf-2", "coin_flip", "grin", "50", "heads", sha256Hex("c2"))
	testing.SetRealm(testing.NewUserRealm(adm))
	RevealCasinoSeed(cross(cur), "cr-rf-2", "r2")
	stranger := casAddr("cas-stranger")
	testing.SetRealm(testing.NewUserRealm(stranger))
	casAbort(t, "early forfeit", revive(func() { ForfeitCasinoBet(cross(cur), "cr-rf-2") }), "forfeit opens")
	testing.SkipHeights(17281) // > 24 h
	testing.SetRealm(testing.NewUserRealm(p))
	casAbort(t, "refund instead of forfeit", revive(func() { RefundCasinoBet(cross(cur), "cr-rf-2") }), "no refunds")
	testing.SetRealm(testing.NewUserRealm(stranger))
	ForfeitCasinoBet(cross(cur), "cr-rf-2")
	if casBalOf(p.String(), "grin") != 0 || casGet(&casinoPool, "grin") != 100050 || casGet(&casinoReserved, "grin") != 0 {
		t.Errorf("forfeit: bal=%d pool=%d reserved=%d", casBalOf(p.String(), "grin"), casGet(&casinoPool, "grin"), casGet(&casinoReserved, "grin"))
	}
	casAbort(t, "secret after forfeit", revive(func() { RevealCasinoSecret(cross(cur), "cr-rf-2", "c2") }), "not waiting")
	// 3) betting window: a commit older than 1 h takes no bet.
	testing.SetRealm(testing.NewUserRealm(adm))
	CommitCasinoSeed(cross(cur), "cr-rf-3", p.String(), casSeedHash("r3"))
	testing.SkipHeights(721)
	casSet(&balances, p.String()+":grin", 5)
	testing.SetRealm(testing.NewUserRealm(p))
	casAbort(t, "expired round", revive(func() {
		PlaceCasinoBet(cross(cur), "cr-rf-3", "coin_flip", "grin", "5", "heads", sha256Hex("c3"))
	}), "expired")
}

// Same vectors as src/lib/game/__tests__/casino-outcome.test.ts: realm and client roll alike.
func TestCasino_RollVectors(t *testing.T) {
	if r := CasinoRoll("seed-a", "client-a", "cr-vector", "higher_lower"); r != 23 {
		t.Errorf("vector a: %d", r)
	}
	if r := CasinoRoll("seed-b", "client-b", "cr-vector", "coin_flip"); r != 65 {
		t.Errorf("vector b: %d", r)
	}
}

// Seeds ground offline with the same engine (.bot-notes/casino, engine mirror):
//   cr-g-25    3 scatters → 10 free spins, base win 240 at bet 100
//   cr-g-212   4 vaults → Hold & Spin 6× (+ lines 55 units) = 820 at bet 100
//   cr-g-8273  Hold & Spin with MAJOR (+ 28× incl. a MINI) = 2800 at bet 100
//   cr-g-29989 Hold & Spin with GRAND (9×) = 450 at bet 50
func TestCasino_FreeSpinsGrant(cur realm, t *testing.T) {
	adm := casSetup()
	casResetBonus()
	casResetPool("grin", 10_000_000)
	p := casAddr("cas-fs")
	casSet(&balances, p.String()+":grin", 100_000)
	players := []address{p, adm}
	total0 := casTotal("grin", players)

	b := casPlay(cur, t, adm, p, "cr-g-25", "slots", "spin", 100)
	if b.payout != 240 || b.scatters != 3 || b.fsGranted != 10 {
		t.Fatalf("trigger spin payout %d scatters %d granted %d", b.payout, b.scatters, b.fsGranted)
	}
	g := getGrant(p.String())
	if g == nil || g.left != 10 || g.bet != 100 || g.capLeft != 50000-240 {
		t.Fatalf("grant %s", FreeSpinGrant(p.String()))
	}
	if casGet(&casinoReserved, "grin") != 50000-240 {
		t.Fatalf("grant reservation %d", casGet(&casinoReserved, "grin"))
	}
	bal0 := casBalOf(p.String(), "grin")

	// A paid slots spin waits until the free spins are used.
	testing.SetRealm(testing.NewUserRealm(adm))
	CommitCasinoSeed(cross(cur), "cr-f-paid", p.String(), casSeedHash("s-cr-f-paid"))
	testing.SetRealm(testing.NewUserRealm(p))
	casAbort(t, "paid spin during grant", revive(func() {
		PlaceCasinoBet(cross(cur), "cr-f-paid", "slots", "grin", "100", "spin", sha256Hex("c-cr-f-paid"))
	}), "finish your free spins")

	// Only the grant owner can spin; refund of a stuck free spin gives the spin back.
	testing.SetRealm(testing.NewUserRealm(adm))
	CommitCasinoSeed(cross(cur), "cr-f-r", p.String(), casSeedHash("s-cr-f-r"))
	testing.SetRealm(testing.NewUserRealm(p))
	PlaceCasinoFreeSpin(cross(cur), "cr-f-r", sha256Hex("c-cr-f-r"))
	testing.SetRealm(testing.NewUserRealm(adm))
	CommitCasinoSeed(cross(cur), "cr-f-x", p.String(), casSeedHash("s-cr-f-x"))
	testing.SetRealm(testing.NewUserRealm(p))
	casAbort(t, "two free spins in flight", revive(func() {
		PlaceCasinoFreeSpin(cross(cur), "cr-f-x", sha256Hex("c-cr-f-x"))
	}), "already in progress")
	testing.SkipHeights(361)
	RefundCasinoBet(cross(cur), "cr-f-r")
	if g.left != 10 || g.inRound != "" || casBalOf(p.String(), "grin") != bal0 {
		t.Fatalf("free spin refund: %s bal %d", FreeSpinGrant(p.String()), casBalOf(p.String(), "grin"))
	}

	wants := []uint64{896, 0, 216, 0, 0, 0, 1640, 80, 0}
	for j, want := range wants {
		round := "cr-f-" + strconv.Itoa(j)
		testing.SetRealm(testing.NewUserRealm(adm))
		CommitCasinoSeed(cross(cur), round, p.String(), casSeedHash("s-"+round))
		testing.SetRealm(testing.NewUserRealm(p))
		before := casBalOf(p.String(), "grin")
		PlaceCasinoFreeSpin(cross(cur), round, sha256Hex("c-"+round))
		if casBalOf(p.String(), "grin") != before {
			t.Fatalf("free spin took a stake")
		}
		testing.SetRealm(testing.NewUserRealm(adm))
		RevealCasinoSeed(cross(cur), round, "s-"+round)
		RevealCasinoSecret(cross(cur), round, "c-"+round)
		fb := casinoBets.Get(round + ":" + p.String()).(*casinoBet)
		if !fb.freeSpin || fb.payout != want || casBalOf(p.String(), "grin") != before+want || fb.fsGranted != 0 || fb.hsTiles != "" {
			t.Errorf("free spin %d payout %d want %d", j, fb.payout, want)
		}
		if casTotal("grin", players) != total0 {
			t.Fatalf("conservation broken at free spin %d", j)
		}
		if casGet(&casinoReserved, "grin") != g.capLeft {
			t.Fatalf("reservation %d != capLeft %d", casGet(&casinoReserved, "grin"), g.capLeft)
		}
	}
	if g.left != 1 || g.won != 2832 || g.capLeft != 50000-240-2832 {
		t.Fatalf("grant after 9: %s", FreeSpinGrant(p.String()))
	}
	// The last free spin is never revealed by the player: forfeited after 24h, wins 0, grant closes.
	testing.SetRealm(testing.NewUserRealm(adm))
	CommitCasinoSeed(cross(cur), "cr-f-9", p.String(), casSeedHash("s-cr-f-9"))
	testing.SetRealm(testing.NewUserRealm(p))
	PlaceCasinoFreeSpin(cross(cur), "cr-f-9", sha256Hex("c-cr-f-9"))
	testing.SetRealm(testing.NewUserRealm(adm))
	RevealCasinoSeed(cross(cur), "cr-f-9", "s-cr-f-9")
	testing.SkipHeights(17281)
	testing.SetRealm(testing.NewUserRealm(casAddr("cas-anyone")))
	ForfeitCasinoBet(cross(cur), "cr-f-9")
	if getGrant(p.String()) != nil || FreeSpinGrant(p.String()) != "null" || casGet(&casinoReserved, "grin") != 0 {
		t.Fatalf("grant not closed: %s reserved %d", FreeSpinGrant(p.String()), casGet(&casinoReserved, "grin"))
	}
	if casTotal("grin", players) != total0 {
		t.Fatalf("conservation broken after the feature")
	}
	// Paid spins are open again.
	testing.SetRealm(testing.NewUserRealm(adm))
	CommitCasinoSeed(cross(cur), "cr-f-after", p.String(), casSeedHash("s-cr-f-after"))
	testing.SetRealm(testing.NewUserRealm(p))
	PlaceCasinoBet(cross(cur), "cr-f-after", "slots", "grin", "100", "spin", sha256Hex("c-cr-f-after"))
	testing.SetRealm(testing.NewUserRealm(casAddr("cas-nogrant")))
	casAbort(t, "free spin without grant", revive(func() {
		PlaceCasinoFreeSpin(cross(cur), "cr-f-x", sha256Hex("c-cr-f-x"))
	}), "another player")
}

func TestCasino_HoldAndSpinJackpots(cur realm, t *testing.T) {
	adm := casSetup()
	casResetBonus()
	casResetPool("grin", 10_000_000)
	p := casAddr("cas-hs")
	casSet(&balances, p.String()+":grin", 100_000)
	casSet(&balances, adm.String()+":grin", 50_000)
	players := []address{p, adm}

	// Only the admin seeds, from its own balance; seeds and ref bet are admin-only.
	testing.SetRealm(testing.NewUserRealm(p))
	casAbort(t, "non-admin seed", revive(func() { SeedCasinoJackpot(cross(cur), "grin", "major", "10") }), "admin only")
	casAbort(t, "non-admin reset", revive(func() { SetCasinoJackpotSeed(cross(cur), "grin", "major", "10") }), "admin only")
	testing.SetRealm(testing.NewUserRealm(adm))
	casAbort(t, "bad tier", revive(func() { SeedCasinoJackpot(cross(cur), "grin", "mega", "10") }), "tier")
	casAbort(t, "seed above balance", revive(func() { SeedCasinoJackpot(cross(cur), "grin", "grand", "60000") }), "")
	SeedCasinoJackpot(cross(cur), "grin", "major", "5000")
	SeedCasinoJackpot(cross(cur), "grin", "grand", "20000")
	SetCasinoJackpotSeed(cross(cur), "grin", "major", "3000")
	SetCasinoJackpotSeed(cross(cur), "grin", "grand", "10000")
	if casBalOf(adm.String(), "grin") != 25000 || casJp("grin") != 25000 {
		t.Fatalf("seeding moved %d", casJp("grin"))
	}
	if !strings.Contains(JackpotPool("grin"), `"pool":"20000"`) {
		t.Errorf("JackpotPool should report GRAND: %s", JackpotPool("grin"))
	}
	total0 := casTotal("grin", players)

	// Plain Hold & Spin: coins only, inside the 500× cap.
	b := casPlay(cur, t, adm, p, "cr-g-212", "slots", "spin", 100)
	if b.payout != 820 || b.hsMult != 6 || b.hsRespins != 3 || b.jackpots != "" || b.hsTiles != "0.1.0.0.3.0.0.0.0.0.0.0.0.0.0.1.0.0.1.0" {
		t.Errorf("hold&spin payout %d mult %d respins %d tiles %s", b.payout, b.hsMult, b.hsRespins, b.hsTiles)
	}
	// Each paid spin feeds MAJOR 1% and GRAND 0.5% (remainders carried).
	if casGet(&casinoJackpot, jpKey("grin", "major")) != 5001 || casGet(&casinoJpDust, jpKey("grin", "grand")) != 5000 {
		t.Errorf("contribution major %d grand dust %d", casGet(&casinoJackpot, jpKey("grin", "major")), casGet(&casinoJpDust, jpKey("grin", "grand")))
	}
	if casTotal("grin", players) != total0 {
		t.Fatalf("conservation broken after hold&spin")
	}

	// MAJOR at the reference bet: the whole pool (incl. this spin's 1), then reset to its seed from the house.
	bal := casBalOf(p.String(), "grin")
	house := casGet(&casinoPool, "grin")
	b = casPlay(cur, t, adm, p, "cr-g-8273", "slots", "spin", 100)
	if b.jackpots != "major" || b.jackpotWin != 5002 || b.payout != 2800+5002 || b.hsMult != 28 {
		t.Errorf("major: jackpots %q win %d payout %d mult %d", b.jackpots, b.jackpotWin, b.payout, b.hsMult)
	}
	if casBalOf(p.String(), "grin") != bal-100+b.payout {
		t.Errorf("major paid %d", casBalOf(p.String(), "grin")-bal)
	}
	if casGet(&casinoJackpot, jpKey("grin", "major")) != 3000 {
		t.Errorf("major not reset to its seed: %d", casGet(&casinoJackpot, jpKey("grin", "major")))
	}
	// house: +100 stake −2800 win −1 major −1 grand(dust 5000+5000) −3000 reset
	if casGet(&casinoPool, "grin") != house+100-2800-1-1-3000 {
		t.Errorf("house after major %d → %d", house, casGet(&casinoPool, "grin"))
	}
	if casTotal("grin", players) != total0 {
		t.Fatalf("conservation broken after major")
	}

	// GRAND at half the reference bet pays half the pool.
	grand0 := casGet(&casinoJackpot, jpKey("grin", "grand"))
	b = casPlay(cur, t, adm, p, "cr-g-29989", "slots", "spin", 50)
	if b.jackpots != "grand" || b.jackpotWin != grand0/2 || b.payout != 450+grand0/2 {
		t.Errorf("grand: jackpots %q win %d (pool %d) payout %d", b.jackpots, b.jackpotWin, grand0, b.payout)
	}
	if casGet(&casinoJackpot, jpKey("grin", "grand")) != 10001 {
		// half stays (10000 + the 1 contributed) → above the 10000 seed, no top-up
		t.Errorf("grand after hit %d", casGet(&casinoJackpot, jpKey("grin", "grand")))
	}
	if casTotal("grin", players) != total0 {
		t.Fatalf("conservation broken after grand")
	}
	if !strings.Contains(CasinoJackpots("grin"), `"major":"3000"`) || !strings.Contains(CasinoBet("cr-g-29989", p.String()), `"jackpots":"grand"`) {
		t.Errorf("queries: %s", CasinoJackpots("grin"))
	}
	if casGet(&casinoReserved, "grin") != 0 {
		t.Errorf("reservations left %d", casGet(&casinoReserved, "grin"))
	}
}

func TestCasino_HSPayoutRules(t *testing.T) {
	var tiles [slotsCells]uint16
	tiles[0], tiles[1], tiles[2], tiles[3] = 5, hsMini, hsMinor, hsMajor
	tiles[4], tiles[5] = hsMajor, hsGrand
	m, mj, gr := slotsHSPayout(&tiles, false)
	if m != 5+20+75+75 || !mj || !gr {
		t.Errorf("hs payout %d %v %v", m, mj, gr)
	}
	var full [slotsCells]uint16
	for i := range full {
		full[i] = 1
	}
	m, mj, gr = slotsHSPayout(&full, true)
	if m != 20 || mj || !gr {
		t.Errorf("blackout %d %v %v", m, mj, gr)
	}
}


func TestCasino_OperatorIsSeparateKey(cur realm, t *testing.T) {
	adm := casSetup()
	casResetPool("grin", 100000)
	op := casAddr("cas-op2")
	p := casAddr("cas-op-player")
	testing.SetRealm(testing.NewUserRealm(adm))
	casAbort(t, "operator = admin", revive(func() { SetOperator(cross(cur), adm.String()) }), "separate key")
	// bootstrap: no operator yet → the admin may commit
	CommitCasinoSeed(cross(cur), "cr-op-boot", p.String(), casSeedHash("s"))
	SetOperator(cross(cur), op.String())
	casAbort(t, "admin after operator set", revive(func() {
		CommitCasinoSeed(cross(cur), "cr-op-adm", p.String(), casSeedHash("s"))
	}), "operator")
	testing.SetRealm(testing.NewUserRealm(op))
	CommitCasinoSeed(cross(cur), "cr-op-ok", p.String(), casSeedHash("s"))
	operator = address("")
}

func TestCasino_StatsConservation(cur realm, t *testing.T) {
	adm := casSetup()
	casResetBonus()
	casinoPool = avl.Tree{}
	casinoReserved = avl.Tree{}
	casinoDay = avl.Tree{}
	casinoRounds = avl.Tree{}
	casinoBets = avl.Tree{}
	casSet(&balances, adm.String()+":grin", 10_100_000)
	testing.SetRealm(testing.NewUserRealm(adm))
	SeedCasinoPool(cross(cur), "grin", "10000000")
	SeedCasinoJackpot(cross(cur), "grin", "major", "5000")
	SeedCasinoJackpot(cross(cur), "grin", "grand", "20000")
	p := casAddr("cas-stats")
	casSet(&balances, p.String()+":grin", 1_000_000)
	casPlay(cur, t, adm, p, "cr-g-25", "slots", "spin", 100) // grants 10 free spins
	for j := 0; j < 9; j++ {
		round := "cr-f-" + strconv.Itoa(j)
		testing.SetRealm(testing.NewUserRealm(adm))
		CommitCasinoSeed(cross(cur), round, p.String(), casSeedHash("s-"+round))
		testing.SetRealm(testing.NewUserRealm(p))
		PlaceCasinoFreeSpin(cross(cur), round, sha256Hex("c-"+round))
		testing.SetRealm(testing.NewUserRealm(adm))
		RevealCasinoSeed(cross(cur), round, "s-"+round)
		RevealCasinoSecret(cross(cur), round, "c-"+round)
	}
	casPlay(cur, t, adm, p, "cr-st-cf", "coin_flip", "heads", 100)
	casPlay(cur, t, adm, p, "cr-st-rps", "rps", "rock", 100)
	st := CasinoStats("grin")
	if !strings.Contains(st, `"conserved":true`) || !strings.Contains(st, `"seeded":"10025000"`) {
		t.Errorf("stats: %s", st)
	}
	if !strings.Contains(st, `"slots":{"rounds":10,"staked":"100","paid":"`+casU(240+2832)+`"}`) {
		t.Errorf("slots stats: %s", st)
	}
	if !strings.Contains(st, `"freeSpinsOpen":1`) {
		t.Errorf("open grant: %s", st)
	}
}
