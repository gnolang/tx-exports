package game31

import (
	"crypto/sha256"
	"encoding/hex"
	"strconv"
	"strings"
	"time"

)

// ── PvP lobbies ──────────────────────────────────────────────────────────────
//
// Storage (pvpLobbies, string values — PvpLobby(key) can read any of them):
//   <id>                → lobby JSON (re-rendered on every change)
//   <id>:creator / :challenger / :game / :coin / :bet / :status / :createdAt / :last
//   <id>:commit:<addr>  → sha256(choice+":"+salt) hex, written once
//   <id>:reveal:<addr>  → choice (after the hash matched)
//   <id>:salt:<addr>    → salt
//   <id>:winner         → addr | "draw"
// Lobby ids come from a counter, so two lobbies can never collide.
// Status: open → joined → finished | cancelled.

func lget(id, f string) string {
	k := id + ":" + f
	if !pvpLobbies.Has(k) {
		return ""
	}
	return pvpLobbies.Get(k).(string)
}

func lset(id, f, v string) { pvpLobbies.Set(id+":"+f, v) }

func renderLobby(id string) {
	bet := lget(id, "bet")
	if bet == "" {
		bet = "0"
	}
	js := `{"lobbyId":` + jsonStr(id) + `,"creator":` + jsonStr(lget(id, "creator")) +
		`,"challenger":` + jsonStr(lget(id, "challenger")) + `,"game":` + jsonStr(lget(id, "game")) +
		`,"coinId":` + jsonStr(lget(id, "coin")) + `,"betAmount":` + bet +
		`,"status":` + jsonStr(lget(id, "status")) + `,"winner":` + jsonStr(lget(id, "winner")) +
		`,"round":1,"createdAt":` + lget(id, "createdAt") + `}`
	pvpLobbies.Set(id, js)
}

func touch(id string) { lset(id, "last", strconv.FormatInt(time.Now().Unix(), 10)) }

func lastAction(id string) int64 {
	v, _ := strconv.ParseInt(lget(id, "last"), 10, 64)
	return v
}

// CreatePvpLobby escrows the creator's wager and opens a lobby.
func CreatePvpLobby(cur realm, game string, coinId string, betAmount string) string {
	caller := requirePlayer(cur)
	if _, ok := pvpGames[game]; !ok {
		panic("unknown PvP game: " + game)
	}
	if _, ok := coinRarity[coinId]; !ok {
		panic("unknown coin id: " + coinId)
	}
	wager, err := strconv.ParseUint(betAmount, 10, 64)
	if err != nil || wager > 1000000000 {
		panic("invalid bet amount")
	}
	if wager > 0 {
		panic("PvP wagers are off until they are rewritten; create a lobby with bet 0")
	}
	pvpCounter++
	id := "pvp-" + zeroPad(pvpCounter, 10)
	now := strconv.FormatInt(time.Now().Unix(), 10)
	lset(id, "creator", caller)
	lset(id, "game", game)
	lset(id, "coin", coinId)
	lset(id, "bet", strconv.FormatUint(wager, 10))
	lset(id, "status", "open")
	lset(id, "createdAt", now)
	lset(id, "last", now)
	if wager > 0 {
		pvpWagers.Set(id, coinId+":"+strconv.FormatUint(wager, 10)+":"+caller+":")
	}
	renderLobby(id)
	return id
}

func JoinPvpLobby(cur realm, lobbyId string) {
	caller := requirePlayer(cur)
	if lget(lobbyId, "status") != "open" {
		panic("lobby not open")
	}
	creator := lget(lobbyId, "creator")
	if caller == creator {
		panic("cannot join your own lobby")
	}
	if pvpWagered(lobbyId) {
		panic("PvP wagers are off: this wagered lobby can only be refunded")
	}
	wager, _ := strconv.ParseUint(lget(lobbyId, "bet"), 10, 64)
	coin := lget(lobbyId, "coin")
	if wager > 0 {
		debitBal(caller, coin, wager)
		pvpWagers.Set(lobbyId, coin+":"+strconv.FormatUint(wager, 10)+":"+creator+":"+caller)
	}
	lset(lobbyId, "challenger", caller)
	lset(lobbyId, "status", "joined")
	touch(lobbyId)
	renderLobby(lobbyId)
}

