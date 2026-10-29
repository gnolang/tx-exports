package game30

import (
	"chain"
	"strconv"
	"strings"
	"testing"
	"time"
)

// ── Vouchers & replay ────────────────────────────────────────────────────────

func TestVoucher_ValidAndReplay(cur realm, t *testing.T) {
	setup()
	p := ta("v-player")
	payload := `[["grin","50"]]`
	n, e, s := voucher(t, "claim", p, payload)
	testing.SetRealm(testing.NewUserRealm(p))
	out := ClaimAndMint(cross(cur), payload, n, e, s)
	if bal(p, "grin") != 50 || out != `{"grin":50}` {
		t.Errorf("claim: bal=%d out=%s", bal(p, "grin"), out)
	}
	if LastNonce(p.String()) != n {
		t.Errorf("nonce not recorded")
	}
	testing.SkipHeights(13)
	mustAbort(t, "replay", revive(func() { ClaimAndMint(cross(cur), payload, n, e, s) }), "already used")
	if bal(p, "grin") != 50 {
		t.Errorf("replay credited")
	}
}

func TestVoucher_Rejections(cur realm, t *testing.T) {
	adm := setup()
	p, q := ta("v-p"), ta("v-q")
	payload := `[["grin","10"]]`
	now := time.Now().Unix()

	// voucher for p used by q
	n, e, s := voucher(t, "claim", p, payload)
	testing.SetRealm(testing.NewUserRealm(q))
	mustAbort(t, "other player", revive(func() { ClaimAndMint(cross(cur), payload, n, e, s) }), "invalid voucher signature")
	// tampered payload
	testing.SetRealm(testing.NewUserRealm(p))
	mustAbort(t, "tampered", revive(func() { ClaimAndMint(cross(cur), `[["grin","99"]]`, n, e, s) }), "invalid voucher signature")
	// wrong kind (an achievement voucher can't be used to claim)
	sa := sigFor(t, "ach", p, n, e, payload)
	mustAbort(t, "wrong kind", revive(func() { ClaimAndMint(cross(cur), payload, n, e, sa) }), "invalid voucher signature")
	// expired
	se := sigFor(t, "claim", p, n, now-1, payload)
	mustAbort(t, "expired", revive(func() { ClaimAndMint(cross(cur), payload, n, now-1, se) }), "expired")
	// expiry too far out
	sf := sigFor(t, "claim", p, n, now+3600, payload)
	mustAbort(t, "far expiry", revive(func() { ClaimAndMint(cross(cur), payload, n, now+3600, sf) }), "too far")
	// kill switch
	testing.SetRealm(testing.NewUserRealm(adm))
	SetClaimSigner(cross(cur), "")
	testing.SetRealm(testing.NewUserRealm(p))
	mustAbort(t, "signer disabled", revive(func() { ClaimAndMint(cross(cur), payload, n, e, s) }), "no claim signer")
	testing.SetRealm(testing.NewUserRealm(p))
	mustAbort(t, "non-admin SetClaimSigner", revive(func() { SetClaimSigner(cross(cur), testSignerPub) }), "admin only")
	testing.SetRealm(testing.NewUserRealm(adm))
	SetClaimSigner(cross(cur), testSignerPub)
	testing.SetRealm(testing.NewUserRealm(p))
	ClaimAndMint(cross(cur), payload, n, e, s)
	if bal(p, "grin") != 10 || bal(q, "grin") != 0 {
		t.Errorf("p=%d q=%d", bal(p, "grin"), bal(q, "grin"))
	}
}

// ── Rate caps ────────────────────────────────────────────────────────────────

