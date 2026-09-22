// Package home is the realm behind https://gno.land/u/clockwork.
//
// gnoweb builds a user profile page by calling Render("") on the realm at the
// exact path /r/<username>/home (gno.land/pkg/gnoweb/handler_http.go,
// GetUserView). That lookup does no version resolution, so this path is the
// interface with gnoweb and can never carry a /vN suffix. Everything that
// might want to change therefore lives behind the path, in four layers:
//
//  1. CONTENT is data. The page is assembled from SLOTS: named markdown
//     fragments in an avl tree, each written by its own Set call. Updating
//     one paragraph is one small transaction.
//  2. LAYOUT is data. The slot named "layout" is the page template; every
//     :slug: placeholder in it is filled from the slot of that name.
//  3. STYLE is data. Slots under the "style." prefix are knobs (colors,
//     header mode) that the theme reads. Changing the accent color is a Set.
//  4. RENDERING is code, but replaceable. A THEME is a separate realm nested
//     under this one that implements Theme and registers itself from its own
//     init. The authority accepts it through p/clockwork/upgradeable and can
//     roll it back. The slots never move: an upgrade replaces the code that
//     reads them, not the data. When no theme is live the built-in renderer
//     in render.gno serves the page, and the operator views (system, slots,
//     edit, manifest) are always served by this realm, so a theme that
//     panics can be rolled back from the page it cannot break.
//
// This realm holds state and forwards. It is deliberately small, because it
// is the one piece that can never be redeployed: it is importable by its
// themes, so it cannot be private, so AddPackage refuses a second deploy.
package home

import (
	"crypto/sha256"
	"encoding/hex"
	"strconv"
	"strings"

	"chain/runtime"

	"gno.land/p/g1lnkytfqcjwllws63gvf0mv9yt04aswy4y9amhm/upgradeable/v0"
	"gno.land/p/nt/avl/v0"
)

// Admin is the initial authority: the only address that may write slots and
// accept, roll back or freeze a theme. It is a constant so a reviewer can read
// who controls the page without decoding chain state; TransferAuthority moves
// it afterwards.
//
// The value here is the standard test1 account, so the gnodev walkthrough in
// the README works unedited. `make build ADMIN=g1...` rewrites it for a real
// deployment.
const Admin = address("g1lnkytfqcjwllws63gvf0mv9yt04aswy4y9amhm")

const (
	// LayoutSlug names the slot used as the page template.
	LayoutSlug = "layout"

	// StylePrefix marks slots that are style knobs rather than content.
	// Style("accent", ...) reads the slot "style.accent".
	StylePrefix = "style."

	// maxSlugLen bounds a slot name so an index row stays readable.
	maxSlugLen = 64
)

// Theme is what a renderer realm promises. It is declared here, in the file
// that can never change, so every theme version agrees on one type identity.
//
// Render receives the render path ("" is the profile page) and returns
// markdown. The operator views (system, slots, edit, manifest) never reach a
// theme; for any other path it does not draw itself, a theme should return
// Fallback(path). A panic here aborts the query: there is no recovering a
// foreign realm's panic, so a broken theme shows an error until Rollback.
type Theme interface {
	Render(path string) string
}

// Slot is one named fragment of the page.
type Slot struct {
	Body   string
	Rev    int   // Revision() at the time of the last write to this slot
	Height int64 // block height of that write
}

var (
	proxy    *upgradeable.Proxy
	selfPath string

	slots      = avl.NewTree() // slug -> *Slot
	rev        int             // total writes accepted; bumps on every mutation
	lastHeight int64           // height of the most recent write
)

func init(cur realm) {
	// Captured rather than written as a constant, so links and the nesting
	// rule follow the path this code was actually deployed at.
	selfPath = cur.PkgPath()
	proxy = upgradeable.New(upgradeable.NewAddrAuthority(Admin))
}

// ---------------------------------------------------------------------------
// Authority

// assertAuthority panics unless the caller of the crossing function that owns
// cur is the current authority. It asks the proxy's Authority directly rather
// than going through proxy.AssertAuthorized, so content writes keep working
// after Freeze: freezing ends code upgrades, not editing.
func assertAuthority(cur realm) {
	caller := cur.Previous()
	if !proxy.Authority().Authorized(caller.Address(), caller.PkgPath()) {
		panic("home: restricted to the authority")
	}
}

