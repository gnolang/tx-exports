package nsskin

import (
	"strings"

	"gno.land/p/g1pmffzfv3326akjjs27mqp4zgumlnqne7urjm7x/grc721"
	"gno.land/p/nt/ufmt/v0"
	"gno.land/r/g1pmffzfv3326akjjs27mqp4zgumlnqne7urjm7x/nsdata/v1"
)

/*
ArtForName is the one question the renderer asks, and it is answered here
so the rule lives with the data it depends on.

It returns the sprite a name should be drawn with, or "" for the ordinary
card. Everything the renderer would otherwise have to remember to check
is inside it, because a renderer that has to remember three things before
drawing is one that eventually forgets one.

The checks, and what each of them makes self-cleaning:

	the name wears a token at all
	that token's definition has not been WITHDRAWN — so a takedown
	  reverts every name wearing it, everywhere, at once, with no
	  migration and no per-name cleanup
	the binding is FRESH, pinned to this registration — so a name that
	  lapsed and was taken by somebody else inherits nothing
	the LOCK still matches — belt and braces, since Attach checks it too

Note what is NOT checked: who holds the token in their wallet. Nobody
does. It is in this realm's custody for as long as it is attached, which
is what makes the skin travel with the name instead of with a wallet.
*/
func ArtForName(label, domain string) string {
	tid := SkinOnName(label, domain)
	if tid == "" {
		return ""
	}
	v := bound.Get(tid)
	if v == nil {
		return ""
	}
	b := v.(*binding)

	if !nsdata.NameExists(label, domain) {
		return ""
	}
	_, registered, _, _, _, _ := nsdata.GetNameInfo(label, domain)
	if registered != b.registered {
		return "" // a different registration of the same label
	}

	id, ok := skinOfToken(tid)
	if !ok {
		return ""
	}
	// Normalized on the way in, so a token minted from a non-canonical
	// id before Buy/Mint were fixed starts rendering instead of staying
	// a blank card its holder already paid for.
	sv := skins.Get(strings.ToLower(strings.TrimSpace(id)))
	if sv == nil {
		return ""
	}
	s := sv.(*skin)
	if s.withdrawn {
		return ""
	}
	if s.lock != "" && s.lock != domain {
		return ""
	}
	return s.art
}

// SkinInfo describes a DEFINITION, for a shop listing or a skin's own
// card. Withdrawn is returned rather than hidden: a holder is entitled
// to know, and a listing that silently vanishes is worse than one that
// says what happened.
func SkinInfo(id string) (name, art, lock string, artist address, withdrawn bool, minted int64) {
	s := mustSkin(id)
	return s.name, s.art, s.lock, s.artist, s.withdrawn, s.minted
}

func SkinExists(id string) bool {
	return skins.Has(strings.ToLower(strings.TrimSpace(id)))
}

// ListSkins returns every definition id, in tree order. Small by
// construction — this is a curated shop, not a submission firehose — and
// if that ever stops being true it wants paging rather than a bigger
// answer.
func ListSkins() []string {
	var out []string
	skins.Iterate("", "", func(k string, _ any) bool {
		out = append(out, k)
		return false
	})
	return out
}

/*
AllSkins packs the whole catalogue into ONE read.

A shop page needs every definition's name, lock and availability, and
asking for them one at a time is sixty round trips before anything
appears on screen. The ART is deliberately NOT here: it is the bulk of
the data, it is committed in the repo as the canonical source, and a
page that already has it does not need to fetch it again.

Six fields: id, name, lock, withdrawn, minted, price in ugnot.

Tab-separated fields, newline-separated records — not JSON, because
building JSON by string concatenation in a realm is how quoting bugs get
shipped, and a shop is not worth that risk. No field can contain a tab
or a newline: ids and locks are [a-z0-9-] by rule, and a name is checked
here rather than assumed.
*/
func AllSkins() string {
	var b strings.Builder
	skins.Iterate("", "", func(k string, v any) bool {
		s := v.(*skin)
		nm := s.name
		if strings.ContainsAny(nm, "\t\n") {
			nm = "?" // never seen: DefineSkin would have to have accepted it
		}
		w := "0"
		if s.withdrawn {
			w = "1"
		}
		// PRICE IS THE SIXTH FIELD, appended rather than inserted, so a
		// page shipped before per-design pricing keeps reading the five
		// it knows and simply does not see this one.
		b.WriteString(k + "\t" + nm + "\t" + s.lock + "\t" + w + "\t" +
			ufmt.Sprintf("%d", s.minted) + "\t" +
			ufmt.Sprintf("%d", PriceOf(k)) + "\n")
		return false
	})
	return b.String()
}

func skinOfToken(tid string) (string, bool) {
	v := tokenSkin.Get(tid)
	if v == nil {
		return "", false
	}
	return v.(string), true
}

// SkinOfToken is skinOfToken for callers outside the realm.
func SkinOfToken(tid string) string {
	id, _ := skinOfToken(tid)
	return id
}

func GetAdmin() address        { return admin }
func GetTokenURIBase() string  { return tokenURIBase }
func IsTrustedShop(a address) bool {
	return trustedShop.Has(a.String())
}

// ---------------------------------------------------------------- grc721

func Name() string      { return nft.Name() }
func Symbol() string    { return nft.Symbol() }
func TokenCount() int64 { return nft.TokenCount() }

func BalanceOf(owner address) int64 {
	bal, err := nft.BalanceOf(owner)
	if err != nil {
		panic(err)
	}
	return bal
}

// OwnerOf does NOT hide a withdrawn skin's owner, and that is the
// opposite of what nsdata does for an expired name.
//
// There, hiding the owner is an anti-scam measure: a lapsed name must
// not be listable, because the seller no longer controls it. Here the
// holder still owns the token completely — withdrawal only stops it
// being DRAWN. Hiding the owner would break transfers and approvals for
// somebody who has done nothing wrong, to solve a problem that is not
// theirs.
func OwnerOf(tid grc721.TokenID) address {
	owner, err := nft.OwnerOf(tid)
	if err != nil {
		panic(err)
	}
	return owner
}

// Total, the same way nsdata.GetApproved is: the zero address means
// nobody is approved, and only an unknown token id panics. The vendored
// NFT returns an error for both cases, and collapsing them made "no
// approval" indistinguishable from "no such token" — so no caller could
// fall back to the operator grant without catching a panic first.
func GetApproved(tid grc721.TokenID) address {
	a, err := nft.GetApproved(tid)
	if err != nil {
		if _, oerr := nft.OwnerOf(tid); oerr != nil {
			panic(err)
		}
		return ""
	}
	return a
}

func IsApprovedForAll(owner, operator address) bool {
	return nft.IsApprovedForAll(owner, operator)
}

func TokenURI(tid grc721.TokenID) string {
	return tokenURIBase + string(tid)
}
