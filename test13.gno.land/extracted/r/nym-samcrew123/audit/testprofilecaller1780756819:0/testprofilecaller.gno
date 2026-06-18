package testprofilecaller1780756819

import "gno.land/r/demo/profile"

// SpoofProfile appelle SetStringField cross-realm.
// Le profil sera stocké sous l'adresse de CE realm (pas l'EOA signataire).
func SpoofProfile(cur realm, field, value string) {
	profile.SetStringField(cross(cur), field, value)
}

// GetAddr retourne l'adresse de ce realm (pour la vérification).
func GetAddr(cur realm) string {
	return cur.Address().String()
}
