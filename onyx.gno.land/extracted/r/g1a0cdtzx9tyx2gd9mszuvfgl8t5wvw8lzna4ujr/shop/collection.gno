package shop

import (
	"strconv"

	"chain"

	"gno.land/p/nt/avl/v0"
	"gno.land/p/nt/grc721/enumerable/v0"
	"gno.land/p/nt/grc721/metadata/v0"
	"gno.land/p/nt/grc721/v0"
	"gno.land/p/nt/seqid/v0"
)

const (
	maxImageLen = 200
	maxTidLen   = 64
	saleCap     = 100
	pageMax     = 50
)

var (
	token    *grc721.Token
	ledger   *grc721.PrivateLedger
	metaView *metadata.Metadata
	metaLed  *metadata.Ledger
	enumView *enumerable.Enumerable
	tokenSeq seqid.ID
	creator  address
	ready    bool
	admins   avl.Tree
	listings avl.Tree
	sales    [saleCap]sale
	saleN    int
)

type listing struct {
	Seller address
	Price  int64
}

type sale struct {
	Tid    string
	Seller address
	Buyer  address
	Price  int64
	Name   string
}

// Init creates the collection once. The caller is the creator and can mint.
func Init(cur realm, name, symbol string) {
	caller := requireUser(cur)
	if ready {
		panic("market: already init")
	}
	token, ledger = grc721.NewToken(name, symbol, tokenSeq.Next(), cur)
	metaView, metaLed = metadata.NewMetadata(ledger)
	enumView, _ = enumerable.NewEnumerable(ledger)
	creator = caller
	ready = true
	chain.Emit("Init", "creator", caller.String(), "name", name, "symbol", symbol)
}

// Grant lets who mint. Only the creator can call it.
func Grant(cur realm, who address) {
	caller := requireUser(cur)
	requireReady()
	if caller != creator || !who.IsValid() || who == creator {
		panic("market: admin")
	}
	admins.Set(who.String(), true)
	chain.Emit("Grant", "admin", who.String())
}

// Revoke removes a minter. Only the creator can call it.
func Revoke(cur realm, who address) {
	caller := requireUser(cur)
	requireReady()
	if caller != creator {
		panic("market: admin")
	}
	if _, removed := admins.Remove(who.String()); !removed {
		panic("market: admin")
	}
	chain.Emit("Revoke", "admin", who.String())
}

func canMint(caller address) bool {
	if caller == creator {
		return true
	}
	return admins.Get(caller.String()) != nil
}

// Mint issues one token to the caller. image is an https URL.
func Mint(cur realm, tid, name, image string) {
	caller := requireUser(cur)
	requireReady()
	if !canMint(caller) {
		panic("market: not minter")
	}
	id := parseTid(tid)
	if name == "" || len(name) > grc721.MaxNameLen || !ascii(name) {
		panic("market: name")
	}
	if !httpsURL(image) {
		panic("market: image")
	}
	if err := ledger.Mint(caller, id); err != nil {
		panic("market: mint")
	}
	if err := metaLed.SetTokenURI(id, image); err != nil {
		panic("market: tokenURI")
	}
	if err := metaLed.SetTokenMetadata(id, metadata.Data{
		Name:        name,
		Description: name,
		Image:       image,
	}); err != nil {
		panic("market: metadata")
	}
	chain.Emit("Mint", "tid", tid, "owner", caller.String(), "name", name)
}

// Transfer moves a token the caller owns.
func Transfer(cur realm, to address, tid string) {
	caller := requireUser(cur)
	requireReady()
	if !to.IsValid() || to == caller {
		panic("market: to")
	}
	id := parseTid(tid)
	if err := ledger.TransferFrom(caller, caller, to, id); err != nil {
		panic("market: transfer")
	}
}

func requireReady() {
	if !ready {
		panic("market: call Init")
	}
}

func requireUser(cur realm) address {
	prev := cur.Previous()
	if !prev.IsUserCall() {
		panic("market: eoa")
	}
	return prev.Address()
}

func parseTid(tid string) grc721.TokenID {
	if tid == "" || len(tid) > maxTidLen || !ascii(tid) {
		panic("market: tid")
	}
	for i := 0; i < len(tid); i++ {
		c := tid[i]
		ok := (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') || c == '_' || c == '-'
		if !ok {
			panic("market: tid")
		}
	}
	return grc721.TokenID(tid)
}

func httpsURL(s string) bool {
	const prefix = "https://"
	if len(s) < len(prefix)+1 || len(s) > maxImageLen || !ascii(s) {
		return false
	}
	return s[:len(prefix)] == prefix
}

func ascii(s string) bool {
	for i := 0; i < len(s); i++ {
		if s[i] < 0x20 || s[i] > 0x7e {
			return false
		}
	}
	return true
}

func ownerOf(tid grc721.TokenID) address {
	owner, err := token.OwnerOf(tid)
	if err != nil {
		panic("market: owner")
	}
	return owner
}

func metaNameImage(tid grc721.TokenID) (string, string) {
	data, err := metaView.TokenMetadata(tid)
	if err != nil {
		return "", ""
	}
	return data.Name, data.Image
}

func page(offset, limit int) (int, int) {
	if offset < 0 {
		offset = 0
	}
	if limit < 1 {
		limit = 1
	}
	if limit > pageMax {
		limit = pageMax
	}
	return offset, limit
}

func quote(s string) string {
	out := "\""
	for i := 0; i < len(s); i++ {
		c := s[i]
		if c == '\\' || c == '"' {
			out += "\\"
		}
		out += s[i : i+1]
	}
	return out + "\""
}

func i64(n int64) string {
	return strconv.FormatInt(n, 10)
}
