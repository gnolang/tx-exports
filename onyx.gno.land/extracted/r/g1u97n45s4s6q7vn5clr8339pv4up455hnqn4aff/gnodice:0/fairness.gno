package gnodice

import (
	"crypto/sha256"
	"encoding/binary"
	"encoding/hex"
	"strconv"
)

// Équité du jeu : empreinte du chiffre caché et calcul du dé.
// Tout est vérifiable par n'importe qui avec SHA-256 :
//
//	empreinte = sha256("gnodice|v1|commit|" + adresse + "|" + chiffre + "|" + secret)
//	dé        = 1 + (8 premiers octets de sha256("gnodice|v1|roll|" + graine + "|" + empreinte + "|" + numéro)) mod 6
//
// Le secret du joueur et la graine du croupier font 32 octets (64 caractères
// hexadécimaux). Un secret plus court permettrait au croupier de retrouver le
// chiffre en essayant les 6 possibilités : il est donc refusé.

const hexLen = 64 // 32 octets écrits en hexadécimal

// Commitment calcule l'empreinte d'un chiffre caché. Lecture seule : le site
// et le croupier peuvent l'appeler pour vérifier leurs calculs.
func Commitment(player address, guess int, salt string) string {
	sum := sha256.Sum256([]byte("gnodice|v1|commit|" + player.String() + "|" + strconv.Itoa(guess) + "|" + salt))
	return hex.EncodeToString(sum[:])
}

// rollFromSeed calcule le dé à partir de la graine du croupier, de l'empreinte
// du joueur et du numéro de la partie.
// Le modulo 6 sur 64 bits a un biais inférieur à 1 sur 3 milliards de milliards :
// négligeable.
func rollFromSeed(seed, commitment string, id int64) int {
	sum := sha256.Sum256([]byte("gnodice|v1|roll|" + seed + "|" + commitment + "|" + itoa64(id)))
	return int(binary.BigEndian.Uint64(sum[0:8])%DieFaces) + 1
}

// RollFor : version publique de rollFromSeed, pour que chacun puisse vérifier
// un tirage passé (graine et empreinte sont publiques après le tirage).
func RollFor(seed, commitment string, id int64) int {
	if !isHex64(seed) || !isHex64(commitment) {
		return 0
	}
	return rollFromSeed(seed, commitment, id)
}

// isHex64 : exactement 64 caractères hexadécimaux minuscules.
func isHex64(s string) bool {
	if len(s) != hexLen {
		return false
	}
	for i := 0; i < len(s); i++ {
		c := s[i]
		if !(c >= '0' && c <= '9' || c >= 'a' && c <= 'f') {
			return false
		}
	}
	return true
}

func itoa64(v int64) string { return strconv.FormatInt(v, 10) }
