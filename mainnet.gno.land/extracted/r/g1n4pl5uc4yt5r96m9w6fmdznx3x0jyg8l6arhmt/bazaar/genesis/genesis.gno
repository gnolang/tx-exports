package genesis

import (
	"chain"
	"errors"
	"strconv"
	"strings"

	"gno.land/p/nt/avl/v0"
	"gno.land/p/nt/grc721/metadata/v0"
	"gno.land/p/nt/grc721/v0"
	"gno.land/p/nt/seqid/v0"
	"gno.land/r/g1n4pl5uc4yt5r96m9w6fmdznx3x0jyg8l6arhmt/bazaar/bazaarv3"
)

// Holder perk for Bazaar: col.Buy subtracts HolderDiscount(trader) from
// factory.ProtocolBps() (highest FeeDiscount in that wallet). Every Genesis NFT
// also has ShareWeight = FeeDiscount for the 11% protocol-fee pool (claim later).

const (
	maxImageLen    = 200
	maxDiscountBps = int64(150)
	maxSupply      = 1111
	supplyCommon   = 666
	supplyUncommon = 222
	supplyRare     = 111
	supplyEpic     = 66
	supplyLegend   = 33
	supplyMythic   = 13
	defaultImage   = "https://bazaar-gno.vercel.app/gnomies.png"
	shareBps       = int64(1100) // 11% of protocol take on Buy
)

type item struct {
	id          int
	owner       address
	name        string
	image       string
	rarity      string
	discountBps int64
}

var (
	token    *grc721.Token
	ledger   *grc721.PrivateLedger
	metaView *metadata.Metadata
	metaLed  *metadata.Ledger
	tokenSeq seqid.ID
	items    avl.Tree
	inited         bool
	creator        address
	nextID         int
	mintedCommon   int
	mintedUncommon int
	mintedRare     int
	mintedEpic     int
	mintedLegend   int
	mintedMythic   int
)

func Init(cur realm, name, symbol string) {
	if !cur.IsCurrent() {
		panic("genesis: spoofed realm")
	}
	if !cur.Previous().IsUserCall() {
		panic("genesis: EOA only")
	}
	if inited {
		panic("genesis: already initialized")
	}
	tok, led := grc721.NewToken(name, symbol, tokenSeq.Next(), cur)
	token = tok
	ledger = led
	metaView, metaLed = metadata.NewMetadata(led)
	creator = cur.Previous().Address()
	inited = true
	chain.Emit("Init", "creator", creator.String())
	factory.AttachGenesis(cross(cur))
}

func Mint(cur realm, name, image, rarity string, discountBps int64) int {
	caller := requireUser(cur)
	if caller != creator {
		panic("genesis: not creator")
	}
	if name == "" || len(name) > grc721.MaxNameLen {
		panic("genesis: name")
	}
	if image == "" {
		image = defaultImage
	}
	if len(image) > maxImageLen {
		panic("genesis: image")
	}
	d := discountBps
	if d < 0 {
		d = rarityDiscount(rarity)
	}
	if d > maxDiscountBps {
		panic("genesis: discount")
	}
	if nextID >= maxSupply {
		panic("genesis: sold out")
	}
	takeRarity(rarity)
	nextID++
	id := nextID
	tid := grc721.TokenID(strconv.Itoa(id))
	if err := ledger.Mint(caller, tid); err != nil {
		panic("genesis: mint")
	}
	if err := metaLed.SetTokenURI(tid, tokenJSON(name, image, rarity, d)); err != nil {
		panic("genesis: tokenURI")
	}
	if err := metaLed.SetTokenMetadata(tid, metadata.Data{
		Name:        name,
		Description: name,
		Image:       image,
		Attributes: []metadata.Trait{
			{TraitType: "Rarity", Value: rarity},
			{TraitType: "FeeDiscount", Value: strconv.FormatInt(d, 10)},
			{TraitType: "ShareWeight", Value: strconv.FormatInt(d, 10)},
		},
	}); err != nil {
		panic("genesis: metadata")
	}
	items.Set(strconv.Itoa(id), &item{id: id, owner: caller, name: name, image: image, rarity: rarity, discountBps: d})
	syncFactory(cur, caller.String())
	chain.Emit("Mint", "id", strconv.Itoa(id), "discount", strconv.FormatInt(d, 10))
	return id
}

// HolderDiscount is the best FeeDiscount among Genesis NFTs currently in `owner`'s wallet (not listed/escrowed).
func HolderDiscount(owner string) int64 {
	if !inited {
		return 0
	}
	who := address(owner)
	if !who.IsValid() {
		return 0
	}
	var best int64
	items.Iterate("", "", func(_ string, value any) bool {
		it := value.(*item)
		if it.owner == who && it.discountBps > best {
			best = it.discountBps
		}
		return false
	})
	return best
}

// ShareWeight sums FeeDiscount of every Genesis NFT in `owner`'s wallet (not listed/escrowed).
func ShareWeight(owner string) int64 {
	if !inited {
		return 0
	}
	who := address(owner)
	if !who.IsValid() {
		return 0
	}
	var sum int64
	items.Iterate("", "", func(_ string, value any) bool {
		it := value.(*item)
		if it.owner == who {
			sum += it.discountBps
		}
		return false
	})
	return sum
}

func DiscountOf(tid string) int64 {
	return mustItem(parseTid(tid)).discountBps
}

func ShareBps() int64 {
	return shareBps
}

func MaxSupply() int {
	return maxSupply
}

