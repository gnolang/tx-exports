package game28

import (
	"strconv"
	"strings"
	"time"

	"gno.land/p/nt/ufmt/v0"
)

// ── Casino ───────────────────────────────────────────────────────────────────

func CommitCasinoSeed(cur realm, roundId string, seedHash string) {
	if !isAdmin(cur) {
		panic("unauthorized")
	}
	casinoRounds.Set(roundId, `{"roundId":"`+roundId+`","seedHash":"`+seedHash+`","status":"committed","bets":[]}`)
}

func PlaceCasinoBet(cur realm, roundId string, game string, coinId string, betAmount string, choice string, clientSeed string) {
	requireNotPaused()
	caller := cur.Previous().Address().String()
	if isBlacklisted(caller) {
		panic("address banned")
	}
	amt, err := strconv.ParseUint(betAmount, 10, 64)
	if err != nil || amt == 0 {
		panic("invalid bet amount")
	}

	balKey := caller + ":" + coinId
	existing := uint64(0)
	if balances.Has(balKey) {
		existing, _ = strconv.ParseUint(balances.Get(balKey).(string), 10, 64)
	}
	if existing < amt {
		panic("insufficient balance")
	}
	balances.Set(balKey, strconv.FormatUint(existing-amt, 10))

	if !casinoRounds.Has(roundId) {
		panic("round not found")
	}
	bet := `{"addr":"` + caller + `","game":"` + game + `","coinId":"` + coinId + `","amount":` + betAmount + `,"choice":"` + choice + `","clientSeed":"` + clientSeed + `"}`
	casinoRounds.Set(roundId+":bet:"+caller, bet)
}

func RevealCasinoSeed(cur realm, roundId string, serverSeed string) {
	if !isAdmin(cur) {
		panic("unauthorized")
	}
	casinoRounds.Set(roundId+":serverSeed", serverSeed)
	casinoRounds.Set(roundId+":status", "revealed")
}

func RefundCasinoBet(cur realm, roundId string) {
	requireNotPaused()
	caller := cur.Previous().Address().String()
	betKey := roundId + ":bet:" + caller
	if !casinoRounds.Has(betKey) {
		panic("no bet found for this round")
	}

	// Parse bet JSON to recover coinId and amount before removing the record.
	// Bet JSON format: {"addr":"...","game":"...","coinId":"...","amount":N,...}
	betJson := casinoRounds.Get(betKey).(string)

	// Extract coinId (quoted string value)
	coinId := ""
	coinIdStart := strings.Index(betJson, `"coinId":"`) + len(`"coinId":"`)
	if coinIdStart > len(`"coinId":"`) {
		coinIdEnd := strings.Index(betJson[coinIdStart:], `"`) + coinIdStart
		if coinIdEnd > coinIdStart {
			coinId = betJson[coinIdStart:coinIdEnd]
		}
	}

	// Extract amount (unquoted numeric value)
	amountStr := ""
	amountStart := strings.Index(betJson, `"amount":`) + len(`"amount":`)
	if amountStart > len(`"amount":`) {
		amountEnd := strings.IndexAny(betJson[amountStart:], `,}`) + amountStart
		if amountEnd > amountStart {
			amountStr = betJson[amountStart:amountEnd]
		}
	}

	amount, _ := strconv.ParseUint(amountStr, 10, 64)
	if amount > 0 && coinId != "" {
		// Restore the deducted balance
		balKey := caller + ":" + coinId
		current := uint64(0)
		if balances.Has(balKey) {
			current, _ = strconv.ParseUint(balances.Get(balKey).(string), 10, 64)
		}
		balances.Set(balKey, strconv.FormatUint(current+amount, 10))
	}

	casinoRounds.Remove(betKey)
}

// ── PvP Lobbies ──────────────────────────────────────────────────────────────

// CreatePvpLobby creates a new PvP lobby and escrows the creator's wager from balances.
// Phase 6: wager > 0 deducts from balances and records the escrow in pvpWagers.
func CreatePvpLobby(cur realm, game string, coinId string, betAmount string) string {
	requireNotPaused()
	caller := cur.Previous().Address().String()
	if isBlacklisted(caller) {
		panic("address banned")
	}

	wager, err := strconv.ParseUint(betAmount, 10, 64)
	if err != nil {
		panic("invalid bet amount")
	}

	// Escrow creator's wager from balances (if wager > 0)
	if wager > 0 {
		balKey := caller + ":" + coinId
		bal := uint64(0)
		if balances.Has(balKey) {
			bal, _ = strconv.ParseUint(balances.Get(balKey).(string), 10, 64)
		}
		if bal < wager {
			panic("insufficient balance for wager: need " + betAmount + " " + coinId)
		}
		balances.Set(balKey, strconv.FormatUint(bal-wager, 10))
	}

	prefix := caller
	if len(prefix) > 8 {
		prefix = caller[:8]
	}
	lobbyId := ufmt.Sprintf("pvp-%s-%d", prefix, time.Now().Unix())
	lobby := `{"lobbyId":"` + lobbyId + `","creator":"` + caller + `","game":"` + game + `","coinId":"` + coinId + `","betAmount":` + betAmount + `,"status":"open","round":1,"createdAt":` + strconv.FormatInt(time.Now().Unix(), 10) + `}`
	pvpLobbies.Set(lobbyId, lobby)

	// Record wager escrow (challenger is empty until JoinPvpLobby)
	if wager > 0 {
		pvpWagers.Set(lobbyId, coinId+":"+betAmount+":"+caller+":")
	}

	return lobbyId
}

