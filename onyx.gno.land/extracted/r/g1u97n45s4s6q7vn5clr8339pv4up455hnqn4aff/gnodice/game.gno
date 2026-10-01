package gnodice

import (
	"chain"
	"chain/banker"
	"chain/runtime/unsafe"
	"strconv"
)

// Les étapes d'une partie : Play -> Resolve -> Reveal, avec deux sorties de
// secours, Refund (croupier trop lent) et Expire (chiffre jamais dévoilé).
// Règle d'or suivie partout : on vérifie, puis on met à jour l'état, et on
// envoie l'argent en tout dernier (contrôles -> effets -> paiement).

// Play mise sur un chiffre caché. Le joueur envoie sa mise (1 à 10 GNOT) avec
// la transaction et l'empreinte de son chiffre (voir Commitment).
// Renvoie le numéro de la partie, par exemple "id=42".
func Play(cur realm, commitment string) string {
	caller := cur.Previous()

	// La mise est lue dans « l'enveloppe » de la transaction (OriginSend) :
	// ce n'est fiable que pour un appel direct depuis un wallet (MsgCall).
	// Un script (MsgRun) ou un autre contrat pourrait détourner ces GNOT.
	if !caller.IsUserCall() {
		panic("gnodice: Play doit être appelé directement depuis un wallet")
	}
	player := caller.Address()
	if paused {
		panic("gnodice: le jeu est en pause")
	}
	if isBlocked(player) {
		panic("gnodice: cette adresse n'est pas autorisée à jouer")
	}
	if !isHex64(commitment) {
		panic("gnodice: empreinte invalide (64 caractères hexadécimaux attendus)")
	}
	bet := receivedBet()

	t := now()
	rollDay(t)
	if payoutToday >= dailyPayoutLimit {
		panic("gnodice: limite de gains du jour atteinte, réessaie demain")
	}

	p := getPlayer(player)
	if wait := cooldownRemaining(p, t); wait > 0 {
		panic("gnodice: attends encore " + formatDuration(wait) + " avant de rejouer")
	}

	// La banque (qui contient déjà la mise reçue) doit pouvoir couvrir le gain
	// maximal EN PLUS de tout ce qu'elle a déjà promis aux parties en cours.
	game := &Game{
		Player:       player,
		Commitment:   commitment,
		Bet:          bet,
		Status:       StatusPending,
		PlacedAt:     t,
		PlacedHeight: height(),
	}
	if available() < game.reservation() {
		panic("gnodice: la banque ne peut pas couvrir ce gain, essaie une mise plus petite")
	}

	// Effets
	totalGames++
	game.ID = totalGames
	games.Set(gameKey(game.ID), game)
	openGames.Set(gameKey(game.ID), true)
	reserved += game.reservation()

	if p == nil {
		p = &playerData{}
		players.Set(player.String(), p)
	}
	p.LastPlay = t
	p.Open++
	p.Wagered += bet
	totalWagered += bet

	chain.Emit(
		"GamePlaced",
		"id", itoa64(game.ID),
		"player", player.String(),
		"bet", itoa64(bet),
		"commitment", commitment,
	)
	return "id=" + itoa64(game.ID)
}

// Resolve tire le dé d'une partie en attente. Réservé au croupier, qui fournit
// une graine aléatoire de 32 octets (64 caractères hexadécimaux) sans connaître
// le chiffre du joueur. La graine est publiée : chacun peut refaire le calcul.
func Resolve(cur realm, id int64, seed string) {
	caller := cur.Previous()
	if !caller.IsUserCall() || caller.Address() != croupier {
		panic("gnodice: seul le croupier peut tirer les dés")
	}
	if !isHex64(seed) {
		panic("gnodice: graine invalide (64 caractères hexadécimaux attendus)")
	}
	g := mustGetGame(id)
	if g.Status != StatusPending {
		panic("gnodice: cette partie n'attend pas de tirage")
	}
	// Fenêtres disjointes : avant la limite, seul le tirage est possible ;
	// après, seul le remboursement. Sinon un joueur qui voit passer un tirage
	// tardif (et sa graine) pourrait le devancer avec Refund s'il a perdu.
	if now() >= g.PlacedAt+ResolveTimeout {
		panic("gnodice: délai de tirage dépassé, la partie doit être remboursée")
	}

	g.Seed = seed
	g.Roll = rollFromSeed(seed, g.Commitment, g.ID)
	g.Status = StatusRolled
	g.RolledAt = now()

	chain.Emit("DiceRolled", "id", itoa64(g.ID), "player", g.Player.String(), "roll", strconv.Itoa(g.Roll), "seed", seed)
}