// ---------------------------------------------------------------------------
// Slugs

// reservedSlugs are placeholders computed at render time (see render.gno). A
// slot may not take one of these names, so the page never depends on which
// of the two would win.
var reservedSlugs = []string{"chainid", "height", "owner", "realm", "rev", "slots", "theme", "updated"}

// validSlug reports whether slug is a legal slot name: 1..maxSlugLen bytes of
// [a-z0-9._-]. No ':' so a slug can never break out of its own :slug:
// placeholder, and no uppercase so a slot has exactly one name.
func validSlug(slug string) bool {
	if len(slug) == 0 || len(slug) > maxSlugLen {
		return false
	}
	for i := 0; i < len(slug); i++ {
		c := slug[i]
		switch {
		case c >= 'a' && c <= 'z', c >= '0' && c <= '9':
		case c == '-', c == '_', c == '.':
		default:
			return false
		}
	}
	return true
}

func assertWritableSlug(slug string) {
	if !validSlug(slug) {
		panic("home: invalid slug " + strconv.Quote(slug) +
			": want 1-" + strconv.Itoa(maxSlugLen) + " bytes of [a-z0-9._-]")
	}
	for _, r := range reservedSlugs {
		if slug == r {
			panic("home: reserved slug " + slug + " is computed at render time")
		}
	}
}

// ---------------------------------------------------------------------------
// Writes (authority only)

// Set creates or replaces the slot named slug. This is the ordinary update:
// one slot, one transaction. An empty body keeps the slot but empties it; use
// Delete to remove it.
func Set(cur realm, slug, body string) {
	assertAuthority(cur)
	assertWritableSlug(slug)
	write(slug, body)
}

// Append adds to the end of a slot, creating it when absent. It exists for a
// body too large for one transaction: Set the first chunk, Append the rest.
func Append(cur realm, slug, body string) {
	assertAuthority(cur)
	assertWritableSlug(slug)
	write(slug, Get(slug)+body)
}

// Delete removes a slot. Deleting the layout slot restores the theme's
// default layout.
func Delete(cur realm, slug string) {
	assertAuthority(cur)
	if _, removed := slots.Remove(slug); !removed {
		panic("home: no such slot: " + slug)
	}
	bump()
}

func write(slug, body string) {
	bump()
	slots.Set(slug, &Slot{Body: body, Rev: rev, Height: lastHeight})
}

func bump() {
	rev++
	lastHeight = runtime.ChainHeight()
}

// ---------------------------------------------------------------------------
// Reads (anyone, including themes)

// Get returns a slot body, or "" when the slot does not exist.
func Get(slug string) string {
	v := slots.Get(slug)
	if v == nil {
		return ""
	}
	return v.(*Slot).Body
}

// Has reports whether a slot exists, empty or not.
func Has(slug string) bool { return slots.Has(slug) }

// Lookup returns a copy of a slot and whether it exists.
func Lookup(slug string) (Slot, bool) {
	v := slots.Get(slug)
	if v == nil {
		return Slot{}, false
	}
	return *v.(*Slot), true
}

// Slugs returns every slot name, sorted.
func Slugs() []string {
	out := make([]string, 0, slots.Size())
	slots.Iterate("", "", func(key string, _ any) bool {
		out = append(out, key)
		return false
	})
	return out
}

// Each visits every slot in name order until fn returns true.
func Each(fn func(slug string, s Slot) bool) {
	slots.Iterate("", "", func(key string, value any) bool {
		return fn(key, *value.(*Slot))
	})
}

// Style returns the style knob named key (the slot "style."+key), or fallback
// when it is absent or empty.
func Style(key, fallback string) string {
	if v := Get(StylePrefix + key); v != "" {
		return v
	}
	return fallback
}

// Layout returns the layout slot, or "" when none has been set. Themes
// substitute their own default in that case.
func Layout() string { return Get(LayoutSlug) }

// Revision returns the total number of writes this realm has accepted. It
// changes on every mutation, so a client can cheaply tell "nothing moved".
func Revision() int { return rev }

// LastHeight returns the block height of the most recent write, or 0.
func LastHeight() int64 { return lastHeight }