// pvpWagered: a lobby that escrowed coins before wagers were switched off.
// It can only be cancelled or refunded after the timeout.
func pvpWagered(id string) bool { b := lget(id, "bet"); return b != "" && b != "0" }

// CancelPvpLobby lets the creator close an open lobby nobody joined (refund).
// Works while paused: a refund of the player's own escrow is never blocked.
func CancelPvpLobby(cur realm, lobbyId string) {
	caller := cur.Previous().Address().String()
	if lget(lobbyId, "status") != "open" || lget(lobbyId, "creator") != caller {
		panic("only the creator can cancel an open lobby")
	}
	settlePvp(lobbyId, "refund")
	lset(lobbyId, "status", "cancelled")
	renderLobby(lobbyId)
}

func memberOf(lobbyId, addr string) bool {
	return addr != "" && (addr == lget(lobbyId, "creator") || addr == lget(lobbyId, "challenger"))
}

// CommitPvpMove stores sha256(choice+":"+salt) for the caller. Members only,
// once per player per lobby, only while the lobby is joined.
func CommitPvpMove(cur realm, lobbyId string, moveHash string) {
	caller := requirePlayer(cur)
	if lget(lobbyId, "status") != "joined" {
		panic("lobby is not in progress")
	}
	if !memberOf(lobbyId, caller) {
		panic("not a lobby participant")
	}
	if lget(lobbyId, "commit:"+caller) != "" {
		panic("move already committed")
	}
	moveHash = strings.ToLower(moveHash)
	if !isHex64(moveHash) {
		panic("moveHash must be sha256(choice:salt) as 64 hex chars")
	}
	lset(lobbyId, "commit:"+caller, moveHash)
	touch(lobbyId)
}

func validChoice(game, choice string) bool {
	for _, c := range pvpGames[game] {
		if c == choice {
			return true
		}
	}
	return false
}

func moveHash(choice, salt string) string {
	h := sha256.Sum256([]byte(choice + ":" + salt))
	return hex.EncodeToString(h[:])
}

// RevealPvpMove reveals a committed move. The tx fails unless
// sha256(choice+":"+salt) equals the stored commit. A matching reveal of an
// invalid choice forfeits the match. When both have revealed, it settles.
func RevealPvpMove(cur realm, lobbyId string, choice string, salt string) {
	caller := requirePlayer(cur)
	if lget(lobbyId, "status") != "joined" {
		panic("lobby is not in progress")
	}
	if !memberOf(lobbyId, caller) {
		panic("not a lobby participant")
	}
	if pvpWagered(lobbyId) {
		panic("PvP wagers are off: this wagered lobby can only be refunded after the timeout")
	}
	creator, challenger := lget(lobbyId, "creator"), lget(lobbyId, "challenger")
	if lget(lobbyId, "commit:"+creator) == "" || lget(lobbyId, "commit:"+challenger) == "" {
		panic("both players must commit moves before revealing")
	}
	if lget(lobbyId, "reveal:"+caller) != "" {
		panic("already revealed")
	}
	if moveHash(choice, salt) != lget(lobbyId, "commit:"+caller) {
		panic("reveal does not match your commit")
	}
	lset(lobbyId, "reveal:"+caller, choice)
	lset(lobbyId, "salt:"+caller, salt)
	touch(lobbyId)

	game := lget(lobbyId, "game")
	if !validChoice(game, choice) {
		// Committed garbage: forfeit to the opponent.
		opp := creator
		if caller == creator {
			opp = challenger
		}
		settlePvp(lobbyId, opp)
		return
	}
	cr, chr := lget(lobbyId, "reveal:"+creator), lget(lobbyId, "reveal:"+challenger)
	if cr == "" || chr == "" {
		renderLobby(lobbyId)
		return
	}
	settlePvp(lobbyId, pvpWinner(game, creator, challenger, cr, chr, lget(lobbyId, "salt:"+creator), lget(lobbyId, "salt:"+challenger)))
}

