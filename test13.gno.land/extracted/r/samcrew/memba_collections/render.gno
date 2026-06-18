package memba_collections

import (
	"strings"

	"gno.land/p/nt/ufmt/v0"
)

const renderPageSize = 50

// CollectionView is a structured read of a collection's public fields.
type CollectionView struct {
	ID           string
	Creator      address
	Admin        address
	Name         string
	Symbol       string
	RoyaltyBPS   int64
	RoyaltyRecip address
	Phase        int
	MintPrice    int64
	PayDenom     string
	MaxSupply    int64
	MaxPerWallet int64
	Minted       int64
	Paused       bool
}

// CollectionInfo returns a structured view of a collection.
func CollectionInfo(id string) CollectionView {
	c := mustGet(id)
	return CollectionView{
		ID:           id,
		Creator:      c.creator,
		Admin:        c.admin,
		Name:         c.nft.Name(),
		Symbol:       c.nft.Symbol(),
		RoyaltyBPS:   c.royaltyBPS,
		RoyaltyRecip: c.royaltyRecip,
		Phase:        c.phase,
		MintPrice:    c.mintPrice,
		PayDenom:     denomKey(c.payDenom),
		MaxSupply:    c.maxSupply,
		MaxPerWallet: c.maxPerWallet,
		Minted:       c.nextAutoTokenID,
		Paused:       c.paused,
	}
}

// MintedBy returns how many tokens an address has minted in a collection.
func MintedBy(id string, who address) int64 {
	return walletCount(mustGet(id), who)
}

// Render mux:
//   ""                 → paginated collection list (?page=N)
//   "collection/<id>"  → collection detail
func Render(path string) string {
	if path == "" || strings.HasPrefix(path, "?") {
		return renderList(parsePage(path))
	}
	if strings.HasPrefix(path, "collection/") {
		return renderCollection(strings.TrimPrefix(path, "collection/"))
	}
	return "# Not found\n\nUnknown path: " + path
}

func parsePage(path string) int {
	idx := strings.Index(path, "page=")
	if idx < 0 {
		return 1
	}
	rest := path[idx+5:]
	if amp := strings.IndexByte(rest, '&'); amp >= 0 {
		rest = rest[:amp]
	}
	n := 0
	for i := 0; i < len(rest); i++ {
		c := rest[i]
		if c < '0' || c > '9' {
			break
		}
		n = n*10 + int(c-'0')
	}
	if n < 1 {
		return 1
	}
	return n
}

func renderList(page int) string {
	var b strings.Builder
	b.WriteString("# Memba Collections\n\n")
	if paused {
		b.WriteString("> ⚠️ Registry is globally paused.\n\n")
	}
	total := collections.Size()
	if total == 0 {
		b.WriteString("_No collections yet._\n")
		return b.String()
	}
	start := (page - 1) * renderPageSize
	end := start + renderPageSize
	i := 0
	shown := 0
	collections.Iterate("", "", func(key string, v any) bool {
		if i >= start && i < end {
			c := v.(*collection)
			b.WriteString(ufmt.Sprintf("- **%s** (%s) — phase %d, minted %d\n",
				c.nft.Name(), key, c.phase, c.nextAutoTokenID))
			shown++
		}
		i++
		return i >= end
	})
	b.WriteString(ufmt.Sprintf("\n_Page %d — %d of %d collections._\n", page, shown, total))
	return b.String()
}

func renderCollection(id string) string {
	v, ok := collections.Get(id)
	if !ok {
		return "# Not found\n\nNo collection: " + id
	}
	c := v.(*collection)
	var b strings.Builder
	b.WriteString(ufmt.Sprintf("# %s (%s)\n\n", c.nft.Name(), c.nft.Symbol()))
	b.WriteString(ufmt.Sprintf("- ID: `%s`\n", id))
	b.WriteString(ufmt.Sprintf("- Creator: %s\n", c.creator.String()))
	b.WriteString(ufmt.Sprintf("- Admin: %s\n", c.admin.String()))
	b.WriteString(ufmt.Sprintf("- Royalty: %d bps → %s\n", c.royaltyBPS, c.royaltyRecip.String()))
	b.WriteString(ufmt.Sprintf("- Phase: %d\n", c.phase))
	b.WriteString(ufmt.Sprintf("- Mint price: %d %s\n", c.mintPrice, denomKey(c.payDenom)))
	b.WriteString(ufmt.Sprintf("- Supply: %d", c.nextAutoTokenID))
	if c.maxSupply > 0 {
		b.WriteString(ufmt.Sprintf(" / %d", c.maxSupply))
	}
	b.WriteString("\n")
	if c.paused {
		b.WriteString("- ⚠️ Paused\n")
	}
	return b.String()
}
