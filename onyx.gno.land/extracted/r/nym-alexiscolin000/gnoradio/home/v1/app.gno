package home

import (
	"chain"
	"chain/runtime/unsafe"
	"strings"

	"gno.land/r/nym-alexiscolin000/gnoradio/catalog/v1"
	"gno.land/r/nym-alexiscolin000/gnoradio/data"
)

// The site's two settings live in the data realm, "home/config", so a later
// home release keeps them: "app" is the GnoRadio app (dApp) that pages link
// to, "" hides the links; "contact" is an extra way to reach the moderator,
// shown with the notice path, "" hides the line (the on-chain Report needs
// none). Only the catalog admin sets them: home has no admin of its own.
const (
	cConfig    = "home/config"
	maxAppURL  = 100
	maxContact = 120
)

// init makes home/config while this realm is the home writer (release 1 at
// deploy); a later release finds it made.
func init(cur realm) {
	if data.Writer("home") == cur.PkgPath() {
		data.Make(cross(cur), cConfig)
	}
}

// Ready tells the data realm that this release is on chain (see
// data.Propose). Anyone may call it.
func Ready(cur realm) {
	noPayment()
	data.Ready(cross(cur))
}

func noPayment() {
	if len(unsafe.OriginSend()) != 0 {
		panic("home: this action does not take coins")
	}
}

func onlyCatalogAdmin(cur realm) {
	if !cur.Previous().IsUserCall() || cur.Previous().Address() != catalog.Admin() {
		panic("home: catalog admin only")
	}
	noPayment()
}

// SetAppURL sets the app link shown on every page: an https URL of at most
// 100 characters from [A-Za-z0-9-._~/:%], or "" to remove it. Catalog admin only.
func SetAppURL(cur realm, url string) {
	onlyCatalogAdmin(cur)
	if url != "" && !validAppURL(url) {
		panic("home: app URL must be https://, at most 100 characters of A-Z a-z 0-9 - . _ ~ / : %")
	}
	data.Set(cross(cur), cConfig, "app", url)
	chain.Emit("AppURLSet", "url", url)
}

// SetContact sets the contact line shown next to the notice path (a web form,
// a postal address…): one line of at most 120 characters, or "" to remove it.
// Catalog admin only.
func SetContact(cur realm, line string) {
	onlyCatalogAdmin(cur)
	line = strings.TrimSpace(line)
	if len(line) > maxContact || strings.ContainsAny(line, "\r\n") {
		panic("home: the contact is one line of at most 120 characters")
	}
	data.Set(cross(cur), cConfig, "contact", line)
	chain.Emit("ContactSet", "contact", line)
}

func validAppURL(u string) bool {
	if !strings.HasPrefix(u, "https://") || len(u) <= len("https://") || len(u) > maxAppURL {
		return false
	}
	for _, c := range u {
		switch {
		case c >= 'a' && c <= 'z', c >= 'A' && c <= 'Z', c >= '0' && c <= '9':
		case strings.ContainsRune("-._~/:%", c):
		default:
			return false
		}
	}
	return true
}

// appURL and contact read the settings.
// appURL is checked again when read: a later release may write it.
func appURL() string {
	if v, _ := data.Get(cConfig, "app"); validAppURL(v) {
		return v
	}
	return ""
}

func contact() string {
	v, _ := data.Get(cConfig, "contact")
	return v
}

// inApp links an app route (e.g. "track/12", "" for the player), or returns
// "" when no app URL is set.
func inApp(route, label string) string {
	u := appURL()
	if u == "" {
		return ""
	}
	return "[" + label + "](" + strings.TrimRight(u, "/") + "/" + route + ")"
}
