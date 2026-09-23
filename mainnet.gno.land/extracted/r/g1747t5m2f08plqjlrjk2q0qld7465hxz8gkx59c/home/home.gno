// Package home is zôÖma's profile page on gno.land.
//
// gnoweb renders a profile by calling Render("") on the realm at exactly
// /r/<namespace>/home, so this path carries no /vN suffix.
//
// The page is assembled from SLOTS: named markdown fragments, one Set
// transaction each. The slot named "layout" is the template; every :slug:
// placeholder in it is replaced by the slot of that name, in a single pass.
// init seeds every slot from content.gno, so the page is complete the block
// it goes live and later edits are data, not redeploys.
//
// One thing on this page is not written by its owner: visitors can send a
// heart (<3), one per address, and the page counts them.
package home

import (
	"strconv"
	"strings"

	"chain/runtime"

	"gno.land/p/nt/avl/v0"
)

// admin is the only address allowed to edit slots.
const admin = address("g1747t5m2f08plqjlrjk2q0qld7465hxz8gkx59c")

const (
	layoutSlug = "layout"
	maxSlugLen = 64
	maxRecent  = 7
)

type slot struct {
	body    string
	rev     int
	updated int64
}

var (
	slots = avl.NewTree() // slug -> *slot
	rev   int             // total slot writes

	hearts = avl.NewTree() // address string -> int64 height of the heart
	recent []address        // newest first, at most maxRecent
)

// reservedSlugs are placeholders computed at render time. A slot may not take
// one of these names, so nothing a slot says can shadow chain state.
var reservedSlugs = []string{"chainid", "height", "hearts", "hero", "realm", "rev"}

func init() {
	for _, s := range defaultSlots {
		rev++
		slots.Set(s.slug, &slot{body: s.body, rev: rev, updated: runtime.ChainHeight()})
	}
	for _, g := range defaultGalleries {
		galleries.Set(g.name, parseGallery(g.spec))
	}
}

func assertAdmin(cur realm) {
	if cur.Previous().Address() != admin {
		panic("restricted to admin")
	}
}

func validSlug(slug string) bool {
	if len(slug) == 0 || len(slug) > maxSlugLen {
		return false
	}
	for i := 0; i < len(slug); i++ {
		c := slug[i]
		if !(c >= 'a' && c <= 'z' || c >= '0' && c <= '9' || c == '-' || c == '_' || c == '.') {
			return false
		}
	}
	return true
}

func assertWritableSlug(slug string) {
	if !validSlug(slug) {
		panic("invalid slug: want 1-" + strconv.Itoa(maxSlugLen) + " bytes of [a-z0-9._-], got " + strconv.Quote(slug))
	}
	for _, r := range reservedSlugs {
		if slug == r {
			panic("reserved slug: " + slug)
		}
	}
	if strings.HasPrefix(slug, galleryPrefix) {
		panic("reserved slug: " + galleryPrefix + "* renders a gallery, use SetGallery")
	}
}

// Set creates or replaces one slot.
func Set(cur realm, slug, body string) {
	assertAdmin(cur)
	assertWritableSlug(slug)
	rev++
	slots.Set(slug, &slot{body: body, rev: rev, updated: runtime.ChainHeight()})
}

// Append adds to the end of a slot, creating it when absent, for bodies too
// large for one transaction.
func Append(cur realm, slug, body string) {
	assertAdmin(cur)
	assertWritableSlug(slug)
	prev := ""
	if v := slots.Get(slug); v != nil {
		prev = v.(*slot).body
	}
	rev++
	slots.Set(slug, &slot{body: prev + body, rev: rev, updated: runtime.ChainHeight()})
}

// Delete removes a slot. Deleting "layout" falls back to the built-in layout.
func Delete(cur realm, slug string) {
	assertAdmin(cur)
	if _, removed := slots.Remove(slug); !removed {
		panic("no such slot: " + slug)
	}
	rev++
}

// Get returns a slot body, or "" when the slot does not exist.
func Get(slug string) string {
	if v := slots.Get(slug); v != nil {
		return v.(*slot).body
	}
	return ""
}

// Revision is the total number of slot writes accepted.
func Revision() int { return rev }

// Heart records one <3 from the caller. Each address can send exactly one.
func Heart(cur realm) {
	from := cur.Previous().Address()
	if hearts.Has(from.String()) {
		panic("already sent: one <3 per address")
	}
	hearts.Set(from.String(), runtime.ChainHeight())

	recent = append([]address{from}, recent...)
	if len(recent) > maxRecent {
		recent = recent[:maxRecent]
	}
}

// Hearts returns how many distinct addresses sent a <3.
func Hearts() int { return hearts.Size() }

// HasHeart reports whether addr already sent a <3.
func HasHeart(addr address) bool { return hearts.Has(addr.String()) }
