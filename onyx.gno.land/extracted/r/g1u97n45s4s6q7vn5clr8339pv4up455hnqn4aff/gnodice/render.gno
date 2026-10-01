package gnodice

import (
	"strconv"
	"strings"
)

// Render affiche une page lisible sur gnoweb (le site officiel de gno.land).
//   - chemin ""               : règles, banque et dernières parties
//   - chemin "player/<g1...>" : statistiques et historique d'un joueur
//   - chemin "game/<numéro>"  : une partie, avec de quoi vérifier le tirage
//
// Le chemin est choisi par le visiteur : on ne l'affiche jamais tel quel, on
// n'utilise qu'une adresse ou un numéro validés.
func Render(path string) string {
	switch {
	case strings.HasPrefix(path, "player/"):
		player := address(strings.TrimPrefix(path, "player/"))
		if !player.IsValid() {
			return "# GNO-DICE\n\nAdresse invalide.\n"
		}
		return renderPlayer(player)
	case strings.HasPrefix(path, "game/"):
		id, err := strconv.ParseInt(strings.TrimPrefix(path, "game/"), 10, 64)
		if err != nil || getGame(id) == nil {
			return "# GNO-DICE\n\nPartie introuvable.\n"
		}
		return renderGame(getGame(id))
	}
	return renderHome()
}

func renderHome() string {
	var b strings.Builder
	b.WriteString("# 🎲 GNO-DICE\n\n")
	b.WriteString("Choisis un chiffre de 1 à 6, mise entre 1 et 10 GNOT. ")
	b.WriteString("Si le dé tombe sur ton chiffre, tu gagnes **5 fois ta mise**. ")
	b.WriteString("Un lancer toutes les 10 minutes.\n\n")
	b.WriteString("Le jeu est **prouvablement équitable** : ton chiffre reste caché (empreinte SHA-256) pendant que le croupier tire le dé, ")
	b.WriteString("puis il est dévoilé et vérifié par le contrat. Chaque tirage publie sa graine : `game/<numéro>` pour le vérifier.\n\n")

	if paused {
		b.WriteString("> ⏸️ Le jeu est actuellement en pause.\n\n")
	}

	b.WriteString("## Banque\n\n")
	b.WriteString("- Solde : " + formatGnot(Bankroll()) + " GNOT (dont " + formatGnot(reserved) + " réservés aux parties en cours)\n")
	b.WriteString("- Mise maximale acceptée en ce moment : " + formatGnot(MaxCoverableBet()) + " GNOT\n")
	b.WriteString("- Parties : " + itoa64(totalGames) + " (" + strconv.Itoa(totalWins) + " gagnées, " + strconv.Itoa(openGames.Size()) + " en cours)\n")
	b.WriteString("- Total misé : " + formatGnot(totalWagered) + " GNOT, total payé : " + formatGnot(totalPaid) + " GNOT\n\n")

	b.WriteString("## Dernières parties\n\n")
	writeGamesTable(&b, recent, true)
	return b.String()
}

func renderPlayer(player address) string {
	var b strings.Builder
	b.WriteString("# 🎲 GNO-DICE : joueur\n\n")
	b.WriteString("`" + player.String() + "`\n\n")

	p := getPlayer(player)
	if p == nil {
		b.WriteString("Aucune partie jouée pour l'instant.\n")
		return b.String()
	}
	b.WriteString("- Parties terminées : " + strconv.Itoa(p.Played) + " (" + strconv.Itoa(p.Wins) + " gagnées), en cours : " + strconv.Itoa(p.Open) + "\n")
	b.WriteString("- Total misé : " + formatGnot(p.Wagered) + " GNOT, total gagné : " + formatGnot(p.Paid) + " GNOT\n\n")
	b.WriteString("## Dernières parties\n\n")
	writeGamesTable(&b, p.History, false)
	return b.String()
}

func renderGame(g *Game) string {
	var b strings.Builder
	b.WriteString("# 🎲 GNO-DICE : partie n° " + itoa64(g.ID) + "\n\n")
	b.WriteString("- Joueur : `" + g.Player.String() + "`\n")
	b.WriteString("- Mise : " + formatGnot(g.Bet) + " GNOT, bloc " + itoa64(g.PlacedHeight) + "\n")
	b.WriteString("- Statut : " + g.Status.String() + "\n")
	b.WriteString("- Empreinte du chiffre : `" + g.Commitment + "`\n")
	if g.Seed != "" {
		b.WriteString("- Graine du croupier : `" + g.Seed + "`\n")
		b.WriteString("- Dé : **" + strconv.Itoa(g.Roll) + "**\n")
	}
	if g.Guess != 0 {
		b.WriteString("- Chiffre dévoilé : **" + strconv.Itoa(g.Guess) + "**\n")
	}
	if g.Payout > 0 {
		b.WriteString("- Versé au joueur : " + formatGnot(g.Payout) + " GNOT\n")
	}
	b.WriteString("\n### Vérifier ce tirage\n\n")
	b.WriteString("dé = 1 + (8 premiers octets de sha256(\"gnodice|v1|roll|\" + graine + \"|\" + empreinte + \"|\" + numéro)) mod 6\n")
	return b.String()
}

func writeGamesTable(b *strings.Builder, ids []int64, withPlayer bool) {
	if len(ids) == 0 {
		b.WriteString("Aucune partie terminée pour l'instant.\n")
		return
	}
	if withPlayer {
		b.WriteString("| # | Bloc | Joueur | Mise | Chiffre | Dé | Résultat |\n")
		b.WriteString("|---|---|---|---|---|---|---|\n")
	} else {
		b.WriteString("| # | Bloc | Mise | Chiffre | Dé | Résultat |\n")
		b.WriteString("|---|---|---|---|---|---|\n")
	}
	for i := len(ids) - 1; i >= 0; i-- {
		g := mustGetGame(ids[i])
		b.WriteString("| [" + itoa64(g.ID) + "](:game/" + itoa64(g.ID) + ") | " + itoa64(g.PlacedHeight) + " | ")
		if withPlayer {
			b.WriteString(shortAddress(g.Player) + " | ")
		}
		b.WriteString(formatGnot(g.Bet) + " GNOT | " + digitOrDash(g.Guess) + " | " + digitOrDash(g.Roll) + " | ")
		switch g.Status {
		case StatusWon:
			b.WriteString("✅ +" + formatGnot(g.Payout) + " GNOT |\n")
		case StatusRefunded:
			b.WriteString("↩️ remboursé |\n")
		case StatusExpired:
			b.WriteString("⌛ expiré |\n")
		default:
			b.WriteString("❌ perdu |\n")
		}
	}
}

func digitOrDash(v int) string {
	if v == 0 {
		return "-"
	}
	return strconv.Itoa(v)
}

// shortAddress raccourcit une adresse : g1abcd...wxyz
func shortAddress(a address) string {
	s := a.String()
	if len(s) <= 12 {
		return s
	}
	return s[:6] + "..." + s[len(s)-4:]
}

// formatGnot convertit des ugnot en GNOT lisibles : 1500000 -> "1.5"
func formatGnot(ugnot int64) string {
	sign := ""
	if ugnot < 0 {
		sign = "-"
		ugnot = -ugnot
	}
	whole := ugnot / UgnotPerGnot
	frac := ugnot % UgnotPerGnot
	if frac == 0 {
		return sign + itoa64(whole)
	}
	fracStr := itoa64(frac + UgnotPerGnot)[1:] // complète avec des zéros : 500000 -> "500000"
	fracStr = strings.TrimRight(fracStr, "0")
	return sign + itoa64(whole) + "." + fracStr
}