func TestRateCap_RefillAndCooldown(cur realm, t *testing.T) {
	setup()
	p := ta("rate-p")
	// hands dust rate = 12 × 2.00 (dmg) × 1.75 (year-plan dust headroom) = 42/min;
	// a fresh wallet starts with a 5-min bank = 210.
	payload := `[["grin","200"]]`
	n, e, s := voucher(t, "claim", p, payload)
	testing.SetRealm(testing.NewUserRealm(p))
	ClaimAndMint(cross(cur), payload, n, e, s)

	payload = `[["grin","1"]]`
	n, e, s = voucher(t, "claim", p, payload)
	mustAbort(t, "cooldown", revive(func() { ClaimAndMint(cross(cur), payload, n, e, s) }), "too fast")
	testing.SkipHeights(13) // +65 s → 10 + 45 = 55 available
	payload = `[["grin","60"]]`
	n, e, s = voucher(t, "claim", p, payload)
	mustAbort(t, "over cap", revive(func() { ClaimAndMint(cross(cur), payload, n, e, s) }), "rate limit")
	testing.SkipHeights(13) // +65 s → 10 + 91 = 101
	payload = `[["grin","90"]]`
	n, e, s = voucher(t, "claim", p, payload)
	ClaimAndMint(cross(cur), payload, n, e, s)
	if bal(p, "grin") != 290 {
		t.Errorf("grin=%d want 290", bal(p, "grin"))
	}
	// the bank never exceeds 1 h of the tool's rate
	testing.SkipHeights(2000)
	if a := allowanceFor(p, 0); a != 2520 {
		t.Errorf("bank cap = %d, want 2520", a)
	}
}

func TestRateCap_VeinCap(cur realm, t *testing.T) {
	adm := setup()
	p := ta("vein-p")
	testing.SetRealm(testing.NewUserRealm(adm))
	SetVeinMax(cross(cur), "joy", strconv.FormatUint(veinMintedOf("joy")+30, 10))
	payload := `[["joy","100"]]`
	n, e, s := voucher(t, "claim", p, payload)
	testing.SetRealm(testing.NewUserRealm(p))
	out := ClaimAndMint(cross(cur), payload, n, e, s)
	if bal(p, "joy") != 30 || out != `{"joy":30}` {
		t.Errorf("vein cap not applied: %d %s", bal(p, "joy"), out)
	}
	testing.SetRealm(testing.NewUserRealm(adm))
	mustAbort(t, "vein below minted", revive(func() { SetVeinMax(cross(cur), "joy", "1") }), "below")
}

// ── Gnome Pass payment ───────────────────────────────────────────────────────

func TestPass_PaymentAndWithdraw(cur realm, t *testing.T) {
	adm := setup()
	p := ta("pass-buyer")
	price := PassPrice()
	testing.SetRealm(testing.NewUserRealm(p))
	testing.SetOriginSend(chain.Coins{chain.NewCoin("ugnot", 1)})
	mustAbort(t, "underpay", revive(func() { ActivateGnomePass(cross(cur), 30) }), "attach exactly")
	testing.SetOriginSend(chain.Coins{chain.NewCoin("ugnot", price*2)})
	mustAbort(t, "overpay", revive(func() { ActivateGnomePass(cross(cur), 30) }), "attach exactly")
	mustAbort(t, "bad duration", revive(func() { ActivateGnomePass(cross(cur), 45) }), "durationDays")
	testing.SetOriginSend(chain.Coins{chain.NewCoin("ugnot", price)})
	ActivateGnomePass(cross(cur), 30)
	now := time.Now().Unix()
	if GnomePassExpiry(p.String()) != now+30*86400 {
		t.Errorf("expiry %d", GnomePassExpiry(p.String()))
	}
	testing.SetOriginSend(chain.Coins{chain.NewCoin("ugnot", price*2)})
	ActivateGnomePass(cross(cur), 60) // stacks
	if GnomePassExpiry(p.String()) != now+90*86400 {
		t.Errorf("stacked expiry %d", GnomePassExpiry(p.String()))
	}
	if PassRevenue() != price*3 {
		t.Errorf("revenue %d", PassRevenue())
	}
	testing.SetOriginSend(nil)

	// Withdraw (the bank deposited the attached ugnot into the realm account).
	realmAddr := chain.PackageAddress(realmPkgPath)
	testing.IssueCoins(realmAddr, chain.Coins{chain.NewCoin("ugnot", price*3)})
	mustAbort(t, "non-admin withdraw", revive(func() { WithdrawFunds(cross(cur), p.String(), 1) }), "admin only")
	testing.SetRealm(testing.NewUserRealm(adm))
	out := ta("treasury-out")
	WithdrawFunds(cross(cur), out.String(), price*3)
	if TreasuryBalance() != 0 {
		t.Errorf("realm balance after withdraw %d", TreasuryBalance())
	}
	mustAbort(t, "overdraw", revive(func() { WithdrawFunds(cross(cur), out.String(), 1) }), "unwithdrawn pass revenue")
}

