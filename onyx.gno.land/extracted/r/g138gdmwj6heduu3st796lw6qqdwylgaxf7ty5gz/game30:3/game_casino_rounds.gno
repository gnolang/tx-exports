package game30

import (
	"crypto/sha256"
	"encoding/hex"
	"strconv"
	"strings"
	"time"

	"chain"
)

// ── rounds ──────────────────────────────────────────────────────────────────

func getCasinoRound(id string) *casinoRound {
	if !casinoRounds.Has(id) {
		return nil
	}
	r, ok := casinoRounds.Get(id).(*casinoRound)
	if !ok {
		return nil
	}
	return r
}

func mustCasinoRound(id string) *casinoRound {
	r := getCasinoRound(id)
	if r == nil {
		panic("round not found")
	}
	return r
}

func casinoRoundBet(r *casinoRound, roundId string) *casinoBet {
	key := roundId + ":" + r.player
	if !casinoBets.Has(key) {
		return nil
	}
	return casinoBets.Get(key).(*casinoBet)
}

// CommitCasinoSeed opens a round for one player with sha256(s). Operator only;
// a round id can be used once.
func CommitCasinoSeed(cur realm, roundId string, player string, seedHash string) {
	if !isOperator(cur) {
		panic("unauthorized: casino operator only")
	}
	if !casSafe(roundId, 64) {
		panic("invalid round id")
	}
	if casinoRounds.Has(roundId) {
		panic("round already exists")
	}
	if !address(player).IsValid() {
		panic("invalid player address")
	}
	seedHash = strings.ToLower(seedHash)
	if !casIsHex64(seedHash) {
		panic("seedHash must be sha256 hex")
	}
	casinoRounds.Set(roundId, &casinoRound{player: player, seedHash: seedHash, status: "committed", committedAt: time.Now().Unix()})
}

// PlaceCasinoBet escrows the player's bet with sha256(c): only the round's
// player, only before s is revealed, and only if the pool can pay its largest win.
func PlaceCasinoBet(cur realm, roundId string, game string, coinId string, betAmount string, choice string, clientHash string) {
	requireNotPaused()
	caller := cur.Previous().Address().String()
	if isBlacklisted(caller) {
		panic("address banned")
	}
	r := mustCasinoRound(roundId)
	if r.player != caller {
		panic("this round belongs to another player")
	}
	if r.status != "committed" {
		panic("betting is closed for this round")
	}
	if time.Now().Unix()-r.committedAt >= casinoBetWindowSec {
		panic("round expired")
	}
	if _, ok := coinRarity[coinId]; !ok {
		panic("unknown coin id: " + coinId)
	}
	if !validCasinoChoice(game, choice) {
		panic("invalid game or choice: " + game + "/" + choice)
	}
	clientHash = strings.ToLower(clientHash)
	if !casIsHex64(clientHash) {
		panic("client hash must be sha256 hex")
	}
	amt, err := strconv.ParseUint(betAmount, 10, 64)
	if err != nil || amt == 0 || amt > casinoMaxAmount {
		panic("invalid bet amount")
	}
	if game == "slots" && getGrant(caller) != nil {
		panic("finish your free spins first")
	}
	// Check everything before any write, then debit and reserve the largest win.
	casinoCheckBet(coinId, game, amt)
	exp := casinoExposure(game, amt)
	casDebit(caller, coinId, amt)
	casinoReserve(coinId, exp)
	casinoBets.Set(roundId+":"+caller, &casinoBet{addr: caller, game: game, coin: coinId, choice: choice, clientHash: clientHash, amount: amt, exposure: exp})
	r.status = "bet"
	r.betAt = time.Now().Unix()
	r.bets = 1
}

