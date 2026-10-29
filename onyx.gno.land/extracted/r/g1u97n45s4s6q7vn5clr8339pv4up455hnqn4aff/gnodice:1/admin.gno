package gnodice

import (
	"chain"
	"strconv"
)

// Administration : réservée au propriétaire (sauf AcceptOwnership).
// Chaque action émet un événement on-chain, pour garder une trace publique.

// SetPaused met le jeu en pause (true) ou le relance (false). En pause, les
// nouvelles mises sont refusées mais les parties en cours peuvent se terminer.
func SetPaused(cur realm, value bool) {
	assertOwner(cur)
	paused = value
	chain.Emit("PauseChanged", "paused", strconv.FormatBool(value), "by", "owner")
}

// SetCroupier désigne l'adresse du service qui tire les dés.
func SetCroupier(cur realm, addr address) {
	assertOwner(cur)
	if !addr.IsValid() {
		panic("gnodice: adresse invalide")
	}
	previous := croupier
	croupier = addr
	chain.Emit("CroupierChanged", "from", previous.String(), "to", addr.String())
}

// SetBlocked interdit (true) ou autorise de nouveau (false) une adresse à jouer.
// Les parties déjà en cours de cette adresse se terminent normalement.
func SetBlocked(cur realm, addr address, value bool) {
	assertOwner(cur)
	if !addr.IsValid() {
		panic("gnodice: adresse invalide")
	}
	if value {
		blocked.Set(addr.String(), true)
	} else {
		blocked.Remove(addr.String())
	}
	chain.Emit("PlayerBlocked", "player", addr.String(), "blocked", strconv.FormatBool(value))
}

// SetLimits règle le coupe-circuit (gains maximum par jour) et le seuil
// d'alerte de la banque, en ugnot.
func SetLimits(cur realm, dailyLimit, lowBankrollThreshold int64) {
	assertOwner(cur)
	if dailyLimit < MaxBet*PayoutMultiplier {
		panic("gnodice: la limite du jour doit couvrir au moins un gain maximal (50 GNOT)")
	}
	if lowBankrollThreshold < 0 {
		panic("gnodice: seuil invalide")
	}
	dailyPayoutLimit = dailyLimit
	lowBankroll = lowBankrollThreshold
	chain.Emit("LimitsChanged", "dailyPayoutLimit", itoa64(dailyLimit), "lowBankroll", itoa64(lowBankrollThreshold))
}

// TransferOwnership PROPOSE un nouveau propriétaire. Il ne devient
// propriétaire qu'en appelant AcceptOwnership : une faute de frappe dans
// l'adresse ne fait donc jamais perdre le contrôle du contrat.
func TransferOwnership(cur realm, newOwner address) {
	assertOwner(cur)
	if !newOwner.IsValid() {
		panic("gnodice: adresse invalide")
	}
	pendingOwner = newOwner
	chain.Emit("OwnershipProposed", "from", owner.String(), "to", newOwner.String())
}

// AcceptOwnership : le propriétaire proposé accepte le contrôle du contrat.
func AcceptOwnership(cur realm) {
	caller := cur.Previous().Address()
	if pendingOwner == "" || caller != pendingOwner {
		panic("gnodice: aucune proposition de transfert pour cette adresse")
	}
	previous := owner
	owner = pendingOwner
	pendingOwner = ""
	chain.Emit("OwnershipTransferred", "from", previous.String(), "to", owner.String())
}

// Owner renvoie l'adresse du propriétaire.
func Owner() address { return owner }

// Croupier renvoie l'adresse du croupier.
func Croupier() address { return croupier }

func assertOwner(cur realm) {
	if cur.Previous().Address() != owner {
		panic("gnodice: action réservée au propriétaire du contrat")
	}
}