// ── PvP ──────────────────────────────────────────────────────────────────────

func newMatch(cur realm, a, b address, game string, bet string) string {
	testing.SetRealm(testing.NewUserRealm(a))
	id := CreatePvpLobby(cross(cur), game, "grin", bet)
	testing.SetRealm(testing.NewUserRealm(b))
	JoinPvpLobby(cross(cur), id)
	return id
}

// legacyLobby builds a lobby that escrowed a wager before wagers were switched off.
func legacyLobby(cur realm, a address, bet uint64) string {
	testing.SetRealm(testing.NewUserRealm(a))
	id := CreatePvpLobby(cross(cur), "rps", "grin", "0")
	debitBal(a.String(), "grin", bet)
	lset(id, "bet", strconv.FormatUint(bet, 10))
	pvpWagers.Set(id, "grin:"+strconv.FormatUint(bet, 10)+":"+a.String()+":")
	return id
}

func winnerIs(id string, w address) bool {
	return strings.Contains(PvpLobby(id), `"winner":"`+w.String()+`"`)
}

// Decision 5: PvP wagers are off until rewritten. A bet is refused; a lobby
// escrowed before the switch can't be joined or revealed, only refunded.
func TestPvp_WagersOff(cur realm, t *testing.T) {
	setup()
	a, b := ta("pvpw-a"), ta("pvpw-b")
	give(a, "grin", 1000)
	give(b, "grin", 1000)
	testing.SetRealm(testing.NewUserRealm(a))
	mustAbort(t, "wager lobby", revive(func() { CreatePvpLobby(cross(cur), "rps", "grin", "100") }), "wagers are off")
	if bal(a, "grin") != 1000 {
		t.Errorf("refused wager moved coins: %d", bal(a, "grin"))
	}
	id := legacyLobby(cur, a, 100)
	testing.SetRealm(testing.NewUserRealm(b))
	mustAbort(t, "join wagered lobby", revive(func() { JoinPvpLobby(cross(cur), id) }), "wagers are off")
	// a legacy lobby that was already joined: reveal refused, timeout refunds both
	id2 := legacyLobby(cur, a, 100)
	debitBal(b.String(), "grin", 100)
	pvpWagers.Set(id2, "grin:100:"+a.String()+":"+b.String())
	lset(id2, "challenger", b.String())
	lset(id2, "status", "joined")
	testing.SetRealm(testing.NewUserRealm(a))
	CommitPvpMove(cross(cur), id2, h("rock", "1"))
	testing.SetRealm(testing.NewUserRealm(b))
	CommitPvpMove(cross(cur), id2, h("paper", "2"))
	mustAbort(t, "reveal wagered lobby", revive(func() { RevealPvpMove(cross(cur), id2, "paper", "2") }), "wagers are off")
	testing.SkipHeights(121)
	ClaimPvpTimeout(cross(cur), id2)
	if bal(a, "grin") != 900 || bal(b, "grin") != 1000 {
		t.Errorf("timeout refund: a=%d b=%d", bal(a, "grin"), bal(b, "grin"))
	}
	testing.SetRealm(testing.NewUserRealm(a))
	CancelPvpLobby(cross(cur), id)
	if bal(a, "grin") != 1000 {
		t.Errorf("cancel refund: a=%d", bal(a, "grin"))
	}
}