// RevealCasinoSeed publishes s (it must hash to the commit). It settles nothing:
// the bet settles when the player's secret is revealed.
func RevealCasinoSeed(cur realm, roundId string, serverSeed string) {
	if !isOperator(cur) {
		panic("unauthorized: casino operator only")
	}
	r := mustCasinoRound(roundId)
	if r.status != "committed" && r.status != "bet" {
		panic("round already revealed or closed")
	}
	h := sha256.Sum256([]byte(serverSeed))
	if hex.EncodeToString(h[:]) != r.seedHash {
		panic("server seed does not match the committed hash")
	}
	r.serverSeed = serverSeed
	if r.status == "committed" {
		r.status = "closed" // no bet was placed: the round just ends
		return
	}
	r.status = "seeded"
	r.seededAt = time.Now().Unix()
}

// RevealCasinoSecret publishes the player's secret c (anyone may relay it: it
// must hash to the bet's hash) and settles the bet on chain. Works while paused.
func RevealCasinoSecret(cur realm, roundId string, clientSecret string) {
	r := mustCasinoRound(roundId)
	if r.status != "seeded" {
		panic("round is not waiting for the client secret")
	}
	b := casinoRoundBet(r, roundId)
	if b == nil || b.settled {
		panic("no open bet in this round")
	}
	if !casSafe(clientSecret, 64) {
		panic("invalid client secret")
	}
	if sha256Hex(clientSecret) != b.clientHash {
		panic("client secret does not match the bet's hash")
	}
	b.clientSecret = clientSecret
	casinoResolve(roundId, r, b)
	r.status = "settled"
}

