package gnodice

import (
	"strconv"
	"strings"
)

// Lectures : ces fonctions ne modifient rien. Le site et le croupier les
// appellent gratuitement (sans transaction) pour lire l'état du jeu en JSON.
// Les seules chaînes écrites sont des adresses, des empreintes/graines
// hexadécimales (vérifiées) et des statuts fixes : rien à échapper.

// GetInfoJSON renvoie l'état global du jeu et les dernières parties terminées.
func GetInfoJSON() string {
	t := now()
	var b strings.Builder
	b.WriteString("{")
	str(&b, "owner", owner.String())
	str(&b, "pendingOwner", pendingOwner.String())
	str(&b, "croupier", croupier.String())
	str(&b, "realm", realmAddr.String())
	boolean(&b, "paused", paused)
	num(&b, "bankroll", Bankroll())
	num(&b, "reserved", reserved)
	num(&b, "available", available())
	num(&b, "maxCoverableBet", MaxCoverableBet())
	num(&b, "minBet", MinBet)
	num(&b, "maxBet", MaxBet)
	num(&b, "multiplier", PayoutMultiplier)
	num(&b, "cooldown", CooldownSeconds)
	num(&b, "historySize", HistorySize)
	num(&b, "resolveTimeout", ResolveTimeout)
	num(&b, "revealWindow", RevealWindow)
	num(&b, "totalGames", totalGames)
	num(&b, "totalWins", int64(totalWins))
	num(&b, "totalLosses", int64(totalLosses))
	num(&b, "totalRefunded", int64(totalRefunded))
	num(&b, "totalExpired", int64(totalExpired))
	num(&b, "totalWagered", totalWagered)
	num(&b, "totalPaid", totalPaid)
	num(&b, "totalFunded", totalFunded)
	num(&b, "totalWithdrawn", totalWithdrawn)
	num(&b, "openGames", int64(openGames.Size()))
	num(&b, "dailyPayoutLimit", dailyPayoutLimit)
	todayPaid := int64(0)
	if t/86400 == payoutDay {
		todayPaid = payoutToday
	}
	num(&b, "payoutToday", todayPaid)
	num(&b, "lowBankroll", lowBankroll)
	num(&b, "now", t)
	b.WriteString(`"recent":`)
	writeGameIDs(&b, recent)
	b.WriteString("}")
	return b.String()
}

// GetPlayerJSON renvoie les statistiques d'un joueur, son temps d'attente,
// ses parties en cours et ses 10 dernières parties terminées.
func GetPlayerJSON(addr string) string {
	player := address(addr)
	if !player.IsValid() {
		return `{"error":"adresse invalide"}`
	}
	p := getPlayer(player)
	if p == nil {
		p = &playerData{}
	}
	t := now()
	nextPlayAt := int64(0)
	if p.LastPlay > 0 {
		nextPlayAt = p.LastPlay + CooldownSeconds
	}

	var b strings.Builder
	b.WriteString("{")
	str(&b, "address", player.String())
	num(&b, "played", int64(p.Played))
	num(&b, "wins", int64(p.Wins))
	num(&b, "wagered", p.Wagered)
	num(&b, "paid", p.Paid)
	num(&b, "lastPlay", p.LastPlay)
	num(&b, "nextPlayAt", nextPlayAt)
	num(&b, "cooldownRemaining", cooldownRemaining(p, t))
	boolean(&b, "blocked", isBlocked(player))
	num(&b, "now", t)
	b.WriteString(`"open":`)
	writePlayerOpenGames(&b, player, p.Open)
	b.WriteString(`,"history":`)
	writeGameIDs(&b, p.History)
	b.WriteString("}")
	return b.String()
}

// GetGameJSON renvoie une partie, ou {"error":...} si elle n'existe pas.
func GetGameJSON(id int64) string {
	g := getGame(id)
	if g == nil {
		return `{"error":"partie introuvable"}`
	}
	var b strings.Builder
	writeGame(&b, g)
	return b.String()
}

// GetOpenGamesJSON renvoie les parties en cours (en attente de tirage ou de
// révélation), de la plus ancienne à la plus récente, à partir du numéro
// `after` exclu (pagination ; 0 pour commencer). Utilisé par le croupier.
func GetOpenGamesJSON(after int64) string {
	var b strings.Builder
	b.WriteString("[")
	count := 0
	openGames.Iterate(gameKey(after+1), "", func(key string, _ any) bool {
		v := games.Get(key)
		if count > 0 {
			b.WriteString(",")
		}
		writeGame(&b, v.(*Game))
		count++
		return count >= maxPageSize
	})
	b.WriteString("]")
	return b.String()
}

// --- écriture JSON ---

func writePlayerOpenGames(b *strings.Builder, player address, open int) {
	b.WriteString("[")
	if open > 0 {
		count := 0
		// Les parties en cours sont peu nombreuses (cooldown de 10 min) :
		// on parcourt la liste des parties ouvertes en partant de la plus récente.
		openGames.ReverseIterate("", "", func(key string, _ any) bool {
			v := games.Get(key)
			g := v.(*Game)
			if g.Player == player {
				if count > 0 {
					b.WriteString(",")
				}
				writeGame(b, g)
				count++
			}
			return count >= open || count >= maxPageSize
		})
	}
	b.WriteString("]")
}

// writeGameIDs écrit les parties de la plus récente à la plus ancienne.
func writeGameIDs(b *strings.Builder, ids []int64) {
	b.WriteString("[")
	for i := len(ids) - 1; i >= 0; i-- {
		if i != len(ids)-1 {
			b.WriteString(",")
		}
		writeGame(b, mustGetGame(ids[i]))
	}
	b.WriteString("]")
}

func writeGame(b *strings.Builder, g *Game) {
	b.WriteString("{")
	num(b, "id", g.ID)
	str(b, "player", g.Player.String())
	str(b, "status", g.Status.String())
	str(b, "commitment", g.Commitment)
	str(b, "seed", g.Seed)
	num(b, "guess", int64(g.Guess))
	num(b, "roll", int64(g.Roll))
	num(b, "bet", g.Bet)
	num(b, "payout", g.Payout)
	boolean(b, "won", g.Won())
	num(b, "time", g.PlacedAt)
	num(b, "height", g.PlacedHeight)
	num(b, "rolledAt", g.RolledAt)
	num(b, "settledAt", g.SettledAt)
	b.WriteString(`"resolveDeadline":` + itoa64(g.PlacedAt+ResolveTimeout))
	b.WriteString("}")
}

// Chaque champ est suivi d'une virgule ; le dernier champ d'un objet est
// écrit à la main, sans virgule.
func str(b *strings.Builder, key, value string) {
	b.WriteString(`"` + key + `":"` + value + `",`)
}

func num(b *strings.Builder, key string, value int64) {
	b.WriteString(`"` + key + `":` + strconv.FormatInt(value, 10) + `,`)
}

func boolean(b *strings.Builder, key string, value bool) {
	b.WriteString(`"` + key + `":` + strconv.FormatBool(value) + `,`)
}