func TestPvp_HashedRoundPaysWinner(cur realm, t *testing.T) {
	adm := setup()
	a, b := ta("pvp-a"), ta("pvp-b")
	give(a, "grin", 1000)
	give(b, "grin", 1000)
	_ = adm
	id := newMatch(cur, a, b, "rps", "0")
	if strings.Contains(OpenLobbies(), id) {
		t.Errorf("joined lobby still listed as open")
	}
	testing.SetRealm(testing.NewUserRealm(a))
	CommitPvpMove(cross(cur), id, h("rock", "sa"))
	testing.SetRealm(testing.NewUserRealm(b))
	mustAbort(t, "reveal before both commit", revive(func() { RevealPvpMove(cross(cur), id, "scissors", "sb") }), "both players")
	CommitPvpMove(cross(cur), id, h("scissors", "sb"))
	RevealPvpMove(cross(cur), id, "scissors", "sb")
	testing.SetRealm(testing.NewUserRealm(a))
	RevealPvpMove(cross(cur), id, "rock", "sa")
	if !winnerIs(id, a) || bal(a, "grin") != 1000 || bal(b, "grin") != 1000 {
		t.Errorf("winner/balances: %s a=%d b=%d", PvpLobby(id), bal(a, "grin"), bal(b, "grin"))
	}
	if !strings.Contains(PvpLobby(id), `"status":"finished"`) || !strings.Contains(PvpLobby(id), a.String()) {
		t.Errorf("lobby %s", PvpLobby(id))
	}
}

func TestPvp_InvalidChoiceForfeits(cur realm, t *testing.T) {
	setup()
	a, b := ta("pvpf-a"), ta("pvpf-b")
	give(a, "grin", 100)
	give(b, "grin", 100)
	id := newMatch(cur, a, b, "rps", "0")
	testing.SetRealm(testing.NewUserRealm(a))
	CommitPvpMove(cross(cur), id, h("lizard", "x")) // not an rps move
	testing.SetRealm(testing.NewUserRealm(b))
	CommitPvpMove(cross(cur), id, h("rock", "y"))
	testing.SetRealm(testing.NewUserRealm(a))
	RevealPvpMove(cross(cur), id, "lizard", "x")
	if !winnerIs(id, b) {
		t.Errorf("forfeit: %s", PvpLobby(id))
	}
}

func TestPvp_Timeouts(cur realm, t *testing.T) {
	setup()
	a, b, c, d := ta("pvpt-a"), ta("pvpt-b"), ta("pvpt-c"), ta("pvpt-d")
	for _, x := range []address{a, b, c, d} {
		give(x, "grin", 100)
	}
	// 1) only a commits, b stalls → a wins after the timeout
	id := newMatch(cur, a, b, "rps", "0")
	testing.SetRealm(testing.NewUserRealm(a))
	CommitPvpMove(cross(cur), id, h("rock", "1"))
	mustAbort(t, "early timeout", revive(func() { ClaimPvpTimeout(cross(cur), id) }), "not yet")
	testing.SkipHeights(121)
	ClaimPvpTimeout(cross(cur), id)
	if !winnerIs(id, a) {
		t.Errorf("committer timeout win: %s", PvpLobby(id))
	}
	// 2) nobody commits → refund both
	id2 := newMatch(cur, c, d, "coin_flip", "0")
	testing.SkipHeights(121)
	testing.SetRealm(testing.NewUserRealm(d))
	ClaimPvpTimeout(cross(cur), id2)
	if bal(c, "grin") != 100 || bal(d, "grin") != 100 {
		t.Errorf("refund: c=%d d=%d", bal(c, "grin"), bal(d, "grin"))
	}
	// 3) open lobby nobody joins → creator cancels and is refunded
	id3 := legacyLobby(cur, c, 40)
	testing.SetRealm(testing.NewUserRealm(d))
	mustAbort(t, "cancel by other", revive(func() { CancelPvpLobby(cross(cur), id3) }), "only the creator")
	testing.SetRealm(testing.NewUserRealm(c))
	CancelPvpLobby(cross(cur), id3)
	if bal(c, "grin") != 100 {
		t.Errorf("cancel refund: c=%d", bal(c, "grin"))
	}
	testing.SetRealm(testing.NewUserRealm(d))
	mustAbort(t, "join cancelled", revive(func() { JoinPvpLobby(cross(cur), id3) }), "not open")
}

