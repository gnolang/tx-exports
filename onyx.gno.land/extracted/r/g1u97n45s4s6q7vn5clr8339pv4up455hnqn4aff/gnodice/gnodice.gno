// Package gnodice est un jeu de dés décentralisé sur gno.land, « prouvablement
// équitable » (provably fair).
//
// Règles du jeu :
//   - le joueur choisit un chiffre entre 1 et 6 et mise entre 1 et 10 GNOT ;
//   - si le dé tombe sur son chiffre, il reçoit 5 fois sa mise ;
//   - chaque joueur ne peut lancer le dé qu'une fois toutes les 10 minutes.
//
// POURQUOI TROIS ÉTAPES (sécurité) :
// Sur une blockchain, tout est public et une transaction peut contenir
// plusieurs messages exécutés « tout ou rien ». Si le dé était tiré pendant
// Play, un tricheur pourrait ajouter un 2e message qui annule toute la
// transaction quand il perd (ou simuler le tirage avant de miser) : il ne
// garderait que ses victoires et viderait la banque. On sépare donc le jeu en
// trois étapes, pour que PERSONNE ne puisse choisir le résultat en connaissant
// les données de l'autre :
//
//  1. Play    : le joueur mise et envoie son chiffre CACHÉ (une empreinte
//               SHA-256 de « chiffre + secret aléatoire + adresse »).
//  2. Resolve : le croupier (un service du site) fournit une graine aléatoire
//               de 32 octets SANS connaître le chiffre. Le dé est calculé à
//               partir de la graine et de l'empreinte, et la graine est publiée.
//  3. Reveal  : on dévoile le chiffre et le secret. Le contrat vérifie
//               l'empreinte et paie si le chiffre est le bon.
//
// Garde-fous : si le croupier ne répond pas, le joueur récupère sa mise
// (Refund) ; si le chiffre n'est jamais dévoilé, la partie est perdue (Expire).
// La banque réserve à chaque mise le gain maximal possible : elle ne peut
// jamais promettre plus qu'elle ne possède.
package gnodice

import (
	"chain/runtime"
	"time"

	"gno.land/p/nt/avl/v0"
)

// Paramètres du jeu. 1 GNOT = 1 000 000 ugnot (la plus petite unité).
const (
	Denom            = "ugnot"
	UgnotPerGnot     = int64(1_000_000)
	MinBet           = 1 * UgnotPerGnot  // mise minimale : 1 GNOT
	MaxBet           = 10 * UgnotPerGnot // mise maximale : 10 GNOT
	PayoutMultiplier = int64(5)          // gain = 5 x la mise
	CooldownSeconds  = int64(10 * 60)    // 10 minutes entre deux lancers
	HistorySize      = 10                // nombre de parties gardées par joueur
	DieFaces         = 6

	// Délais (en secondes, heure des blocs)
	ResolveTimeout = int64(30 * 60)       // sans tirage au bout de 30 min : le joueur peut être remboursé
	RevealWindow   = int64(7 * 24 * 3600) // 7 jours pour dévoiler son chiffre après le tirage

	// Limites par défaut (modifiables par le propriétaire avec SetLimits)
	DefaultDailyPayoutLimit = 500 * UgnotPerGnot // au-delà, le jeu se met en pause tout seul
	DefaultLowBankroll      = 100 * UgnotPerGnot // en dessous, un événement d'alerte est émis

	maxPageSize = 50 // nombre maximal de parties renvoyées par une lecture
)

// Status : étape d'une partie.
type Status int

const (
	StatusPending  Status = iota // mise reçue, en attente du tirage
	StatusRolled                 // dé tiré, en attente du chiffre dévoilé
	StatusWon                    // chiffre dévoilé : gagné et payé
	StatusLost                   // chiffre dévoilé : perdu
	StatusRefunded               // croupier trop lent : mise rendue
	StatusExpired                // chiffre jamais dévoilé : perdu
)

func (s Status) String() string {
	switch s {
	case StatusPending:
		return "pending"
	case StatusRolled:
		return "rolled"
	case StatusWon:
		return "won"
	case StatusLost:
		return "lost"
	case StatusRefunded:
		return "refunded"
	case StatusExpired:
		return "expired"
	}
	return "unknown"
}

