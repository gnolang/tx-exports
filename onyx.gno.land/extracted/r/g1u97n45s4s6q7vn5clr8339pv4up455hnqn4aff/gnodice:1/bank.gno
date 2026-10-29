package gnodice

import (
	"chain"
	"chain/banker"
	"chain/runtime/unsafe"
)

// La banque du jeu : son solde est celui de l'adresse du contrat.
// Une partie de ce solde est « réservée » : c'est le gain maximal promis aux
// parties en cours. Seul le reste (« disponible ») peut couvrir de nouvelles
// mises ou être retiré par le propriétaire.

// Fund alimente la banque. N'importe qui peut l'appeler en envoyant des GNOT.
func Fund(cur realm) {
	caller := cur.Previous()
	if !caller.IsUserCall() {
		panic("gnodice: Fund doit être appelé directement depuis un wallet")
	}
	sent := unsafe.OriginSend()
	if len(sent) != 1 || sent[0].Denom != Denom || sent[0].Amount <= 0 {
		panic("gnodice: envoie des GNOT (et uniquement des GNOT) pour alimenter la banque")
	}
	totalFunded += sent[0].Amount
	chain.Emit("BankFunded", "from", caller.Address().String(), "amount", itoa64(sent[0].Amount))
}

// Withdraw retire des GNOT DISPONIBLES vers le propriétaire. L'argent réservé
// aux parties en cours ne peut pas être retiré. amount est en ugnot.
func Withdraw(cur realm, amount int64) {
	assertOwner(cur)
	if amount <= 0 {
		panic("gnodice: montant invalide")
	}
	if amount > available() {
		panic("gnodice: montant supérieur au solde disponible (hors réserve des parties en cours)")
	}
	totalWithdrawn += amount
	chain.Emit("BankWithdrawn", "to", owner.String(), "amount", itoa64(amount))
	pay(cur, owner, amount) // en dernier
	checkLowBankroll()
}

// Bankroll renvoie le solde total de la banque en ugnot.
func Bankroll() int64 {
	return banker.NewReadonlyBanker().GetCoin(realmAddr, Denom)
}

// Reserved renvoie la somme réservée aux parties en cours, en ugnot.
func Reserved() int64 {
	return reserved
}

// Available renvoie le solde libre (non réservé), en ugnot.
func Available() int64 {
	return available()
}

// MaxCoverableBet renvoie la plus grosse mise (en ugnot) acceptée en ce moment.
// Une mise b arrive dans la banque puis réserve 5 x b : il faut donc
// disponible + b >= 5 x b, soit b <= disponible / 4.
// Renvoie 0 si le jeu est en pause ou si la limite du jour est atteinte.
func MaxCoverableBet() int64 {
	if paused || dailyLimitReached(now()) {
		return 0
	}
	max := available() / (PayoutMultiplier - 1)
	if max > MaxBet {
		return MaxBet
	}
	if max < 0 {
		return 0
	}
	return max
}

func available() int64 {
	return Bankroll() - reserved
}

// rollDay remet le compteur de gains à zéro quand on change de jour.
func rollDay(t int64) {
	day := t / 86400
	if day != payoutDay {
		payoutDay = day
		payoutToday = 0
	}
}

func dailyLimitReached(t int64) bool {
	if t/86400 != payoutDay {
		return false
	}
	return payoutToday >= dailyPayoutLimit
}

// recordPayout compte un gain payé. Coupe-circuit : si les gains du jour
// dépassent la limite (signe possible d'une attaque ou d'un croupier
// compromis), le jeu se met en pause tout seul. Le gain en cours est quand
// même payé : le joueur a gagné honnêtement.
func recordPayout(amount int64) {
	rollDay(now())
	payoutToday += amount
	if payoutToday >= dailyPayoutLimit && !paused {
		paused = true
		chain.Emit("CircuitBreakerTripped", "payoutToday", itoa64(payoutToday), "limit", itoa64(dailyPayoutLimit))
		chain.Emit("PauseChanged", "paused", "true", "by", "circuit-breaker")
	}
}

// checkLowBankroll émet une alerte quand le solde disponible passe sous le seuil.
func checkLowBankroll() {
	if a := available(); a < lowBankroll {
		chain.Emit("BankrollLow", "available", itoa64(a), "threshold", itoa64(lowBankroll))
	}
}
