// Package home is samcrew's page on gno.land, served at /u/samcrew.
//
// The page is assembled from SLOTS (named markdown fragments, one Set each);
// the slot named "layout" is the template and every :slug: in it is filled in
// a single pass. The crew roster is not a slot: see crew.gno.
//
// The admin starts as the samcrew namespace multisig and moves with a
// two-step ProposeAdmin / AcceptAdmin, so it can later be handed to the DAO.
package home

import (
	"strconv"
	"strings"

	"chain/runtime"

	"gno.land/p/nt/avl/v0"
)

const (
	layoutSlug = "layout"
	maxSlugLen = 64
)

type slot struct {
	body    string
	rev     int
	updated int64
}

var (
	admin        = address("g136j0m08pkm2lwwde9dmlx8uee26llent9s5cpf") // samcrew namespace, 2-of-3
	pendingAdmin address

	slots = avl.NewTree() // slug -> *slot
	rev   int
)

var reservedSlugs = []string{"chainid", "crew", "height", "hero", "realm", "rev"}

func init() {
	h := runtime.ChainHeight()
	for _, s := range defaultSlots() {
		rev++
		slots.Set(s.slug, &slot{body: s.body, rev: rev, updated: h})
	}
	for _, g := range defaultGalleries() {
		galleries.Set(g.name, parseGallery(g.spec))
	}
	for _, m := range defaultCrew() {
		addMember(m.id, m.handle, m.role, m.team, m.url)
	}
	for _, p := range defaultProfiles() {
		m := mustMember(p.id)
		m.addr, m.home, m.line = p.addr, p.home, p.line
		byAddr.Set(p.addr.String(), p.id)
	}
}

// ---------------------------------------------------------------------------
// Admin

func assertAdmin(cur realm) {
	if cur.Previous().Address() != admin {
		panic("restricted to admin")
	}
}

// Admin returns the current admin address.
func Admin() address { return admin }

// ProposeAdmin starts a handover. Nothing changes until the new address calls
// AcceptAdmin, so a typo cannot lock the page.
func ProposeAdmin(cur realm, next address) {
	assertAdmin(cur)
	if !next.IsValid() {
		panic("invalid address")
	}
	pendingAdmin = next
}

// AcceptAdmin completes a handover started by ProposeAdmin.
func AcceptAdmin(cur realm) {
	caller := cur.Previous().Address()
	if pendingAdmin == "" || caller != pendingAdmin {
		panic("restricted to the proposed admin")
	}
	admin = caller
	pendingAdmin = ""
}

// ---------------------------------------------------------------------------
// Slots

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
