// Package fishnft is the six model tokens, one for each sea GLB.
// It takes no GNOT, draws no FISH, and does not replace shoal/fish.
package fishnft

import (
	"chain"
	"chain/runtime/unsafe"
	"errors"
	"strconv"
	"strings"

	"gno.land/p/nt/grc721/metadata/v0"
	"gno.land/p/nt/grc721/v0"
	"gno.land/p/nt/seqid/v0"
)

type body struct {
	id      int
	rarity  string
	species string
	file    string
	owner   address
	uri     string
}

var (
	token    *grc721.Token
	ledger   *grc721.PrivateLedger
	metaLed  *metadata.Ledger
	tokenSeq seqid.ID
	bodies   []*body
	minted   int
)

// Init issues token 1 through 6 to the caller. A second call does nothing useful and panics.
func Init(cur realm) {
	if !cur.IsCurrent() {
		panic("fishnft: realm")
	}
	if !cur.Previous().IsUserCall() {
		panic("fishnft: eoa")
	}
	if token != nil {
		panic("fishnft: init")
	}
	rejectPay()
	tok, led := grc721.NewToken("Shoal Models", "MODEL", tokenSeq.Next(), cur)
	token = tok
	ledger = led
	_, metaLed = metadata.NewMetadata(led)
	bodies = []*body{nil}
	caller := cur.Previous().Address()
	issue(caller, "common", "Minnow", "common.glb")
	issue(caller, "uncommon", "Mackerel", "uncommon.glb")
	issue(caller, "rare", "Snapper", "rare.glb")
	issue(caller, "epic", "Angler", "epic.glb")
	issue(caller, "legendary", "Koi Dragon", "legendary.glb")
	issue(caller, "mythic", "Abyss Leviathan", "mythic.glb")
	chain.Emit("Init", "owner", caller.String(), "minted", strconv.Itoa(minted))
}

// Transfer moves one model token. The caller must own it, and the call must send no coins.
func Transfer(cur realm, to address, id int) {
	if !cur.IsCurrent() {
		panic("fishnft: realm")
	}
	if !cur.Previous().IsUserCall() {
		panic("fishnft: eoa")
	}
	if token == nil {
		panic("fishnft: init")
	}
	rejectPay()
	if !to.IsValid() || to == cur.Previous().Address() {
		panic("fishnft: addr")
	}
	row := must(id)
	caller := cur.Previous().Address()
	if row.owner != caller {
		panic("fishnft: owner")
	}
	tid := grc721.TokenID(strconv.Itoa(id))
	if err := ledger.TransferFrom(caller, caller, to, tid); err != nil {
		panic("fishnft: transfer")
	}
	row.owner = to
	chain.Emit("Transfer", "id", strconv.Itoa(id), "to", to.String())
}

func Version() string { return "fishnft-1" }
func Minted() int      { return minted }
func Name() string     { return "Shoal Models" }
func Symbol() string   { return "MODEL" }

func RarityOf(id int) string  { return must(id).rarity }
func SpeciesOf(id int) string { return must(id).species }
func ModelOf(id int) string   { return must(id).file }
func TokenURI(id int) string  { return must(id).uri }

func OwnerOf(tid string) (address, error) {
	id, err := strconv.Atoi(tid)
	if err != nil || token == nil || id < 1 || id >= len(bodies) || bodies[id] == nil {
		return address(""), errors.New("fishnft: unknown")
	}
	return bodies[id].owner, nil
}

func Render(path string) string {
	if path != "" {
		return "# Shoal model NFTs\n\nThat path is not a token page.\n"
	}
	if token == nil {
		return "# Shoal model NFTs\n\nNot issued.\n"
	}
	var b strings.Builder
	b.WriteString("# Shoal model NFTs\n\nSix tokens. No GNOT. This is not shoal/fish.\n\n")
	for _, row := range bodies {
		if row == nil {
			continue
		}
		b.WriteString("- ")
		b.WriteString(strconv.Itoa(row.id))
		b.WriteString(" ")
		b.WriteString(row.species)
		b.WriteString(" ")
		b.WriteString(row.rarity)
		b.WriteString(" ")
		b.WriteString(row.file)
		b.WriteString("\n")
	}
	return b.String()
}

func issue(to address, rarity, species, file string) {
	minted++
	id := minted
	uri := "data:application/json;charset=utf-8," +
		`{"name":"` + species + `","description":"Shoal model ` + file +
		`","attributes":[{"trait_type":"Rarity","value":"` + rarity +
		`"},{"trait_type":"Species","value":"` + species +
		`"},{"trait_type":"Model","value":"` + file + `"}]}`
	row := &body{id: id, rarity: rarity, species: species, file: file, owner: to, uri: uri}
	bodies = append(bodies, row)
	tid := grc721.TokenID(strconv.Itoa(id))
	if err := ledger.Mint(to, tid); err != nil {
		panic("fishnft: mint")
	}
	if err := metaLed.SetTokenURI(tid, uri); err != nil {
		panic("fishnft: uri")
	}
	chain.Emit("Mint", "id", strconv.Itoa(id), "model", file)
}

func must(id int) *body {
	if token == nil || id < 1 || id >= len(bodies) || bodies[id] == nil {
		panic("fishnft: unknown")
	}
	return bodies[id]
}

func rejectPay() {
	if len(unsafe.OriginSend()) != 0 {
		panic("fishnft: payment")
	}
}