// casinoResolve rolls the bet from s and c, pays it, and records the result.
func casinoResolve(roundId string, r *casinoRound, b *casinoBet) {
	payout := uint64(0)
	switch b.game {
	case "slots":
		s := newSlotsStream(r.serverSeed, b.clientSecret, roundId)
		g := slotsSpinGrid(s)
		mult, lines := slotsLineMult(&g)
		sc := slotsCount(&g, symScatter)
		win := casMul(b.amount/slotsBetStep, mult)
		if sc >= 3 {
			win = casAdd(win, casMul(b.amount, slotsScatterPay[sc]))
		}
		b.grid = slotsGridString(&g)
		b.lineMult = mult
		b.lines = lines
		b.scatters = sc
		if b.freeSpin {
			// ×2, no retrigger, no Hold & Spin; paid from the grant's reservation.
			payout = settleFreeSpin(b, casMul(win, freeSpinMult))
			b.payout = payout
			b.won = payout > 0
			b.outcome = "lose"
			if payout > 0 {
				b.outcome = "win"
			}
			b.settled = true
			casRecord(b.coin, "slots", 0, payout)
			casStat(b.coin, "slots", "freeSpins", 1)
			chain.Emit("CasinoBetSettled", "round", roundId, "player", b.addr, "game", "slots", "coin", b.coin,
				"amount", "0", "freeSpin", "true", "outcome", b.outcome, "won", strconv.FormatBool(b.won), "payout", casU(payout))
			return
		}
		major, grand := false, false
		if slotsCount(&g, symVault) >= 3 {
			tiles, played, full := slotsHoldAndSpin(s, &g)
			hm, mj, gr := slotsHSPayout(&tiles, full)
			b.hsTiles = hsTilesString(&tiles)
			b.hsRespins = played
			b.hsMult = hm
			major, grand = mj, gr
			win = casAdd(win, casMul(b.amount, hm))
		}
		capWin := casMul(b.amount, slotsMaxWinMult)
		if win > capWin {
			win = capWin
			b.capped = true
		}
		payout = casinoSettle(b.addr, b.coin, b.amount, b.exposure, win)
		if sc >= 3 {
			// The rest of this spin's 500× cap stays reserved for its free spins
			// (reserved before anything else leaves the pool, so pool ≥ reserved holds).
			n := slotsFreeSpins[sc]
			capLeft := capWin - win
			casinoReserve(b.coin, capLeft)
			casinoGrants.Set(b.addr, &freeSpinGrant{addr: b.addr, coin: b.coin, bet: b.amount, left: n, total: n, capLeft: capLeft, fromRound: roundId, grantedAt: time.Now().Unix()})
			b.fsGranted = n
			chain.Emit("CasinoFreeSpinsGranted", "player", b.addr, "coin", b.coin, "spins", casU(n), "bet", casU(b.amount))
		}
		casinoJackpotContribute(b.coin, b.amount)
		jw := uint64(0)
		if grand {
			jw = casAdd(jw, casinoJackpotPay(b.addr, b.coin, "grand", b.amount))
			b.jackpots = "grand"
		}
		if major {
			jw = casAdd(jw, casinoJackpotPay(b.addr, b.coin, "major", b.amount))
			if b.jackpots != "" {
				b.jackpots = "major+" + b.jackpots
			} else {
				b.jackpots = "major"
			}
		}
		b.jackpotWin = jw
		b.payout = casAdd(payout, jw)
		b.won = b.payout > b.amount
		b.outcome = "lose"
		if b.payout > 0 {
			b.outcome = "win"
		}
		b.settled = true
		casRecord(b.coin, "slots", b.amount, b.payout)
		chain.Emit("CasinoBetSettled", "round", roundId, "player", b.addr, "game", "slots", "coin", b.coin,
			"amount", casU(b.amount), "outcome", b.outcome, "won", strconv.FormatBool(b.won), "payout", casU(b.payout),
			"jackpots", b.jackpots, "freeSpins", casU(b.fsGranted))
		return
	case "rps":
		b.roll = CasinoRoll(r.serverSeed, b.clientSecret, roundId, b.game)
		res := CasinoOutcome("rps", b.roll)
		b.outcome = rpsHouseMove(b.choice, res)
		switch res {
		case "win":
			payout = casAdd(b.amount, b.amount)
			b.won = true
		case "push":
			payout = b.amount
		}
	default:
		b.roll = CasinoRoll(r.serverSeed, b.clientSecret, roundId, b.game)
		b.outcome = CasinoOutcome(b.game, b.roll)
		if b.outcome == b.choice {
			payout = casAdd(b.amount, b.amount)
			b.won = true
		}
	}
	b.payout = casinoSettle(b.addr, b.coin, b.amount, b.exposure, payout)
	b.settled = true
	casRecord(b.coin, b.game, b.amount, b.payout)
	chain.Emit("CasinoBetSettled", "round", roundId, "player", b.addr, "game", b.game, "coin", b.coin,
		"amount", casU(b.amount), "roll", casU(b.roll), "outcome", b.outcome, "won", strconv.FormatBool(b.won), "payout", casU(b.payout))
}

// RefundCasinoBet returns the stake only if s was never revealed and 30 minutes
// have passed since the bet. Never after s is revealed. Works while paused.
func RefundCasinoBet(cur realm, roundId string) {
	caller := cur.Previous().Address().String()
	r := mustCasinoRound(roundId)
	if r.status == "refunded" {
		panic("bet already settled")
	}
	if r.status != "bet" {
		panic("round already revealed: no refunds")
	}
	if r.player != caller {
		panic("no bet found for this round")
	}
	if time.Now().Unix()-r.betAt < casinoSeedTimeoutSec {
		panic("refund opens 30 minutes after the bet if the server seed is never revealed")
	}
	b := casinoRoundBet(r, roundId)
	b.settled = true
	b.refunded = true
	if b.freeSpin {
		// No stake was taken: the free spin goes back to the grant.
		if g := getGrant(caller); g != nil && g.inRound == roundId {
			g.inRound = ""
		}
	} else {
		casSet(&casinoReserved, b.coin, casSub(casGet(&casinoReserved, b.coin), b.exposure))
		casCredit(caller, b.coin, b.amount)
	}
	r.status = "refunded"
	chain.Emit("CasinoBetRefunded", "round", roundId, "player", caller, "amount", casU(b.amount))
}