// JoinPvpLobby joins an existing PvP lobby and escrows the challenger's matching wager.
// Phase 6: deducts challenger's matching wager from balances and updates pvpWagers.
func JoinPvpLobby(cur realm, lobbyId string) {
	requireNotPaused()
	caller := cur.Previous().Address().String()
	if isBlacklisted(caller) {
		panic("address banned")
	}

	if !pvpLobbies.Has(lobbyId) {
		panic("lobby not found")
	}
	if pvpLobbies.Has(lobbyId + ":challenger") {
		panic("lobby already full")
	}

	// Parse coinId and betAmount from wager record
	if pvpWagers.Has(lobbyId) {
		wagerStr := pvpWagers.Get(lobbyId).(string)
		parts := strings.SplitN(wagerStr, ":", 4)
		if len(parts) == 4 {
			coinId := parts[0]
			betAmountStr := parts[1]
			creator := parts[2]

			if caller == creator {
				panic("cannot join your own lobby")
			}

			wager, _ := strconv.ParseUint(betAmountStr, 10, 64)
			if wager > 0 {
				// Escrow challenger's matching wager
				balKey := caller + ":" + coinId
				bal := uint64(0)
				if balances.Has(balKey) {
					bal, _ = strconv.ParseUint(balances.Get(balKey).(string), 10, 64)
				}
				if bal < wager {
					panic("insufficient balance for wager: need " + betAmountStr + " " + coinId)
				}
				balances.Set(balKey, strconv.FormatUint(bal-wager, 10))
				// Update wager record with challenger address
				pvpWagers.Set(lobbyId, coinId+":"+betAmountStr+":"+creator+":"+caller)
			}
		}
	}

	pvpLobbies.Set(lobbyId+":challenger", caller)
	pvpLobbies.Set(lobbyId+":status", "joined")
}

func CommitPvpMove(cur realm, lobbyId string, moveHash string) {
	requireNotPaused()
	caller := cur.Previous().Address().String()
	pvpLobbies.Set(lobbyId+":commit:"+caller, moveHash)
}

// RevealPvpMove requires both players to have committed before either can reveal.
// Phase 6: when both players have revealed, determines the RPS winner and pays out
// 2× wager minus 2% rake to the winner. Draw = full refund to both players.
// pvpWagers.Remove is called after payout to prevent double-payouts.
func RevealPvpMove(cur realm, lobbyId string, choice string, salt string) {
	requireNotPaused()
	caller := cur.Previous().Address().String()

	// Verify lobby exists and both players have committed
	if !pvpLobbies.Has(lobbyId) {
		panic("lobby not found")
	}
	lobbyJson := pvpLobbies.Get(lobbyId).(string)
	// Extract creator address from JSON
	creatorStart := strings.Index(lobbyJson, `"creator":"`) + len(`"creator":"`)
	creatorEnd := strings.Index(lobbyJson[creatorStart:], `"`) + creatorStart
	creator := lobbyJson[creatorStart:creatorEnd]

	// Require challenger has joined
	if !pvpLobbies.Has(lobbyId + ":challenger") {
		panic("no opponent has joined yet")
	}
	challenger := pvpLobbies.Get(lobbyId + ":challenger").(string)

	// Require both commits are present
	if !pvpLobbies.Has(lobbyId+":commit:"+creator) || !pvpLobbies.Has(lobbyId+":commit:"+challenger) {
		panic("both players must commit moves before revealing")
	}

	pvpLobbies.Set(lobbyId+":reveal:"+caller, choice+":"+salt)

	// Check if both players have now revealed
	creatorRevealed := pvpLobbies.Has(lobbyId + ":reveal:" + creator)
	challengerRevealed := pvpLobbies.Has(lobbyId + ":reveal:" + challenger)

	if creatorRevealed && challengerRevealed {
		// Both revealed — determine winner and pay out
		creatorReveal := pvpLobbies.Get(lobbyId + ":reveal:" + creator).(string)
		challengerReveal := pvpLobbies.Get(lobbyId + ":reveal:" + challenger).(string)

		creatorChoice := strings.SplitN(creatorReveal, ":", 2)[0]
		challengerChoice := strings.SplitN(challengerReveal, ":", 2)[0]

		winner := ""
		// Rock-Paper-Scissors logic: rock beats scissors, scissors beats paper, paper beats rock
		if creatorChoice == challengerChoice {
			winner = "draw"
		} else if (creatorChoice == "rock" && challengerChoice == "scissors") ||
			(creatorChoice == "scissors" && challengerChoice == "paper") ||
			(creatorChoice == "paper" && challengerChoice == "rock") {
			winner = creator
		} else {
			winner = challenger
		}

		pvpLobbies.Set(lobbyId+":winner", winner)
		pvpLobbies.Set(lobbyId+":status", "finished")

		// Pay out wager to winner (or refund both on draw)
		if pvpWagers.Has(lobbyId) {
			wagerStr := pvpWagers.Get(lobbyId).(string)
			parts := strings.SplitN(wagerStr, ":", 4)
			if len(parts) == 4 {
				coinId := parts[0]
				wager, _ := strconv.ParseUint(parts[1], 10, 64)

				if wager > 0 {
					rake := wager * 2 / 100  // 2% rake to admin
					payout := (wager * 2) - rake

					if winner == "draw" {
						// Refund both players their wager
						for _, addr := range []string{creator, challenger} {
							balKey := addr + ":" + coinId
							bal := uint64(0)
							if balances.Has(balKey) {
								bal, _ = strconv.ParseUint(balances.Get(balKey).(string), 10, 64)
							}
							balances.Set(balKey, strconv.FormatUint(bal+wager, 10))
						}
					} else {
						// Pay winner 2× wager minus 2% rake
						winKey := winner + ":" + coinId
						winBal := uint64(0)
						if balances.Has(winKey) {
							winBal, _ = strconv.ParseUint(balances.Get(winKey).(string), 10, 64)
						}
						balances.Set(winKey, strconv.FormatUint(winBal+payout, 10))

						// Rake goes to admin
						adminKey := admin.String() + ":" + coinId
						adminBal := uint64(0)
						if balances.Has(adminKey) {
							adminBal, _ = strconv.ParseUint(balances.Get(adminKey).(string), 10, 64)
						}
						balances.Set(adminKey, strconv.FormatUint(adminBal+rake, 10))
					}

					// Remove wager record after payout to prevent double-payouts
					pvpWagers.Remove(lobbyId)
				}
			}
		}
	} else {
		pvpLobbies.Set(lobbyId+":status", "revealed")
	}
}

