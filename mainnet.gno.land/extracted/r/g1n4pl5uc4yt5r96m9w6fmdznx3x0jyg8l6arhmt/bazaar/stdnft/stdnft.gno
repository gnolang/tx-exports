package stdnft

import (
	"chain"

	"gno.land/p/nt/grc721/enumerable/v0"
	"gno.land/p/nt/grc721/metadata/v0"
	"gno.land/p/nt/grc721/v0"
	"gno.land/p/nt/seqid/v0"
)

// Adena probe: collection realm wrapping genesis GRC721 (string TokenID,
// metadata TokenURI, enumerable TokenOfOwnerByIndex). No List/Buy escrow.

const (
	maxImageLen  = 200
	defaultImage = "https://bazaar-gno.vercel.app/gnomies.png"
)

var (
	token    *grc721.Token
	ledger   *grc721.PrivateLedger
	metaView *metadata.Metadata
	metaLed  *metadata.Ledger
	enumView *enumerable.Enumerable
	tokenSeq seqid.ID
	inited   bool
	creator  address
)

func Init(cur realm, name, symbol string) {
	if !cur.IsCurrent() {
		panic("stdnft: spoofed realm")
	}
	if !cur.Previous().IsUserCall() {
		panic("stdnft: EOA only")
	}
	if inited {
		panic("stdnft: already initialized")
	}
	tok, led := grc721.NewToken(name, symbol, tokenSeq.Next(), cur)
	token = tok
	ledger = led
	metaView, metaLed = metadata.NewMetadata(led)
	enumView, _ = enumerable.NewEnumerable(led)
	creator = cur.Previous().Address()
	inited = true
	chain.Emit("Init", "creator", creator.String(), "name", name, "symbol", symbol)
}

func Mint(cur realm, tid, name, image string) {
	caller := requireUser(cur)
	if caller != creator {
		panic("stdnft: not creator")
	}
	if tid == "" {
		panic("stdnft: tid")
	}
	if name == "" || len(name) > grc721.MaxNameLen {
		panic("stdnft: name")
	}
	if image == "" {
		image = defaultImage
	}
	if len(image) > maxImageLen {
		panic("stdnft: image")
	}
	id := grc721.TokenID(tid)
	if err := ledger.Mint(caller, id); err != nil {
		panic("stdnft: mint")
	}
	if err := metaLed.SetTokenURI(id, tokenJSON(name, image)); err != nil {
		panic("stdnft: tokenURI")
	}
	if err := metaLed.SetTokenMetadata(id, metadata.Data{
		Name:        name,
		Description: name,
		Image:       image,
		Attributes:  []metadata.Trait{{TraitType: "Kind", Value: "stdnft"}},
	}); err != nil {
		panic("stdnft: metadata")
	}
	chain.Emit("Mint", "id", tid, "owner", caller.String())
}

func Name() string {
	requireInit()
	return token.GetName()
}

func Symbol() string {
	requireInit()
	return token.GetSymbol()
}

func TotalSupply() int64 {
	requireInit()
	return token.TotalSupply()
}

func BalanceOf(owner string) int64 {
	requireInit()
	who := address(owner)
	if !who.IsValid() {
		return 0
	}
	n, err := token.BalanceOf(who)
	if err != nil {
		return 0
	}
	return n
}

func OwnerOf(tid string) string {
	requireInit()
	owner, err := token.OwnerOf(grc721.TokenID(tid))
	if err != nil {
		panic("stdnft: owner")
	}
	return owner.String()
}

func TokenURI(tid string) string {
	requireInit()
	u, err := metaView.TokenURI(grc721.TokenID(tid))
	if err != nil {
		panic("stdnft: uri")
	}
	return u
}

func TokenOfOwnerByIndex(owner string, index int64) string {
	requireInit()
	who := address(owner)
	if !who.IsValid() {
		panic("stdnft: addr")
	}
	id, err := enumView.TokenOfOwnerByIndex(who, index)
	if err != nil {
		panic("stdnft: index")
	}
	return id.String()
}

func TokenByIndex(index int64) string {
	requireInit()
	id, err := enumView.TokenByIndex(index)
	if err != nil {
		panic("stdnft: index")
	}
	return id.String()
}

func TokensOf(owner string) string {
	requireInit()
	who := address(owner)
	if !who.IsValid() {
		return ""
	}
	n, err := token.BalanceOf(who)
	if err != nil || n == 0 {
		return ""
	}
	out := ""
	var i int64
	for i = 0; i < n; i++ {
		id, err := enumView.TokenOfOwnerByIndex(who, i)
		if err != nil {
			panic("stdnft: tokens")
		}
		if out != "" {
			out += ","
		}
		out += id.String()
	}
	return out
}

func Approve(cur realm, to, tid string) {
	caller := requireUser(cur)
	who := address(to)
	if to != "" && !who.IsValid() {
		panic("stdnft: addr")
	}
	if err := ledger.Approve(caller, who, grc721.TokenID(tid)); err != nil {
		panic("stdnft: approve")
	}
}

func TransferFrom(cur realm, from, to, tid string) {
	caller := requireUser(cur)
	src := address(from)
	dst := address(to)
	if !src.IsValid() || !dst.IsValid() {
		panic("stdnft: addr")
	}
	if err := ledger.TransferFrom(caller, src, dst, grc721.TokenID(tid)); err != nil {
		panic("stdnft: transfer")
	}
}

func Creator() string {
	requireInit()
	return creator.String()
}

func Render(_ string) string {
	if !inited {
		return "# StdNFT\n\ncall Init first\n"
	}
	return token.RenderHome() + "\ncreator: " + creator.String() + "\n"
}

func requireInit() {
	if !inited {
		panic("stdnft: call Init first")
	}
}

func requireUser(cur realm) address {
	requireInit()
	if !cur.IsCurrent() {
		panic("stdnft: spoofed realm")
	}
	if !cur.Previous().IsUserCall() {
		panic("stdnft: EOA only")
	}
	return cur.Previous().Address()
}

func tokenJSON(name, image string) string {
	body := `{"name":` + jsonStr(name) + `,"description":` + jsonStr(name) + `,"image":` + jsonStr(image) + `,"attributes":[{"trait_type":"Kind","value":"stdnft"}]}`
	return "data:application/json;charset=utf-8," + pctURI(body)
}

func jsonStr(s string) string {
	out := `"`
	for _, r := range s {
		switch r {
		case '"':
			out += `\"`
		case '\\':
			out += `\\`
		case '\n':
			out += `\n`
		default:
			out += string(r)
		}
	}
	return out + `"`
}

func pctURI(s string) string {
	out := ""
	for i := 0; i < len(s); i++ {
		c := s[i]
		if (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') || c == '-' || c == '_' || c == '.' || c == '~' {
			out += string(c)
			continue
		}
		hex := "0123456789ABCDEF"
		out += "%"
		out += string([]byte{hex[c>>4], hex[c&15]})
	}
	return out
}