func TotalSupply() int {
	requireInit()
	return nextID
}

func SupplyOf(rarity string) int {
	switch canonRarity(rarity) {
	case "mythic":
		return supplyMythic
	case "legendary":
		return supplyLegend
	case "epic":
		return supplyEpic
	case "rare":
		return supplyRare
	case "uncommon":
		return supplyUncommon
	default:
		return supplyCommon
	}
}

func MintedOf(rarity string) int {
	requireInit()
	switch canonRarity(rarity) {
	case "mythic":
		return mintedMythic
	case "legendary":
		return mintedLegend
	case "epic":
		return mintedEpic
	case "rare":
		return mintedRare
	case "uncommon":
		return mintedUncommon
	default:
		return mintedCommon
	}
}

func Name() string {
	requireInit()
	return token.GetName()
}

func Symbol() string {
	requireInit()
	return token.GetSymbol()
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

func OwnerOf(tid string) (address, error) {
	requireInit()
	id, err := strconv.Atoi(tid)
	if err != nil || id < 1 {
		return address(""), errors.New("genesis: tid")
	}
	v := items.Get(strconv.Itoa(id))
	if v == nil {
		return address(""), errors.New("genesis: unknown item")
	}
	return v.(*item).owner, nil
}

func TokenURI(tid string) string {
	u, err := metaView.TokenURI(grc721.TokenID(tid))
	if err != nil || u == "" {
		it := mustItem(parseTid(tid))
		return tokenJSON(it.name, it.image, it.rarity, it.discountBps)
	}
	return u
}

func TokensOf(owner string) string {
	requireInit()
	who := address(owner)
	if !who.IsValid() {
		return ""
	}
	out := ""
	items.Iterate("", "", func(_ string, value any) bool {
		it := value.(*item)
		if it.owner != who {
			return false
		}
		if out != "" {
			out += ","
		}
		out += strconv.Itoa(it.id)
		return false
	})
	return out
}

func TransferFrom(cur realm, from, to, tid string) {
	caller := requireUser(cur)
	id := parseTid(tid)
	src := address(from)
	dst := address(to)
	if !src.IsValid() || !dst.IsValid() {
		panic("genesis: addr")
	}
	if err := ledger.TransferFrom(caller, src, dst, grc721.TokenID(tid)); err != nil {
		panic("genesis: transfer")
	}
	it := mustItem(id)
	it.owner = dst
	items.Set(strconv.Itoa(id), it)
	syncFactory(cur, from, to)
}

func Attach(cur realm) {
	caller := requireUser(cur)
	if caller != creator {
		panic("genesis: not creator")
	}
	factory.AttachGenesis(cross(cur))
}

func syncFactory(cur realm, owners ...string) {
	for _, o := range owners {
		if strings.TrimSpace(o) == "" {
			continue
		}
		factory.NoteHolderDiscount(cross(cur), o, HolderDiscount(o))
	}
}

func canonRarity(rarity string) string {
	switch strings.ToLower(strings.TrimSpace(rarity)) {
	case "mythic":
		return "mythic"
	case "legendary":
		return "legendary"
	case "epic":
		return "epic"
	case "rare":
		return "rare"
	case "uncommon":
		return "uncommon"
	default:
		return "common"
	}
}

func takeRarity(rarity string) {
	switch canonRarity(rarity) {
	case "mythic":
		if mintedMythic >= supplyMythic {
			panic("genesis: rarity full")
		}
		mintedMythic++
	case "legendary":
		if mintedLegend >= supplyLegend {
			panic("genesis: rarity full")
		}
		mintedLegend++
	case "epic":
		if mintedEpic >= supplyEpic {
			panic("genesis: rarity full")
		}
		mintedEpic++
	case "rare":
		if mintedRare >= supplyRare {
			panic("genesis: rarity full")
		}
		mintedRare++
	case "uncommon":
		if mintedUncommon >= supplyUncommon {
			panic("genesis: rarity full")
		}
		mintedUncommon++
	default:
		if mintedCommon >= supplyCommon {
			panic("genesis: rarity full")
		}
		mintedCommon++
	}
}

func rarityDiscount(rarity string) int64 {
	switch canonRarity(rarity) {
	case "mythic":
		return 150
	case "legendary":
		return 125
	case "epic":
		return 100
	case "rare":
		return 75
	case "uncommon":
		return 50
	default:
		return 25
	}
}

func requireInit() {
	if !inited {
		panic("genesis: call Init first")
	}
}

func requireUser(cur realm) address {
	requireInit()
	if !cur.IsCurrent() {
		panic("genesis: spoofed realm")
	}
	if !cur.Previous().IsUserCall() {
		panic("genesis: EOA only")
	}
	return cur.Previous().Address()
}

func parseTid(tid string) int {
	id, err := strconv.Atoi(tid)
	if err != nil || id < 1 {
		panic("genesis: tid")
	}
	return id
}

func mustItem(id int) *item {
	v := items.Get(strconv.Itoa(id))
	if v == nil {
		panic("genesis: unknown item")
	}
	return v.(*item)
}

func tokenJSON(name, image, rarity string, discount int64) string {
	body := `{"name":` + jsonStr(name) + `,"image":` + jsonStr(image) + `,"attributes":[{"trait_type":"Rarity","value":` + jsonStr(rarity) + `},{"trait_type":"FeeDiscount","value":` + jsonStr(strconv.FormatInt(discount, 10)) + `},{"trait_type":"ShareWeight","value":` + jsonStr(strconv.FormatInt(discount, 10)) + `}]}`
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