// Reveal dévoile le chiffre caché et termine la partie. N'importe qui peut
// l'appeler (le joueur ou le service du site) : le gain va toujours au joueur.
// Renvoie le résultat, par exemple "roll=4;won=true;payout=50000000".
func Reveal(cur realm, id int64, guess int, salt string) string {
	g := mustGetGame(id)
	if g.Status != StatusRolled {
		panic("gnodice: cette partie ne peut pas être dévoilée maintenant")
	}
	if now() > g.RolledAt+RevealWindow {
		panic("gnodice: délai dépassé, la partie a expiré")
	}
	if guess < 1 || guess > DieFaces {
		panic("gnodice: le chiffre doit être entre 1 et 6")
	}
	if !isHex64(salt) {
		panic("gnodice: secret invalide (64 caractères hexadécimaux attendus)")
	}
	if Commitment(g.Player, guess, salt) != g.Commitment {
		panic("gnodice: le chiffre ou le secret ne correspond pas à l'empreinte")
	}

	g.Guess = guess
	won := guess == g.Roll
	payout := int64(0)
	if won {
		payout = g.reservation()
		g.Status = StatusWon
	} else {
		g.Status = StatusLost
	}
	g.Payout = payout
	finish(g)

	p := getPlayer(g.Player)
	p.Played++
	p.Paid += payout
	if won {
		p.Wins++
		totalWins++
	} else {
		totalLosses++
	}
	totalPaid += payout

	chain.Emit(
		"GameSettled",
		"id", itoa64(g.ID),
		"player", g.Player.String(),
		"guess", strconv.Itoa(guess),
		"roll", strconv.Itoa(g.Roll),
		"bet", itoa64(g.Bet),
		"payout", itoa64(payout),
		"won", strconv.FormatBool(won),
	)

	if won {
		recordPayout(payout)
		pay(cur, g.Player, payout) // en dernier
	}
	checkLowBankroll()
	return "roll=" + strconv.Itoa(g.Roll) + ";won=" + strconv.FormatBool(won) + ";payout=" + itoa64(payout)
}

// Refund rend sa mise au joueur si le croupier n'a pas tiré le dé à temps
// (ResolveTimeout). N'importe qui peut le déclencher : l'argent va au joueur.
func Refund(cur realm, id int64) {
	g := mustGetGame(id)
	if g.Status != StatusPending {
		panic("gnodice: seule une partie en attente de tirage peut être remboursée")
	}
	if now() < g.PlacedAt+ResolveTimeout {
		panic("gnodice: le croupier a encore " + formatDuration(g.PlacedAt+ResolveTimeout-now()) + " pour tirer le dé")
	}

	g.Status = StatusRefunded
	g.Payout = g.Bet
	finish(g)

	p := getPlayer(g.Player)
	p.Wagered -= g.Bet
	totalWagered -= g.Bet
	totalRefunded++

	chain.Emit("GameRefunded", "id", itoa64(g.ID), "player", g.Player.String(), "amount", itoa64(g.Bet))
	pay(cur, g.Player, g.Bet) // en dernier
}

// Expire termine une partie dont le chiffre n'a jamais été dévoilé
// (RevealWindow) : elle compte comme perdue et la réserve est libérée.
// N'importe qui peut l'appeler.
func Expire(cur realm, id int64) {
	g := mustGetGame(id)
	if g.Status != StatusRolled {
		panic("gnodice: seule une partie tirée et non dévoilée peut expirer")
	}
	if now() <= g.RolledAt+RevealWindow {
		panic("gnodice: le joueur peut encore dévoiler son chiffre")
	}

	g.Status = StatusExpired
	finish(g)

	p := getPlayer(g.Player)
	p.Played++
	totalExpired++

	chain.Emit("GameExpired", "id", itoa64(g.ID), "player", g.Player.String())
}

// --- outils internes ---

// receivedBet vérifie la mise envoyée avec la transaction et renvoie son montant.
func receivedBet() int64 {
	sent := unsafe.OriginSend()
	if len(sent) != 1 || sent[0].Denom != Denom {
		panic("gnodice: envoie ta mise en GNOT uniquement")
	}
	amount := sent[0].Amount
	if amount < MinBet || amount > MaxBet {
		panic("gnodice: la mise doit être entre 1 et 10 GNOT")
	}
	return amount
}

// finish : partie terminée. Libère la réserve, la retire des parties en cours
// et l'ajoute aux historiques.
func finish(g *Game) {
	g.SettledAt = now()
	reserved -= g.reservation()
	openGames.Remove(gameKey(g.ID))
	p := getPlayer(g.Player)
	p.Open--
	p.History = pushID(p.History, g.ID)
	recent = pushID(recent, g.ID)
}

// pay envoie des GNOT de la banque vers une adresse.
func pay(cur realm, to address, amount int64) {
	bk := banker.NewBanker(banker.BankerTypeRealmSend, cur)
	bk.SendCoins(realmAddr, to, chain.NewCoins(chain.NewCoin(Denom, amount)))
}

// cooldownRemaining renvoie le nombre de secondes à attendre avant de pouvoir
// rejouer (0 si le joueur peut jouer maintenant).
func cooldownRemaining(p *playerData, t int64) int64 {
	if p == nil || p.LastPlay == 0 {
		return 0
	}
	wait := p.LastPlay + CooldownSeconds - t
	if wait < 0 {
		return 0
	}
	return wait
}

// formatDuration transforme un nombre de secondes en texte, ex. "7 min 12 s".
func formatDuration(seconds int64) string {
	if seconds < 60 {
		return itoa64(seconds) + " s"
	}
	return itoa64(seconds/60) + " min " + itoa64(seconds%60) + " s"
}