func TestPvp_CoinFlipFairBit(cur realm, t *testing.T) {
	setup()
	a, b := ta("pvpc-a"), ta("pvpc-b")
	give(a, "grin", 10)
	give(b, "grin", 10)
	id := newMatch(cur, a, b, "coin_flip", "0")
	testing.SetRealm(testing.NewUserRealm(a))
	CommitPvpMove(cross(cur), id, h("heads", "s1"))
	testing.SetRealm(testing.NewUserRealm(b))
	CommitPvpMove(cross(cur), id, h("tails", "s2"))
	RevealPvpMove(cross(cur), id, "tails", "s2")
	testing.SetRealm(testing.NewUserRealm(a))
	RevealPvpMove(cross(cur), id, "heads", "s1")
	x := sha256Sum("s1:s2")
	outcome := "heads"
	if (hexNibble(x[1]) & 1) == 1 {
		outcome = "tails"
	}
	winner := a
	if outcome == "tails" {
		winner = b
	}
	if !winnerIs(id, winner) {
		t.Errorf("outcome %s, winner bal %d (a=%d b=%d)", outcome, bal(winner, "grin"), bal(a, "grin"), bal(b, "grin"))
	}
}

func hexNibble(c byte) byte {
	if c >= 'a' {
		return c - 'a' + 10
	}
	return c - '0'
}

// ── Casino ───────────────────────────────────────────────────────────────────



// ── Achievements ─────────────────────────────────────────────────────────────

func TestAchievements_AllowlistAndFixedRewards(cur realm, t *testing.T) {
	setup()
	p := ta("ach-p")
	pl := `["blocks_1"]`
	n, e, s := voucher(t, "ach", p, pl)
	testing.SetRealm(testing.NewUserRealm(p))
	ClaimAchievement(cross(cur), "blocks_1", n, e, s)
	if bal(p, "grin") != 4 || !HasAchievement(p.String(), "blocks_1") {
		t.Errorf("blocks_1 reward: grin=%d", bal(p, "grin"))
	}
	n, e, s = voucher(t, "ach", p, pl)
	testing.SetRealm(testing.NewUserRealm(p))
	mustAbort(t, "claim twice", revive(func() { ClaimAchievement(cross(cur), "blocks_1", n, e, s) }), "already claimed")
	// grind medal needs real lifetime mining
	gp := `["g.grin.10"]`
	n, e, s = voucher(t, "ach", p, gp)
	testing.SetRealm(testing.NewUserRealm(p))
	mustAbort(t, "unearned grind", revive(func() { ClaimAchievement(cross(cur), "g.grin.10", n, e, s) }), "not earned")
	cp := `[["grin","20"]]`
	n, e, s = voucher(t, "claim", p, cp)
	testing.SetRealm(testing.NewUserRealm(p))
	ClaimAndMint(cross(cur), cp, n, e, s)
	bp := `["g.grin.10","g.grin.100","nope"]`
	n, e, s = voucher(t, "ach", p, bp)
	testing.SetRealm(testing.NewUserRealm(p))
	if got := BatchClaimAchievements(cross(cur), bp, n, e, s); got != 1 {
		t.Errorf("batch claimed %d, want 1 (g.grin.10 only)", got)
	}
	if bal(p, "grin") != 4+20+10 {
		t.Errorf("grin=%d want 34", bal(p, "grin"))
	}
	// medal credits: claiming g.grin.10 (and blocks_1) does NOT change
	// LifetimeMined or the miners leaderboard; rewards have their own counter.
	if got := getU(&lifetimeMined, p.String()+":grin"); got != 20 {
		t.Errorf("lifetimeMined grin=%d want 20 (real claims only)", got)
	}
	if got := getU(&rewarded, p.String()+":grin"); got != 14 {
		t.Errorf("rewarded grin=%d want 14", got)
	}
	if got := getU(&miners, p.String()); got != 20 {
		t.Errorf("miners=%d want 20", got)
	}
	if !strings.Contains(LifetimeMined(p.String()), `"grin":20`) || !strings.Contains(Rewarded(p.String()), `"grin":14`) {
		t.Errorf("views: %s / %s", LifetimeMined(p.String()), Rewarded(p.String()))
	}
}

