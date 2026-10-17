package nsnft

import (
	"chain"
	"encoding/base64"
	"strings"

	"gno.land/p/nt/grc721/v0"
)

/*
WHAT A WALLET SHOWS, AND WHY THIS FROZEN REALM DOES NOT DRAW IT.

Adena puts TokenURI(tid) straight into an <img src>, so it must return
the image itself (a data:image/svg+xml URI), and it reads TokenMetadata
as a camelCase JSON string. Both have to be answered HERE, because the
collection id names this realm. But the card is the most cosmetic and
most-revised thing in the project, and this realm can never change — so
the drawing is delegated to a view realm through a Renderer, and only
the delegation is frozen.

This realm cannot import the view: the view reads the registry, which
reads this ledger, and imports may not form a cycle. So the view hands
this realm an object at runtime instead. gno runs a method declared in
another realm with THAT realm's storage authority (the declaring-realm
borrow), so the renderer can read anything and write nothing of ours —
it gets no `cur`, so it cannot cross into anything as us either. What it
can do is draw something wrong, slow or broken, which is a display
problem: ClearRenderer withdraws it in one transaction (admin, recovery
or guardian) and wallets fall back to the built-in card below.

Who may register is pinned to ONE package path, approved through the
timelock (ProposeRenderer), because what every wallet shows for every
name is worth a waiting period: a hostile card could tell holders to pay
somebody. The ledger is born approving its own generation's view.
*/

// Renderer draws one token for wallets. Implemented by the view realm.
type Renderer interface {
	// TokenImage returns the image itself, as a data: URI.
	TokenImage(tid string) string
	// TokenMetadata returns the metadata as a JSON string: name,
	// description, externalUrl, attributes [{traitType, value}].
	TokenMetadata(tid string) string
}

var (
	// The one realm allowed to register a renderer; "" for none.
	rendererPath string
	// What it registered; nil means the built-in card.
	renderer Renderer
)

// RegisterRenderer is called BY the approved view realm, handing over
// the object that draws. Refused from anywhere else.
func RegisterRenderer(cur realm, r Renderer) {
	assertNoSend(cur)
	registerRenderer(cur.Previous().PkgPath(), r)
}

func registerRenderer(callerPath string, r Renderer) {
	if rendererPath == "" || callerPath != rendererPath {
		panic("nsnft: only the approved view realm may register a renderer")
	}
	if r == nil {
		panic("nsnft: no renderer given")
	}
	renderer = r
	chain.Emit("RendererRegistered", "path", callerPath)
}

// ClearRenderer withdraws the art at once, approval included, so the
// realm that drew it cannot simply register again: approving one takes
// the timelock. Admin, recovery or guardian.
func ClearRenderer(cur realm) {
	assertNoSend(cur)
	clearRenderer(cur.Previous().Address())
}

func clearRenderer(caller address) {
	assertCanRevoke(caller)
	prev := rendererPath
	rendererPath = ""
	renderer = nil
	chain.Emit("RendererCleared", "path", prev, "by", caller.String())
}

func RendererPath() string { return rendererPath }
func HasRenderer() bool    { return renderer != nil }

// TokenURI is the token's image, as a data: URI, for a token that exists.
// A renderer that answers nothing gets the built-in card instead: an
// empty <img src> is a broken picture in every wallet.
func TokenURI(tid string) (string, error) {
	if !Exists(tid) {
		return "", grc721.ErrInvalidTokenId
	}
	if renderer != nil {
		if img := renderer.TokenImage(tid); img != "" {
			return img, nil
		}
	}
	return builtinImage(tid), nil
}

// TokenMetadata is the token's metadata as a camelCase JSON string, the
// shape Adena reads. The image is not in it; that is TokenURI.
func TokenMetadata(tid string) (string, error) {
	if !Exists(tid) {
		return "", grc721.ErrInvalidTokenId
	}
	if renderer != nil {
		if meta := renderer.TokenMetadata(tid); meta != "" {
			return meta, nil
		}
	}
	return builtinMetadata(tid), nil
}

/*
THE BUILT-IN CARD, for when no view is registered: the name, plainly.

Deliberately plain and deliberately free of anything that could go
stale. No URL — a domain this realm named could lapse and be bought by
somebody else, and the link would then live in every wallet forever — and
no colours or claims that a policy change could make wrong.
*/
func builtinImage(tid string) string {
	size := 40
	if n := len(tid); n > 16 {
		size = 640 / n
		if size < 8 {
			size = 8
		}
	}
	svg := `<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 400 400">` +
		`<rect width="400" height="400" fill="#0b0d10"/>` +
		`<text x="200" y="200" text-anchor="middle" font-family="monospace" font-size="` +
		itoa(int64(size)) + `" fill="#f4f4f5">` + escapeXML(tid) + `</text>` +
		`<text x="200" y="372" text-anchor="middle" font-family="monospace" font-size="13"` +
		` letter-spacing="3" fill="#71717a">MEME NAME SERVICE</text></svg>`
	return "data:image/svg+xml;base64," + base64.StdEncoding.EncodeToString([]byte(svg))
}

func builtinMetadata(tid string) string {
	return `{"name":"` + escapeJSON(tid) + `",` +
		`"description":"A name on the Meme Name Service.",` +
		`"attributes":[]}`
}

func escapeXML(s string) string {
	s = strings.ReplaceAll(s, "&", "&amp;")
	s = strings.ReplaceAll(s, "<", "&lt;")
	s = strings.ReplaceAll(s, ">", "&gt;")
	s = strings.ReplaceAll(s, `"`, "&quot;")
	s = strings.ReplaceAll(s, "'", "&apos;")
	return s
}

func escapeJSON(s string) string {
	var b strings.Builder
	for i := 0; i < len(s); i++ {
		c := s[i]
		switch {
		case c == '"':
			b.WriteString(`\"`)
		case c == '\\':
			b.WriteString(`\\`)
		case c < 0x20:
			const hex = "0123456789abcdef"
			b.WriteString(`\u00`)
			b.WriteByte(hex[c>>4])
			b.WriteByte(hex[c&0xf])
		default:
			b.WriteByte(c)
		}
	}
	return b.String()
}