// ForfeitCasinoBet settles a bet as a loss when s was revealed but the player's
// secret was not within 24 h (only the player could know the result). Anyone.
func ForfeitCasinoBet(cur realm, roundId string) {
	r := mustCasinoRound(roundId)
	if r.status != "seeded" {
		panic("round is not waiting for the client secret")
	}
	if time.Now().Unix()-r.seededAt < casinoSecretTimeoutSec {
		panic("forfeit opens 24 hours after the server seed is revealed")
	}
	b := casinoRoundBet(r, roundId)
	b.forfeited = true
	b.outcome = "forfeit"
	if b.freeSpin {
		b.payout = settleFreeSpin(b, 0) // the free spin is used, it wins nothing
		casRecord(b.coin, b.game, 0, 0)
	} else {
		b.payout = casinoSettle(b.addr, b.coin, b.amount, b.exposure, 0)
		casRecord(b.coin, b.game, b.amount, 0)
	}
	b.settled = true
	r.status = "settled"
	chain.Emit("CasinoBetForfeited", "round", roundId, "player", b.addr, "amount", casU(b.amount))
}

// ── queries ─────────────────────────────────────────────────────────────────

func CasinoRound(roundId string) string {
	r := getCasinoRound(roundId)
	if r == nil {
		return "null"
	}
	return `{"roundId":"` + roundId + `","player":"` + r.player + `","seedHash":"` + r.seedHash + `","serverSeed":"` + r.serverSeed +
		`","status":"` + r.status + `","committedAt":` + strconv.FormatInt(r.committedAt, 10) +
		`,"betAt":` + strconv.FormatInt(r.betAt, 10) + `,"seededAt":` + strconv.FormatInt(r.seededAt, 10) +
		`,"bets":` + strconv.Itoa(r.bets) + `}`
}

// CasinoBet returns one player's bet and its on-chain result.
func CasinoBet(roundId string, addr string) string {
	key := roundId + ":" + addr
	if !casinoBets.Has(key) {
		return "null"
	}
	b := casinoBets.Get(key).(*casinoBet)
	return `{"addr":"` + b.addr + `","game":"` + b.game + `","coinId":"` + b.coin + `","amount":` + casU(b.amount) +
		`,"exposure":` + casU(b.exposure) + `,"choice":"` + b.choice + `","clientHash":"` + b.clientHash +
		`","clientSecret":"` + b.clientSecret + `","clientSeed":"` + b.clientSecret + `","settled":` + strconv.FormatBool(b.settled) +
		`,"refunded":` + strconv.FormatBool(b.refunded) + `,"forfeited":` + strconv.FormatBool(b.forfeited) +
		`,"won":` + strconv.FormatBool(b.won) + `,"roll":` + casU(b.roll) + `,"outcome":"` + b.outcome +
		`","payout":` + casU(b.payout) + `,"grid":"` + b.grid + `","lineMult":` + casU(b.lineMult) +
		`,"lines":` + strconv.Itoa(b.lines) + `,"scatters":` + strconv.Itoa(b.scatters) +
		`,"freeSpin":` + strconv.FormatBool(b.freeSpin) + `,"capped":` + strconv.FormatBool(b.capped) +
		`,"fsGranted":` + casU(b.fsGranted) + `,"hsTiles":"` + b.hsTiles + `","hsRespins":` + strconv.Itoa(b.hsRespins) +
		`,"hsMult":` + casU(b.hsMult) + `,"jackpots":"` + b.jackpots + `","jackpotWin":` + casU(b.jackpotWin) + `}`
}

// JackpotPool reports the GRAND jackpot pool (the casino bankroll is CasinoPool).
func JackpotPool(coinId string) string {
	return `{"pool":"` + casU(casGet(&casinoJackpot, jpKey(coinId, "grand"))) + `","coinId":"` + coinId + `"}`
}

func CasinoHistory(_ string) string { return "[]" }