// Vein sizes follow the year-plan rule; crossing 50% is exposed/emitted;
// exhaustion caps credits (the client reports the shortfall).
func TestVein_ResizedAndHalfFlag(cur realm, t *testing.T) {
	adm := setup()
	var r1, r6 string
	for c, r := range coinRarity {
		if r == 1 && r1 == "" && c != "grin" {
			r1 = c
		}
		if r == 6 && r6 == "" {
			r6 = c
		}
	}
	if veinMax(r1) != 82_000_000 || veinMax(r6) != 85_000_000 || veinMax("grin") != 102_000_000 {
		t.Errorf("vein sizes r1 %d r6 %d grin %d", veinMax(r1), veinMax(r6), veinMax("grin"))
	}
	testing.SetRealm(testing.NewUserRealm(adm))
	SetVeinMax(cross(cur), "joy", strconv.FormatUint(veinMintedOf("joy")+100, 10))
	if strings.Contains(VeinSupply("joy"), `"exhausted":true`) {
		t.Errorf("fresh vein exhausted: %s", VeinSupply("joy"))
	}
	takeFromVein("joy", 60)
	if !strings.Contains(VeinSupply("joy"), `"exhausted":false`) {
		t.Errorf("not exhausted yet: %s", VeinSupply("joy"))
	}
	if got := takeFromVein("joy", 60); got != 40 {
		t.Errorf("overflow credited %d want 40", got)
	}
	if !strings.Contains(VeinSupply("joy"), `"halfMinted":true`) || !strings.Contains(VeinSupply("joy"), `"exhausted":true`) {
		t.Errorf("flags: %s", VeinSupply("joy"))
	}
}

// ── Migration ────────────────────────────────────────────────────────────────

func TestMigration_IdempotentAndFinal(cur realm, t *testing.T) {
	adm := setup()
	u := ta("mig-user").String()
	rows := `[["` + u + `","coffee","500"],["` + u + `","bogus","9"]]`
	testing.SetRealm(testing.NewUserRealm(ta("mig-eve")))
	mustAbort(t, "non-admin migrate", revive(func() { MigrateBatch(cross(cur), "b1", "balance", rows) }), "admin only")
	testing.SetRealm(testing.NewUserRealm(adm))
	v0 := veinMintedOf("coffee")
	if n := MigrateBatch(cross(cur), "b1", "balance", rows); n != 1 {
		t.Errorf("applied %d rows, want 1", n)
	}
	if n := MigrateBatch(cross(cur), "b1", "balance", rows); n != 0 {
		t.Errorf("re-run applied %d", n)
	}
	MigrateBatch(cross(cur), "b1-again", "balance", rows) // same rows, new id: SET semantics
	if balOf(u, "coffee") != 500 || veinMintedOf("coffee")-v0 != 500 {
		t.Errorf("not idempotent: bal=%d vein+%d", balOf(u, "coffee"), veinMintedOf("coffee")-v0)
	}
	MigrateBatch(cross(cur), "t1", "tools", `[["`+u+`","starter-twig,twig,laser-of-doom"]]`)
	MigrateBatch(cross(cur), "m1", "medal", `[["`+u+`","blocks_1"],["`+u+`","made-up"]]`)
	MigrateBatch(cross(cur), "l1", "lifetime", `[["`+u+`","grin","1000"]]`)
	MigrateBatch(cross(cur), "l2", "lifetime", `[["`+u+`","grin","1000"]]`)
	if OwnedTools(u) != `["starter-twig","twig"]` || !HasAchievement(u, "blocks_1") || HasAchievement(u, "made-up") || getU(&miners, u) != 1000 {
		t.Errorf("tools=%s medals=%s miners=%d", OwnedTools(u), GetMedals(u), getU(&miners, u))
	}
	FinalizeMigration(cross(cur))
	mustAbort(t, "after finalize", revive(func() { MigrateBatch(cross(cur), "b2", "balance", rows) }), "finalized")
	if !strings.Contains(MigrationStatus(), `"finalized":true`) {
		t.Errorf("status %s", MigrationStatus())
	}
}

// ── Misc fixes ───────────────────────────────────────────────────────────────