// isOpen : la partie n'est pas terminée (sa réserve est encore bloquée).
func (s Status) isOpen() bool {
	return s == StatusPending || s == StatusRolled
}

// Game décrit une partie.
type Game struct {
	ID           int64
	Player       address
	Commitment   string // empreinte du chiffre caché (64 caractères hexadécimaux)
	Bet          int64  // mise en ugnot
	Status       Status
	Seed         string // graine du croupier, publiée au tirage (vide avant)
	Roll         int    // résultat du dé (0 avant le tirage)
	Guess        int    // chiffre dévoilé (0 tant qu'il est caché)
	Payout       int64  // somme versée au joueur (gain, ou mise rendue)
	PlacedAt     int64  // heure du bloc de la mise (secondes Unix)
	PlacedHeight int64
	RolledAt     int64
	SettledAt    int64
}

// Won : true si la partie est gagnée.
func (g *Game) Won() bool { return g.Status == StatusWon }

// reservation : ce que la banque bloque pour cette partie (le gain maximal).
func (g *Game) reservation() int64 { return g.Bet * PayoutMultiplier }

// playerData regroupe les informations d'un joueur.
type playerData struct {
	LastPlay int64   // heure de la dernière mise (secondes Unix)
	Played   int     // parties terminées (gagnées, perdues ou expirées)
	Wins     int     // victoires
	Wagered  int64   // total misé en ugnot
	Paid     int64   // total gagné en ugnot
	History  []int64 // numéros des HistorySize dernières parties (plus ancienne en premier)
	Open     int     // parties en cours (non terminées)
}

var (
	owner        address // propriétaire : retraits, pause, réglages
	pendingOwner address // propriétaire proposé, qui doit accepter (TransferOwnership en 2 temps)
	croupier     address // service autorisé à tirer les dés (Resolve)
	realmAddr    address // adresse du contrat = adresse de la banque
	paused       bool

	games     = avl.NewTree() // numéro (texte à zéros) -> *Game
	openGames = avl.NewTree() // parties en cours, même clé -> true
	players   = avl.NewTree() // adresse -> *playerData
	blocked   = avl.NewTree() // adresses interdites de jeu -> true
	recent    []int64         // dernières parties, tous joueurs confondus

	reserved int64 // somme des gains maximaux des parties en cours

	totalGames     int64 // parties créées (= dernier numéro)
	totalWins      int
	totalLosses    int
	totalRefunded  int
	totalExpired   int
	totalWagered   int64
	totalPaid      int64
	totalFunded    int64
	totalWithdrawn int64

	// Coupe-circuit : gains payés aujourd'hui (jour = heure du bloc / 86 400)
	dailyPayoutLimit = DefaultDailyPayoutLimit
	lowBankroll      = DefaultLowBankroll
	payoutDay        int64
	payoutToday      int64
)

// init s'exécute une seule fois, au déploiement du contrat.
// Celui qui déploie devient le propriétaire ET le croupier par défaut.
func init(cur realm) {
	owner = cur.Previous().Address()
	croupier = owner
	realmAddr = cur.Address()
}

// --- outils internes partagés ---

func now() int64 { return time.Now().Unix() }

func height() int64 { return runtime.ChainHeight() }

// gameKey : clé de tri des parties (zéros devant pour garder l'ordre).
func gameKey(id int64) string {
	s := itoa64(id)
	for len(s) < 12 {
		s = "0" + s
	}
	return s
}

func getGame(id int64) *Game {
	v := games.Get(gameKey(id))
	if v == nil {
		return nil
	}
	return v.(*Game)
}

func mustGetGame(id int64) *Game {
	g := getGame(id)
	if g == nil {
		panic("gnodice: partie introuvable")
	}
	return g
}

func getPlayer(addr address) *playerData {
	v := players.Get(addr.String())
	if v == nil {
		return nil
	}
	return v.(*playerData)
}

func isBlocked(addr address) bool {
	return blocked.Has(addr.String())
}

// pushID ajoute un numéro de partie en ne gardant que les HistorySize derniers.
func pushID(list []int64, id int64) []int64 {
	if len(list) < HistorySize {
		return append(list, id)
	}
	out := make([]int64, 0, HistorySize)
	out = append(out, list[len(list)-HistorySize+1:]...)
	return append(out, id)
}