// Manifest returns one tab-separated line per slot:
//
//	<slug>\t<rev>\t<bytes>\t<sha256 of body, hex>
//
// It is the diff surface scripts/sync.sh reads: one query tells it exactly
// which local file is out of date, without downloading any body.
func Manifest() string {
	var b strings.Builder
	slots.Iterate("", "", func(key string, value any) bool {
		s := value.(*Slot)
		sum := sha256.Sum256([]byte(s.Body))
		b.WriteString(key)
		b.WriteString("\t")
		b.WriteString(strconv.Itoa(s.Rev))
		b.WriteString("\t")
		b.WriteString(strconv.Itoa(len(s.Body)))
		b.WriteString("\t")
		b.WriteString(hex.EncodeToString(sum[:]))
		b.WriteString("\n")
		return false
	})
	return b.String()
}

// Path returns this realm's package path, e.g. "gno.land/r/g1lnkytfqcjwllws63gvf0mv9yt04aswy4y9amhm/home".
func Path() string { return selfPath }

// Link returns the gnoweb path of a render path on this realm:
// Link("") is "/r/g1lnkytfqcjwllws63gvf0mv9yt04aswy4y9amhm/home", Link("slots") is "/r/g1lnkytfqcjwllws63gvf0mv9yt04aswy4y9amhm/home:slots".
func Link(sub string) string {
	p := selfPath
	if i := strings.Index(p, "/"); i >= 0 {
		p = p[i:]
	}
	if sub == "" {
		return p
	}
	return p + ":" + sub
}

// ---------------------------------------------------------------------------
// Themes: the upgradeable part.
//
// A theme realm nested under this path (…/home/theme/vN) calls Register from
// its own init, so deploying it is what nominates it. Nothing serves until the
// authority runs Accept with that path, which is a separate transaction naming
// code anyone can go and read. Rollback puts the previous theme back.

// Register records the calling realm's theme as a candidate. The path filed
// is read off the crossing frame, never taken as an argument, so a candidate
// cannot claim to live somewhere it does not. Only realms nested under this
// one are admitted; a direct user call is refused.
func Register(cur realm, t Theme) { proxy.Propose(0, cur, t) }

// Accept makes the candidate at pkgPath the live theme. Authority only.
func Accept(cur realm, pkgPath string) { proxy.Accept(0, cur, pkgPath) }

// Withdraw drops a candidate. Authority only, except that a theme realm may
// always drop its own.
func Withdraw(cur realm, pkgPath string) { proxy.Withdraw(0, cur, pkgPath) }

// Rollback restores the previous theme and returns the current one to the
// pending set. Authority only.
func Rollback(cur realm) { proxy.Rollback(0, cur) }

// Forget drops the rollback history and the storage it holds. Authority only.
func Forget(cur realm) { proxy.Forget(0, cur) }

// Freeze ends theme upgrades permanently. Slots stay editable. Authority
// only, and there is no way back.
func Freeze(cur realm) { proxy.Freeze(0, cur) }

// TransferAuthority hands both editing and upgrading to another address.
func TransferAuthority(cur realm, to address) {
	proxy.TransferAuthority(0, cur, upgradeable.NewAddrAuthority(to))
}

// LivePath returns the realm path of the theme currently serving, or "".
func LivePath() string { return proxy.LivePath() }

// PendingPaths returns the candidate theme paths awaiting acceptance.
func PendingPaths() []string {
	out := []string{}
	for _, r := range proxy.Pending() {
		out = append(out, r.PkgPath())
	}
	return out
}

// HistoryPaths returns the themes this realm has already served, oldest
// first, excluding the live one.
func HistoryPaths() []string {
	out := []string{}
	for _, r := range proxy.History() {
		out = append(out, r.PkgPath())
	}
	return out
}

// Frozen reports whether theme upgrades have ended.
func Frozen() bool { return proxy.Frozen() }

// Authority returns a human-readable description of who may write and
// upgrade.
func Authority() string { return proxy.Authority().String() }

// liveTheme returns the accepted theme, if any.
func liveTheme() (Theme, bool) {
	v, ok := proxy.TryImpl()
	if !ok {
		return nil, false
	}
	t, ok := v.(Theme)
	return t, ok
}