// pvpWinner: rps uses the usual rules. coin_flip / higher_lower flip a coin
// from sha256(creatorSalt:challengerSalt) — neither player controls it alone —
// and whoever alone called it wins (both or neither right = draw).
func pvpWinner(game, creator, challenger, cChoice, chChoice, cSalt, chSalt string) string {
	if game == "rps" {
		if cChoice == chChoice {
			return "draw"
		}
		if (cChoice == "rock" && chChoice == "scissors") || (cChoice == "scissors" && chChoice == "paper") || (cChoice == "paper" && chChoice == "rock") {
			return creator
		}
		return challenger
	}
	h := sha256.Sum256([]byte(cSalt + ":" + chSalt))
	outcome := pvpGames[game][int(h[0]&1)]
	cOk, chOk := cChoice == outcome, chChoice == outcome
	if cOk && !chOk {
		return creator
	}
	if chOk && !cOk {
		return challenger
	}
	return "draw"
}

// settlePvp pays out the escrow. result = winner addr, "draw" or "refund".
func settlePvp(lobbyId, result string) {
	if pvpWagers.Has(lobbyId) {
		parts := strings.SplitN(pvpWagers.Get(lobbyId).(string), ":", 4)
		if len(parts) == 4 {
			coin := parts[0]
			wager, _ := strconv.ParseUint(parts[1], 10, 64)
			payers := []string{}
			for _, a := range parts[2:] {
				if a != "" {
					payers = append(payers, a)
				}
			}
			if result == "draw" || result == "refund" || len(payers) < 2 {
				for _, a := range payers {
					creditBal(a, coin, wager)
				}
			} else {
				pot := wager * uint64(len(payers))
				rake := pot * pvpRakePct / 100
				creditBal(result, coin, pot-rake)
				creditBal(admin.String(), coin, rake)
			}
		}
		pvpWagers.Remove(lobbyId)
	}
	if result != "refund" {
		lset(lobbyId, "winner", result)
	}
	lset(lobbyId, "status", "finished")
	renderLobby(lobbyId)
}

// ClaimPvpTimeout resolves a stuck match after pvpTimeoutSec without action:
//   - only one player committed → that player wins;
//   - both committed, only one revealed → the revealer wins;
//   - otherwise → both refunded.
// Any lobby member may call it. Escrow can never stay locked.
func ClaimPvpTimeout(cur realm, lobbyId string) {
	caller := cur.Previous().Address().String()
	st := lget(lobbyId, "status")
	if st != "joined" && st != "open" {
		panic("lobby already settled")
	}
	if !memberOf(lobbyId, caller) {
		panic("not a lobby participant")
	}
	if time.Now().Unix()-lastAction(lobbyId) < pvpTimeoutSec {
		panic("timeout not yet claimable — 10 minutes must pass without a move")
	}
	if st == "open" || pvpWagered(lobbyId) {
		settlePvp(lobbyId, "refund")
		lset(lobbyId, "status", "cancelled")
		renderLobby(lobbyId)
		return
	}
	cr, ch := lget(lobbyId, "creator"), lget(lobbyId, "challenger")
	cc, chc := lget(lobbyId, "commit:"+cr) != "", lget(lobbyId, "commit:"+ch) != ""
	rv, chv := lget(lobbyId, "reveal:"+cr) != "", lget(lobbyId, "reveal:"+ch) != ""
	switch {
	case cc && !chc:
		settlePvp(lobbyId, cr)
	case chc && !cc:
		settlePvp(lobbyId, ch)
	case cc && chc && rv && !chv:
		settlePvp(lobbyId, cr)
	case cc && chc && chv && !rv:
		settlePvp(lobbyId, ch)
	default:
		settlePvp(lobbyId, "refund")
	}
}

// ExpireLobbies is a no-op kept for API compatibility (timeouts are per lobby).
func ExpireLobbies(cur realm) {}

func PvpLobby(lobbyId string) string {
	if !pvpLobbies.Has(lobbyId) {
		return "null"
	}
	return pvpLobbies.Get(lobbyId).(string)
}

func OpenLobbies() string {
	var parts []string
	pvpLobbies.Iterate("pvp-", "pvp.", func(key string, val any) bool {
		if !strings.Contains(key, ":") && lget(key, "status") == "open" {
			parts = append(parts, val.(string))
		}
		return len(parts) >= 100
	})
	return "[" + strings.Join(parts, ",") + "]"
}

func sha256Sum(s string) string {
	x := sha256.Sum256([]byte(s))
	return hex.EncodeToString(x[:])
}

// zeroPad formats n with leading zeros to width w (ufmt has no %0Nd).
func zeroPad(n uint64, w int) string {
	s := strconv.FormatUint(n, 10)
	for len(s) < w {
		s = "0" + s
	}
	return s
}