// ClaimPvpTimeout allows a lobby participant to claim a timeout win.
// Only the creator or challenger may call this.
// Phase 6: refunds the escrowed wager to all parties who contributed.
func ClaimPvpTimeout(cur realm, lobbyId string) {
	requireNotPaused()
	caller := cur.Previous().Address().String()

	if !pvpLobbies.Has(lobbyId) {
		panic("lobby not found")
	}
	lobbyJson := pvpLobbies.Get(lobbyId).(string)

	// Extract creator address
	creatorStart := strings.Index(lobbyJson, `"creator":"`) + len(`"creator":"`)
	creatorEnd := strings.Index(lobbyJson[creatorStart:], `"`) + creatorStart
	creator := lobbyJson[creatorStart:creatorEnd]

	// Get challenger (may not exist yet)
	challenger := ""
	if pvpLobbies.Has(lobbyId + ":challenger") {
		challenger = pvpLobbies.Get(lobbyId + ":challenger").(string)
	}

	// Verify caller is a participant
	if caller != creator && caller != challenger {
		panic("not a lobby participant")
	}

	// Require minimum 10 minutes since lobby creation
	createdAtStart := strings.Index(lobbyJson, `"createdAt":`) + len(`"createdAt":`)
	createdAtEnd := strings.IndexAny(lobbyJson[createdAtStart:], `,}`) + createdAtStart
	createdAt, _ := strconv.ParseInt(lobbyJson[createdAtStart:createdAtEnd], 10, 64)
	if time.Now().Unix()-createdAt < 600 {
		panic("timeout not yet claimable — minimum 10 minutes must elapse")
	}

	pvpLobbies.Set(lobbyId+":winner", caller)
	pvpLobbies.Set(lobbyId+":status", "finished")

	// Phase 6: Refund escrowed wagers.
	// On timeout the creator always escrowed; the challenger may or may not have joined.
	// Refund both if they both escrowed (challenger joined but neither revealed in time).
	// If only the creator escrowed (challenger never joined), refund only the creator.
	if pvpWagers.Has(lobbyId) {
		wagerStr := pvpWagers.Get(lobbyId).(string)
		parts := strings.SplitN(wagerStr, ":", 4)
		if len(parts) == 4 {
			coinId := parts[0]
			wager, _ := strconv.ParseUint(parts[1], 10, 64)
			creatorInWager := parts[2]
			challengerInWager := parts[3]
			// Refund whoever escrowed (creator always did; challenger may have joined)
			if wager > 0 {
				for _, addr := range []string{creatorInWager, challengerInWager} {
					if addr == "" {
						continue
					}
					balKey := addr + ":" + coinId
					bal := uint64(0)
					if balances.Has(balKey) {
						bal, _ = strconv.ParseUint(balances.Get(balKey).(string), 10, 64)
					}
					balances.Set(balKey, strconv.FormatUint(bal+wager, 10))
				}
				pvpWagers.Remove(lobbyId)
			}
		}
	}
}

func ExpireLobbies(cur realm) {
	if !isAdmin(cur) {
		panic("unauthorized")
	}
}
