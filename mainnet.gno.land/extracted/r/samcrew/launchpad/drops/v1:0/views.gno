package drops

import (
	"strconv"
	"strings"
	"time"

	"gno.land/p/samcrew/launchpad/meta/v1"
	"gno.land/r/samcrew/launchpad/nft/v1"
)

func num(n int64) string { return meta.JSONString(strconv.FormatInt(n, 10)) }

// StagesJSON lists a collection's stages in index order. "currentPrice" is
// the price a mint would pay now, and is only meaningful while "open" is true.
func StagesJSON(id string) string {
	nft.GetInfo(id) // an unknown collection aborts
	now := time.Now().Unix()
	var b strings.Builder
	b.WriteByte('[')
	for i, s := range stagesOf(id) {
		if i > 0 {
			b.WriteByte(',')
		}
		open := now >= s.Start && now < s.End
		current := s.Price
		if open {
			current = priceAt(s, now)
		}
		b.WriteString("{" +
			`"index":` + strconv.Itoa(i) +
			`,"kind":` + meta.JSONString(s.Kind) +
			`,"start":` + num(s.Start) +
			`,"end":` + num(s.End) +
			`,"open":` + strconv.FormatBool(open) +
			`,"price":` + num(s.Price) +
			`,"floor":` + num(s.Floor) +
			`,"currentPrice":` + num(current) +
			`,"currency":` + meta.JSONString(s.Currency) +
			`,"feeBPS":` + num(s.FeeBPS) +
			`,"supplyCap":` + num(s.SupplyCap) +
			`,"perWallet":` + num(s.PerWallet) +
			`,"root":` + meta.JSONString(s.Root) +
			`,"gate":` + meta.JSONString(s.Gate) +
			`,"gateLimit":` + num(s.GateLimit) +
			`,"minted":` + num(s.Minted) + "}")
	}
	b.WriteByte(']')
	return b.String()
}

// MintedBy is how many tokens who has minted in a stage. Only the chain's
// spelling of an address is an account: any other is refused, never read as 0.
func MintedBy(id string, index int, who string) int64 {
	if !meta.ValidAddress(address(who)) {
		panic("launchpad/drops: invalid account")
	}
	if v := minted.Get(stageKey(id, index) + who); v != nil {
		return v.(int64)
	}
	return 0
}

// GateUsed reports whether a gate token has already paid for a mint in a
// holder stage.
func GateUsed(id string, index int, gateNumber int64) bool {
	return gated.Has(stageKey(id, index) + strconv.FormatInt(gateNumber, 10))
}

// TermsJSON is what creating a collection and scheduling a stage cost now:
// the collection fee in a currency and the protocol fee a new stage would
// pin. A value of -1 means the lane is closed; config's ActionStatusJSON tells
// whether a lane accepts new actions right now.
func TermsJSON(currencyKey string) string {
	t := termsOf(currencyKey)
	return "{" +
		`"currency":` + meta.JSONString(currencyKey) +
		`,"collectionFee":` + num(t.collectionFee) +
		`,"primaryFeeBPS":` + num(t.primaryFeeBPS) +
		`,"maxPrimaryFeeBPS":` + num(maxPrimaryFeeBPS) +
		`,"treasury":` + meta.JSONString(t.treasury.String()) + "}"
}
