// Package soup is a message safety check for Gno apps.
// Before an app (a board, a chat) stores a message, it asks soup:
// is it toxic, does it leak a secret, and what is its flavor.
//
// soup stores nothing and writes nothing. It is a pure package: call it from
// any realm. Flavor weights are constants inside the package.
//
// Paket hicbir sey saklamaz, hicbir sey yazmaz. Herhangi bir realm cagirabilir.
package soup

const Version = "0.1.0"

// Toxic reasons. Zehir sebepleri.
const (
	Profanity = "profanity" // kufur
	Insult    = "insult"    // hakaret
	Threat    = "threat"    // tehdit
)

// Secret kinds. Gizli bilgi turleri.
const (
	Password      = "password"       // sifre
	Code          = "code"           // PIN, OTP, dogrulama kodu
	SeedPhrase    = "seed_phrase"    // cuzdan kelimeleri
	PrivateKey    = "private_key"    // ozel anahtar
	Email         = "email"          // e-posta
	Number        = "number"         // telefon, TC kimlik, kart (7+ rakam)
	IBAN          = "iban"           // IBAN
	WalletAddress = "wallet_address" // 0x... adres
)

// Flavors, in model order. Tatlar, model sirasiyla.
//   sweet  = funny, cute        (tatli)
//   bitter = harsh, sarcastic   (aci)
//   sour   = grumpy, complaint  (eksi)
//   salty  = sad, heavy         (tuzlu)
//   spicy  = absurd, nonsense   (baharatli)
var Flavors = [flavorCount]string{"sweet", "bitter", "sour", "salty", "spicy"}

const MaxLen = 2000 // bytes; longer text is checked only up to here / sinir

// Check runs all three checks.
// toxic: "" or Profanity/Insult/Threat. secret: "" or one of the secret kinds.
// flavor: one of Flavors ("" if the text has no words). confidence: 0-100.
func Check(text string) (toxic, secret, flavor string, confidence int) {
	text = clip(text)
	flavor, confidence = Flavor(text)
	return Toxic(text), Secret(text), flavor, confidence
}

// Safe is true when the text is neither toxic nor leaking a secret.
func Safe(text string) bool {
	text = clip(text)
	return Toxic(text) == "" && Secret(text) == ""
}

// Flavor returns the flavor and confidence (0-100). Tat ve eminlik.
func Flavor(text string) (string, int) {
	j, share := predict(clip(text))
	if j < 0 {
		return "", 0
	}
	return Flavors[j], int(share[j]*100 + 0.5)
}

func clip(s string) string {
	if len(s) > MaxLen {
		return s[:MaxLen]
	}
	return s
}
