package soup

import "testing"

func TestCRC32(t *testing.T) {
	if got := crc32([]byte("123456789")); got != 0xCBF43926 {
		t.Errorf("crc32 check value: %x", got)
	}
}

// 10 languages: a password with a value must be caught.
func TestPasswordTenLanguages(t *testing.T) {
	for _, s := range []string{
		"şifrem kartal1907",            // tr
		"my password is hunter2",       // en
		"mi contraseña es gato123",     // es
		"mon mot de passe est soleil",  // fr
		"mein passwort ist sommer2024", // de
		"minha senha é abacate",        // pt
		"la mia password è girasole",   // it
		"mijn wachtwoord is fiets",     // nl
		"мой пароль qwerty123",         // ru
		"كلمة المرور abc12345",         // ar
	} {
		if got := Secret(s); got != Password {
			t.Errorf("%q: got %q, want password", s, got)
		}
	}
}

// Talking about a password is fine.
func TestPasswordHarmless(t *testing.T) {
	for _, s := range []string{
		"forgot my password",
		"I forgot my password again",
		"olvidé mi contraseña",
		"j'ai oublié mon mot de passe",
		"passwort vergessen",
		"esqueci minha senha",
		"şifremi unuttum",
		"мой пароль забыл",
		"wachtwoord vergeten",
	} {
		if got := Secret(s); got != "" {
			t.Errorf("%q: got %q, want nothing", s, got)
		}
	}
}

func TestOtherSecrets(t *testing.T) {
	cases := [][2]string{
		{"doğrulama kodu 482913", Code},
		{"my verification code is 739204", Code},
		{"codigo de verificacion 552190", Code},
		{"PIN 4821", Code}, // upper-case PIN (older Python filter missed it)
		{"my seed phrase is in a drawer", SeedPhrase},
		{"12 kelime yazdım kağıda", SeedPhrase},
		{"abandon, ability, able, about, above, absent, absorb, abstract, absurd, abuse, access, accident", SeedPhrase},
		{"4c0883a69102937d6231471b5dbb6204fe5129617082792ae468d01a3f362318", PrivateKey},
		{"mail me at ali.k@ornek.com", Email},
		{"numaram 0532 123 45 67", Number},
		{"TC 12345678901", Number},
		{"IBAN TR33 0006 1005 1978 6457 8413 26", IBAN},
		{"adresim 0x52908400098527886E0F7030069857D2E4169EE7", WalletAddress},
	}
	for _, c := range cases {
		if got := Secret(c[0]); got != c[1] {
			t.Errorf("%q: got %q, want %q", c[0], got, c[1])
		}
	}
}

// Known gap: twelve seed words with only spaces are not caught (no word list).
func TestSeedWordsSpacesKnownGap(t *testing.T) {
	if got := Secret("abandon ability able about above absent absorb abstract absurd abuse access accident"); got != "" {
		t.Logf("now caught as %q; update this test", got)
	}
}

func TestInnocent(t *testing.T) {
	for _, s := range []string{
		"bugün hava çok güzel",
		"the cat sat on the box",
		"kedim kutuya sığmadı ama yine girdi",
		"pin up poster on the wall",
		"Şıkım bugün, götürün beni dışarı.",
		"bu ne biçim şıklık, harika",
		"malum konu",
	} {
		if tx, sc, _, _ := Check(s); tx != "" || sc != "" {
			t.Errorf("%q: toxic %q secret %q, want clean", s, tx, sc)
		}
	}
}

func TestToxic(t *testing.T) {
	cases := [][2]string{
		{"orospu çocuğu", Profanity},
		{"siktir git", Profanity},
		{"amk ya", Profanity},
		{"ibnelik etme", Profanity},
		{"sen tam bir salak sın", Insult},
		{"s.a.l.a.k", Insult},
		{"salaaak misin", Insult},
		{"serefsiz", Profanity}, // written without Turkish letters
		{"seni bulurum ve gebertirim", Threat},
	}
	for _, c := range cases {
		if got := Toxic(c[0]); got != c[1] {
			t.Errorf("%q: got %q, want %q", c[0], got, c[1])
		}
	}
}

func TestClean(t *testing.T) {
	cases := [][2]string{
		{"Merhaba ben Ahmet Yılmaz, numaram 0532 123 45 67, Samsun'da yaşıyorum.",
			"Merhaba ben biri, numaram bir numara, bir şehirde yaşıyorum."},
		{"Ayşe'ye söyledim ama dinlemedi, çok kızdım.", "birine söyledim ama dinlemedi, çok kızdım."},
		{"Yağmur yağınca bütün yollar göl oluyor.", "Yağmur yağınca bütün yollar göl oluyor."},
	}
	for _, c := range cases {
		if got, _ := Clean(c[0]); got != c[1] {
			t.Errorf("clean\n in : %s\n got: %s\n want: %s", c[0], got, c[1])
		}
	}
}

// Flavor must match the reference model (flavor_expected_test.gno).
var modelCodes = [flavorCount]string{"tatli", "aci", "eksi", "tuzlu", "baharatli"}

func TestFlavorMatchesModel(t *testing.T) {
	for _, e := range flavorExpected {
		kv := bucketsOf(e.text)
		sortInts(kv)
		if !sameInts(kv, e.buckets) {
			t.Errorf("%q: buckets differ", e.text)
			continue
		}
		j, share := predict(e.text)
		if modelCodes[j] != e.flavor {
			t.Errorf("%q: flavor %s, want %s", e.text, modelCodes[j], e.flavor)
		}
		if d := int(share[j]*1000+0.5) - e.permille; d > 1 || d < -1 {
			t.Errorf("%q: confidence %d permille, want %d", e.text, int(share[j]*1000+0.5), e.permille)
		}
	}
}

func TestCheckShape(t *testing.T) {
	_, _, f, c := Check("Otobüs yine gelmedi, yarım saattir duraktayım.")
	if f == "" || c < 20 || c > 100 {
		t.Errorf("flavor %q confidence %d", f, c)
	}
	if _, _, f, c := Check("!!! ???"); f != "" || c != 0 {
		t.Errorf("no words: flavor %q confidence %d", f, c)
	}
}

func sameInts(a, b []int) bool {
	if len(a) != len(b) {
		return false
	}
	for i := range a {
		if a[i] != b[i] {
			return false
		}
	}
	return true
}

func sortInts(a []int) {
	for i := 1; i < len(a); i++ {
		for j := i; j > 0 && a[j] < a[j-1]; j-- {
			a[j], a[j-1] = a[j-1], a[j]
		}
	}
}
