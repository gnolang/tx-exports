package nsskin

import (
	"strings"

	"gno.land/p/g1pmffzfv3326akjjs27mqp4zgumlnqne7urjm7x/grc721"
	"gno.land/p/nt/ufmt/v0"
)

func assertIsAdmin(cur realm) {
	if cur.Previous().Address() != admin {
		panic("nsskin: not the admin")
	}
}

func assertIsAdminOrShop(cur realm) {
	a := cur.Previous().Address()
	if a == admin {
		return
	}
	if !trustedShop.Has(a.String()) {
		panic("nsskin: not the admin or a trusted shop")
	}
}

/*
DefineSkin registers a design. It does not mint anything.

Definitions and copies are separate calls on purpose: defining is the
expensive, careful, one-off act that puts an artist's work and a sprite
on chain, while minting is the cheap repeated one. Rolling them together
would mean re-sending the artwork with every sale.

A definition may be REDEFINED only while nothing has been minted from it.
After the first copy exists, the art is what its holders bought and it
stops being ours to edit — the only lever left is withdrawal, which is
honest about what it is doing.
*/
func DefineSkin(cur realm, id, name, art, lock string, artist address) {
	assertIsAdmin(cur)
	id = strings.ToLower(strings.TrimSpace(id))
	assertValidID(id)
	if len(name) == 0 || len(name) > maxSkinName {
		panic("nsskin: a skin needs a name, of at most 40 characters")
	}
	if len(art) == 0 || len(art) > maxSkinArt {
		panic(ufmt.Sprintf("nsskin: art is %d bytes, the limit is %d", len(art), maxSkinArt))
	}
	// The SHAPE of the sprite is checked here; whether it renders is
	// nsview's business. Storing something the renderer will reject
	// silently is the failure mode this exists to prevent — a skin that
	// draws nothing, sold to somebody, discovered later.
	assertValidArt(art)
	if lock != "" {
		assertValidLabel(lock)
	}
	if artist == "" {
		panic("nsskin: a skin needs an artist to pay")
	}

	if v := skins.Get(id); v != nil {
		s := v.(*skin)
		if s.minted > 0 {
			panic(ufmt.Sprintf(
				"nsskin: %s has %d copies out — redefining it would change "+
					"what those holders bought; withdraw it instead", id, s.minted))
		}
		s.name, s.art, s.lock, s.artist = name, art, lock, artist
		return
	}
	skins.Set(id, &skin{name: name, art: art, lock: lock, artist: artist})
}

/*
Mint issues one copy of a definition to somebody.

The serial is the definition's own running count, so token ids read as
"ember#1", "ember#2". Never reused: the counter only goes up, even across
burns, because a reissued id would let a new token inherit whatever an
old one was pointed at.
*/
func Mint(cur realm, id string, to address) string {
	assertIsAdminOrShop(cur)
	assertNoSend(cur)
	/* NORMALIZED BEFORE THE TOKEN ID IS BUILT.
	   mustSkin and PriceOf lowercase what they are given; this did not,
	   so Mint("Ember", …) resolved the right definition and then minted
	   "Ember#3" while tokenSkin recorded the raw id. ArtForName looks the
	   definition up in a tree DefineSkin lowercased, so the token bound,
	   charged, and then rendered nothing, forever. An admin typing a
	   capital into a form was all it took. */
	id = strings.ToLower(strings.TrimSpace(id))
	s := mustSkin(id)
	if s.withdrawn {
		panic("nsskin: " + id + " has been withdrawn and cannot be minted")
	}
	if to == "" {
		panic("nsskin: no recipient")
	}
	s.minted++
	tid := ufmt.Sprintf("%s#%d", id, s.minted)
	if err := nft.Mint(to, grc721.TokenID(tid)); err != nil {
		panic("nsskin: mint failed: " + err.Error())
	}
	tokenSkin.Set(tid, id)
	return tid
}

/*
Withdraw is the takedown control, and SKINS.md §6 makes it
non-negotiable: it has to exist before a single outside submission is
accepted, which means it has to exist now, while there is nothing to take
down and it is cheap to build.

Somebody will submit a character somebody else owns, or a bank's logo, or
something vile, and it will render inside other people's wallets with our
name beside it. When that happens the fix has to be one call, not a
migration.

It does NOT burn anything. The holder keeps the token; it simply stops
rendering, and every name pointing at it falls back to the ordinary card
at once. Burning somebody's property to solve our problem is a different
act with different consequences, and it is not this one.
*/
func Withdraw(cur realm, id string, withdrawn bool) {
	assertNoSend(cur)
	assertIsAdmin(cur)
	mustSkin(id).withdrawn = withdrawn
}

