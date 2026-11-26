package kylix

import (
	"strconv"
	"strings"

	"gno.land/p/nt/bptree/v0"
	"gno.land/p/nym-kylix000/ring/v0"
)

// Storage layout.
//
// The chain charges the sender 100 ugnot per byte of realm storage, and a
// persisted struct costs far more than its contents: every object carries
// its own metadata and every field its type. An offer stored as an *Offer
// with two nested ring.Asset values in an avl.Tree took about 4.3 KB, or
// 0.43 GNOT, to post. So each open offer is stored as one string in a B+
// tree, and decoded into an Offer when read; that costs about 0.6-0.8 KB.
//
// The string is 12 fields joined by '|':
//
//	owner|nonce|giveKind|giveKey|giveID|giveAmount|wantKind|wantKey|wantID|wantMin|expiry|viaSession
//
// No field can contain '|': owners are bech32, keys are package paths or
// grc20reg keys, and item ids are validated by PostIntent. encodeOffer
// checks anyway.
var offers bptree.BPTree // offerKey(id) -> encoded offer, open offers only

const sep = "|"

func loadOffer(id uint64) *Offer {
	v := offers.Get(offerKey(id))
	if v == nil {
		return nil
	}
	return decodeOffer(id, v.(string))
}

func storeOffer(o *Offer) { offers.Set(offerKey(o.ID), encodeOffer(o)) }

// eachOfferAfter calls fn for every open offer with id > after, in id
// order, until fn returns true.
func eachOfferAfter(after uint64, fn func(o *Offer) bool) {
	if after == ^uint64(0) {
		return
	}
	start := ""
	if after > 0 {
		start = offerKey(after + 1)
	}
	offers.Iterate(start, "", func(k string, v any) bool { return fn(decodeOffer(parseOfferKey(k), v.(string))) })
}

// eachOfferBefore calls fn for every open offer with id < before (all when
// before is 0), newest first, until fn returns true.
func eachOfferBefore(before uint64, fn func(o *Offer) bool) {
	end := "" // ReverseIterate's end bound is inclusive
	switch {
	case before == 1:
		return
	case before > 1:
		end = offerKey(before - 1)
	}
	offers.ReverseIterate("", end, func(k string, v any) bool { return fn(decodeOffer(parseOfferKey(k), v.(string))) })
}

func encodeOffer(o *Offer) string {
	session := "0"
	if o.ViaSession {
		session = "1"
	}
	fields := []string{
		o.Owner.String(), u64(o.Nonce),
		kindDigit(o.Give.Kind), o.Give.Key, o.Give.ID, i64(o.Give.Amount),
		kindDigit(o.Want.Kind), o.Want.Key, o.Want.ID, i64(o.Want.Amount),
		i64(o.Expiry), session,
	}
	for _, f := range fields {
		if strings.Contains(f, sep) {
			panic("kylix: field contains the separator")
		}
	}
	return strings.Join(fields, sep)
}

// decodeOffer reverses encodeOffer in one pass. Pages decode every offer
// they show, so this is their main cost. In the GnoVM, ranging over a []byte
// costs about a quarter of indexing a string byte by byte, and far less than
// strings.Split followed by strconv parsing, so numbers are read as the scan
// passes them.
func decodeOffer(id uint64, s string) *Offer {
	var str [12]string // text fields
	var num [12]int64  // numeric fields
	field, start := 0, 0
	var n int64
	for i, c := range []byte(s) {
		if c == '|' {
			if field >= 11 {
				panic("kylix: corrupt offer record")
			}
			str[field], num[field] = s[start:i], n
			field, start, n = field+1, i+1, 0
		} else if c >= '0' && c <= '9' {
			n = n*10 + int64(c-'0')
		}
	}
	if field != 11 {
		panic("kylix: corrupt offer record")
	}
	str[11], num[11] = s[start:], n
	// Numeric fields hold digits only (encodeOffer writes them with
	// strconv), so the running value above is exact for them.
	return &Offer{
		ID:         id,
		Owner:      address(str[0]),
		Nonce:      uint64(num[1]),
		Give:       ring.Asset{Kind: ring.Kind(num[2]), Key: str[3], ID: str[4], Amount: num[5]},
		Want:       ring.Asset{Kind: ring.Kind(num[6]), Key: str[7], ID: str[8], Amount: num[9]},
		Expiry:     num[10],
		ViaSession: str[11] == "1",
	}
}

// offerKey writes id in decimal behind a letter giving its length, so keys
// are short and still sort in numeric order: 7 -> "a7", 42 -> "b42".
func offerKey(id uint64) string {
	s := u64(id)
	return string(rune('a'+len(s)-1)) + s
}

func parseOfferKey(k string) uint64 { return mustU64(k[1:]) }

func kindDigit(k ring.Kind) string { return strconv.Itoa(int(k)) }

func mustU64(s string) uint64 {
	n, err := strconv.ParseUint(s, 10, 64)
	if err != nil {
		panic("kylix: corrupt number in store")
	}
	return n
}

func mustI64(s string) int64 {
	n, err := strconv.ParseInt(s, 10, 64)
	if err != nil {
		panic("kylix: corrupt number in store")
	}
	return n
}