func TestMisc_BuyToolLifeLeaderboardJsonRender(cur realm, t *testing.T) {
	setup()
	p := ta("misc-p")
	give(p, "grin", 1000)
	testing.SetRealm(testing.NewUserRealm(p))
	BuyTool(cross(cur), "starter-twig")
	for _, c := range toolCosts["twig"] {
		n, _ := strconv.ParseUint(c[1], 10, 64)
		give(p, c[0], n)
	}
	BuyTool(cross(cur), "twig")
	if toolMaxLife["twig"] > 0 && getU(&toolLife, p.String()+":twig") != effectiveMaxLife(p.String(), "twig") {
		t.Errorf("BuyTool did not set toolLife: %s", ToolLife(p.String()))
	}
	mustAbort(t, "buy twice", revive(func() { BuyTool(cross(cur), "twig") }), "already own")

	setU(&miners, ta("lb-small").String(), 5)
	setU(&miners, ta("lb-big").String(), 5_000_000)
	lb := AllMiners(200, 0)
	if !strings.HasPrefix(lb, `[{"address":"`+ta("lb-big").String()) {
		t.Errorf("leaderboard not sorted by score: %s", lb[:120])
	}

	g := ta("misc-guild")
	testing.SetRealm(testing.NewUserRealm(g))
	gid := CreateGuild(cross(cur), `Evil","leader":"x`)
	info := GuildInfo(gid)
	if strings.Contains(info, `"leader":"x"`) {
		t.Errorf("guild JSON injection: %s", info)
	}
	if !strings.Contains(Render(""), "game29") {
		t.Errorf("Render: %s", Render(""))
	}
}

// ── PlayerXp ─────────────────────────────────────────────────────────────────

func TestPlayerXp_AccumulatesOnClaim(cur realm, t *testing.T) {
	setup()
	p := ta("xp-player")

	// Baseline: fresh player has 0 XP.
	if got := PlayerXp(p.String()); got != "0" {
		t.Errorf("initial XP want 0 got %s", got)
	}

	// Claim 10 grin (rarity 0 → 3 XP each) = 30 XP.
	payload := `[["grin","10"]]`
	n, e, s := voucher(t, "claim", p, payload)
	testing.SetRealm(testing.NewUserRealm(p))
	ClaimAndMint(cross(cur), payload, n, e, s)

	wantXp := uint64(10 * 3) // 10 coins × 3 XP (dust rarity)
	gotXp := getU(&playerXp, p.String())
	if gotXp != wantXp {
		t.Errorf("after grin claim: want XP %d got %d (PlayerXp=%s)", wantXp, gotXp, PlayerXp(p.String()))
	}

	// PlayerXp query must return the same value as a decimal string.
	if PlayerXp(p.String()) != strconv.FormatUint(wantXp, 10) {
		t.Errorf("PlayerXp query mismatch: want %d got %s", wantXp, PlayerXp(p.String()))
	}

	// Upgrade to stone tool (maxRarity=2) so the second claim can mine music.
	// Chain: hands → starter-twig → twig → wood → stone.
	testing.SetRealm(testing.NewUserRealm(p))
	for _, cost := range toolCosts["starter-twig"] {
		n, _ := strconv.ParseUint(cost[1], 10, 64)
		give(p, cost[0], n)
	}
	BuyTool(cross(cur), "starter-twig")
	for _, cost := range toolCosts["twig"] {
		n, _ := strconv.ParseUint(cost[1], 10, 64)
		give(p, cost[0], n)
	}
	BuyTool(cross(cur), "twig")
	for _, cost := range toolCosts["wood"] {
		n, _ := strconv.ParseUint(cost[1], 10, 64)
		give(p, cost[0], n)
	}
	BuyTool(cross(cur), "wood")
	for _, cost := range toolCosts["stone"] {
		n, _ := strconv.ParseUint(cost[1], 10, 64)
		give(p, cost[0], n)
	}
	BuyTool(cross(cur), "stone")

	// Second claim: add a higher-rarity coin. music is rarity 2 → 20 XP each.
	testing.SkipHeights(13) // skip cooldown
	payload2 := `[["music","5"]]`
	n2, e2, s2 := voucher(t, "claim", p, payload2)
	testing.SetRealm(testing.NewUserRealm(p))
	ClaimAndMint(cross(cur), payload2, n2, e2, s2)

	wantXp2 := wantXp + uint64(5*20) // +100 XP
	gotXp2 := getU(&playerXp, p.String())
	if gotXp2 != wantXp2 {
		t.Errorf("after music claim: want XP %d got %d", wantXp2, gotXp2)
	}

	// XP accumulates across players independently.
	q := ta("xp-q")
	if PlayerXp(q.String()) != "0" {
		t.Errorf("unrelated player should have 0 XP, got %s", PlayerXp(q.String()))
	}
}