func SetTokenURIBase(cur realm, base string) {
	assertNoSend(cur)
	assertIsAdmin(cur)
	tokenURIBase = base
}

func SetAdmin(cur realm, a address) {
	assertNoSend(cur)
	assertIsAdmin(cur)
	if a == "" {
		panic("nsskin: refusing to leave the realm with no admin")
	}
	admin = a
}

func TrustShop(cur realm, a address, trusted bool) {
	assertNoSend(cur)
	assertIsAdmin(cur)
	if trusted {
		trustedShop.Set(a.String(), true)
		return
	}
	trustedShop.Remove(a.String())
}

// ---------------------------------------------------------------- grc721

func TransferFrom(cur realm, from, to address, tid grc721.TokenID) {
	assertNoSend(cur)
	if err := nft.TransferFrom(cur.Previous().Address(), from, to, tid); err != nil {
		panic("nsskin: " + err.Error())
	}
}

func Approve(cur realm, to address, tid grc721.TokenID) {
	assertNoSend(cur)
	if err := nft.Approve(cur.Previous().Address(), to, tid); err != nil {
		panic("nsskin: " + err.Error())
	}
}

func SetApprovalForAll(cur realm, operator address, approved bool) {
	assertNoSend(cur)
	if err := nft.SetApprovalForAll(cur.Previous().Address(), operator, approved); err != nil {
		panic("nsskin: " + err.Error())
	}
}

// ---------------------------------------------------------------- checks

func mustSkin(id string) *skin {
	v := skins.Get(strings.ToLower(strings.TrimSpace(id)))
	if v == nil {
		panic("nsskin: no such skin: " + id)
	}
	return v.(*skin)
}

// An id goes into every token id and into the pointer a name stores, so
// it has to survive being split on "#" and compared byte for byte.
func assertValidID(id string) {
	if len(id) == 0 || len(id) > maxSkinID {
		panic("nsskin: a skin id must be 1 to 24 characters")
	}
	for i := 0; i < len(id); i++ {
		c := id[i]
		if (c >= 'a' && c <= 'z') || (c >= '0' && c <= '9') || c == '-' {
			continue
		}
		panic("nsskin: a skin id may only use a-z, 0-9 and -: " + id)
	}
}

func assertValidLabel(l string) {
	if len(l) == 0 || len(l) > 63 {
		panic("nsskin: a lock must be a domain label")
	}
	for i := 0; i < len(l); i++ {
		c := l[i]
		if (c >= 'a' && c <= 'z') || (c >= '0' && c <= '9') || c == '-' {
			continue
		}
		panic("nsskin: a lock may only use a-z, 0-9 and -: " + l)
	}
}

/*
assertValidArt mirrors the sprite checks nsview makes, and it is here for
one reason: nsview REJECTS THE WHOLE SPRITE SILENTLY. A malformed skin
does not draw a broken picture, it draws nothing at all, with no error
anywhere a person would see it.

Storing one would mean selling somebody a blank card and finding out
weeks later. So the shape is checked at the point of storage, where the
failure is a panic in a transaction nobody has paid for yet.

Deliberately checks the SHAPE and not the rendering. This realm does not
know how a card is composed and should not learn — that is the whole
reason the renderer is swappable.
*/
func assertValidArt(enc string) {
	parts := strings.Split(enc, "|")
	n := len(parts) - 1
	if n < 4 || n > 64 {
		panic(ufmt.Sprintf("nsskin: a sprite needs 4 to 64 rows, this has %d", n))
	}
	keys := map[string]bool{}
	for _, e := range strings.Split(parts[0], ",") {
		if len(e) != 8 || e[1] != '#' {
			panic("nsskin: a palette entry must be a letter, #, and six hex digits: " + e)
		}
		for i := 2; i < 8; i++ {
			c := e[i]
			if (c >= '0' && c <= '9') || (c >= 'a' && c <= 'f') || (c >= 'A' && c <= 'F') {
				continue
			}
			panic("nsskin: not a hex colour: " + e)
		}
		keys[e[:1]] = true
	}
	for y := 1; y <= n; y++ {
		if len(parts[y]) != n {
			panic(ufmt.Sprintf(
				"nsskin: row %d is %d wide but the sprite is %d rows tall — it must be square",
				y, len(parts[y]), n))
		}
		for x := 0; x < n; x++ {
			ch := parts[y][x : x+1]
			if ch == "." || keys[ch] {
				continue
			}
			panic(ufmt.Sprintf("nsskin: row %d uses colour %s, which the palette does not define", y, ch))
		}
	}
}
