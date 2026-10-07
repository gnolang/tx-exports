// Realm (smart contract) Gno pour Sonotone.
// - Chaque wallet peut s'inscrire UNE fois avec un pseudo unique.
// - Un joueur inscrit envoie son score uniquement quand il bat son record
//   (ça lui évite de payer des frais à chaque partie).
// - Le jeu lit les données avec GetPlayerJSON / GetTopJSON (gratuit).
// - Render() affiche le classement sur gnoweb (la page du realm sur gno.land).

package sonotone

import (
	"strconv"
	"strings"

	"gno.land/p/nt/avl/v0"
)

// Score maximum accepté (protection basique contre les valeurs absurdes).
const MaxScore = 1000000

// Player = un joueur inscrit et son meilleur résultat.
type Player struct {
	Pseudo     string
	Address    address
	BestScore  int
	Level      int    // niveau max atteint lors du meilleur score
	Instrument string // instrument utilisé lors du meilleur score
}

// Les variables globales d'un realm sont sauvegardées automatiquement
// sur la blockchain après chaque transaction.
var (
	players avl.Tree // clé : adresse du wallet -> *Player
	pseudos avl.Tree // clé : pseudo en minuscules -> adresse du wallet
)

// ---------------------------------------------------------------------
// Fonctions appelées par les joueurs (transactions signées avec Adena)
// ---------------------------------------------------------------------

// Register relie un pseudo au wallet qui signe la transaction.
// Le premier paramètre "cur realm" est obligatoire pour qu'un utilisateur
// puisse appeler la fonction et pour savoir QUI l'appelle.
func Register(cur realm, pseudo string) {
	caller := cur.Previous()
	if !caller.IsUser() {
		panic("seul un wallet peut s'inscrire")
	}
	key := caller.Address().String()

	if players.Has(key) {
		panic("ce wallet a déjà un pseudo")
	}
	checkPseudo(pseudo)

	lower := strings.ToLower(pseudo)
	if pseudos.Has(lower) {
		panic("ce pseudo est déjà pris")
	}

	// On n'écrit qu'après toutes les vérifications.
	players.Set(key, &Player{
		Pseudo:  pseudo,
		Address: caller.Address(),
	})
	pseudos.Set(lower, key)
}

// SubmitScore enregistre un nouveau record pour le wallet qui signe.
func SubmitScore(cur realm, score int, level int, instrument string) {
	key := cur.Previous().Address().String()

	v := players.Get(key)
	if v == nil {
		panic("inscris d'abord un pseudo")
	}
	if score <= 0 || score > MaxScore {
		panic("score invalide")
	}
	if level < 1 || level > 1000 {
		panic("niveau invalide")
	}
	if !validInstrument(instrument) {
		panic("instrument inconnu")
	}

	p := v.(*Player)
	if score <= p.BestScore {
		panic("ce n'est pas un nouveau record")
	}
	p.BestScore = score
	p.Level = level
	p.Instrument = instrument
}

// ---------------------------------------------------------------------
// Fonctions de lecture (gratuites, utilisées par le jeu)
// ---------------------------------------------------------------------

// GetPlayerJSON renvoie le profil d'une adresse en JSON, ou "null".
func GetPlayerJSON(addr string) string {
	v := players.Get(addr)
	if v == nil {
		return "null"
	}
	return playerToJSON(v.(*Player))
}

// GetTopJSON renvoie les n meilleurs joueurs (ayant un score) en JSON.
func GetTopJSON(n int) string {
	top := topPlayers(n)
	out := "["
	for i, p := range top {
		if i > 0 {
			out += ","
		}
		out += playerToJSON(p)
	}
	return out + "]"
}

// Render affiche le classement en Markdown sur gnoweb.
func Render(_ string) string {
	out := "# 🎧 Sonotone — Classement\n\n"
	top := topPlayers(20)
	if len(top) == 0 {
		return out + "Aucun score pour l'instant.\n"
	}
	out += "| # | Pseudo | Score | Niveau | Instrument |\n"
	out += "|---|--------|-------|--------|------------|\n"
	for i, p := range top {
		out += "| " + strconv.Itoa(i+1) +
			" | " + p.Pseudo +
			" | " + strconv.Itoa(p.BestScore) +
			" | " + strconv.Itoa(p.Level) +
			" | " + p.Instrument + " |\n"
	}
	return out
}

// ---------------------------------------------------------------------
// Fonctions internes (minuscule = non accessibles de l'extérieur)
// ---------------------------------------------------------------------

// checkPseudo : 3 à 20 caractères, lettres, chiffres, _ et - uniquement.
// (Ça évite aussi les caractères qui casseraient le JSON ou la page.)
func checkPseudo(p string) {
	if len(p) < 3 || len(p) > 20 {
		panic("le pseudo doit faire entre 3 et 20 caractères")
	}
	for _, c := range p {
		ok := (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') ||
			(c >= '0' && c <= '9') || c == '_' || c == '-'
		if !ok {
			panic("pseudo : seulement lettres (sans accent), chiffres, _ et -")
		}
	}
}

func validInstrument(i string) bool {
	return i == "piano" || i == "bass" || i == "guitar" || i == "organ"
}

func playerToJSON(p *Player) string {
	return `{"pseudo":"` + p.Pseudo +
		`","address":"` + p.Address.String() +
		`","score":` + strconv.Itoa(p.BestScore) +
		`,"level_max":` + strconv.Itoa(p.Level) +
		`,"instrument":"` + p.Instrument + `"}`
}

// topPlayers trie les joueurs ayant un score, du plus grand au plus petit.
func topPlayers(n int) []*Player {
	var list []*Player
	players.Iterate("", "", func(_ string, value any) bool {
		p := value.(*Player)
		if p.BestScore > 0 {
			list = append(list, p)
		}
		return false // false = continuer à parcourir
	})

	// Tri par insertion : simple à lire, suffisant pour un petit jeu.
	for i := 1; i < len(list); i++ {
		for j := i; j > 0 && list[j].BestScore > list[j-1].BestScore; j-- {
			list[j], list[j-1] = list[j-1], list[j]
		}
	}

	if n > 0 && len(list) > n {
		list = list[:n]
	}
	return list
}
