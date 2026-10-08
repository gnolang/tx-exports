// Package drops creates Launchpad NFT collections and runs their primary
// mints. It charges the collection fee and each mint price, and pays the
// treasury and the creator inside the same transaction: it holds no funds
// between calls and has no admin.
package drops

import (
	"chain"
	"strconv"
	"time"

	"gno.land/p/nt/avl/v0"
	"gno.land/p/samcrew/launchpad/currency/v1"
	"gno.land/p/samcrew/launchpad/merkle/v1"
	"gno.land/p/samcrew/launchpad/meta/v1"
	sm "gno.land/p/samcrew/launchpad/safemath/v1"
	"gno.land/r/samcrew/launchpad/config/v1"
	"gno.land/r/samcrew/launchpad/nft/v1"
)

const (
	KindFixed     = "fixed"     // one price, open to every wallet
	KindAllowlist = "allowlist" // only addresses under a Merkle root, each with its own allowance
	KindHolder    = "holder"    // one mint per token held in another collection
	KindDutch     = "dutch"     // the price falls in a straight line until the stage ends

	// Hard limits, fixed for the life of this realm.
	maxPrimaryFeeBPS = 500 // 5% of a mint price
	maxStages        = 10
	maxStageSeconds  = 365 * 24 * 60 * 60
	maxPerWallet     = 1_000_000
)

// stage is one mint window of a collection, open during [Start, End).
type stage struct {
	Kind      string
	Start     int64
	End       int64
	Price     int64 // per token; for a dutch stage, the price at Start
	Floor     int64 // dutch only: the price reached at End
	Currency  string
	FeeBPS    int64  // protocol fee on each mint, pinned when the creator signed
	SupplyCap int64  // 0 means no cap beyond the collection's
	PerWallet int64  // most one wallet may mint; an allowlist sets it per address
	Root      string // allowlist only
	Gate      string // holder only: the collection whose tokens each allow one mint
	// Holder only: the gate collection's tokens numbered up to it, all minted
	// when the stage was placed, open a mint; later ones do not, so no loop of
	// collections gated on each other mints its own gate tokens.
	GateLimit int64
	Minted    int64
}

var (
	stages avl.Tree // collection ID -> []stage, at most maxStages
	minted avl.Tree // "<collection>/<stage>/<address>" -> int64
	gated  avl.Tree // "<collection>/<stage>/<gate token number>" -> true
)

func directCaller(cur realm) address {
	if !cur.IsCurrent() || !cur.Previous().IsUserCall() {
		panic("launchpad/drops: direct user call required")
	}
	return cur.Previous().Address()
}

// CreateCollection registers the caller's collection in the NFT ledger and
// pays the collection fee to the treasury. maxFee is the highest fee the
// caller accepts: a fee above it aborts before anything is taken, whatever
// the caller's allowance. Native coins are attached for exactly the fee; a
// token is pulled for exactly the fee. The collection terms are documented
// on nft.Create.
func CreateCollection(cur realm, name, symbol, description, image, banner,
	website, mode string, revocable bool, maxSupply int64, metadataMode,
	baseURI, placeholderURI, commitment, provenance, royalties,
	currencyKey string, maxFee int64) string {
	creator := directCaller(cur)
	p := policy(config.LaneCollection, currencyKey)
	if p.collectionFee > maxFee {
		panic("launchpad/drops: collection fee above the accepted maximum")
	}
	held := take(cur, currencyKey, p.collectionFee, p.collectionFee)
	id := nft.Create(cross(cur), creator, name, symbol, description, image,
		banner, website, mode, revocable, maxSupply, metadataMode, baseURI,
		placeholderURI, commitment, provenance, royalties)
	pay(cur, currencyKey, p.treasury, p.collectionFee)
	settled(cur, currencyKey, held)
	chain.Emit("CollectionFeePaid", "collection", id, "creator", creator.String(),
		"currency", currencyKey, "fee", strconv.FormatInt(p.collectionFee, 10),
		"treasury", p.treasury.String())
	return id
}

func stagesOf(id string) []stage {
	if list := stages.Get(id); list != nil {
		return list.([]stage)
	}
	return nil
}

// requireCreator aborts unless the caller is the collection's creator. The
// creator may be a realm, a DAO for instance: what it signs here moves no
// funds. Coins attached to a user's call would stay in this realm, so they
// are refused; coins a realm's transaction carries belong to that realm.
func requireCreator(cur realm, id string) {
	if !cur.IsCurrent() || cur.Previous().Address() != nft.GetInfo(id).Creator {
		panic("launchpad/drops: creator only")
	}
	if cur.Previous().IsUserCall() {
		currency.AssertNoCoins(0, cur)
	}
}

// emitStage publishes every term of a stage, so a reader of events alone
// knows what each stage sells.
func emitStage(id string, index int, s stage) {
	chain.Emit("StageSet", "collection", id, "stage", strconv.Itoa(index),
		"kind", s.Kind, "start", strconv.FormatInt(s.Start, 10),
		"end", strconv.FormatInt(s.End, 10), "currency", s.Currency,
		"price", strconv.FormatInt(s.Price, 10),
		"floor", strconv.FormatInt(s.Floor, 10),
		"fee_bps", strconv.FormatInt(s.FeeBPS, 10),
		"supply_cap", strconv.FormatInt(s.SupplyCap, 10),
		"per_wallet", strconv.FormatInt(s.PerWallet, 10),
		"root", s.Root, "gate", s.Gate, "gate_limit", strconv.FormatInt(s.GateLimit, 10))
}

func validRoot(s string) bool {
	h, err := merkle.ParseHash(s)
	return err == nil && merkle.FormatHash(h) == s
}

// newStage validates a stage of collection id that has not started. Fields a
// kind does not use must be zero, so a stage reads the same to everyone. A
// holder stage is gated on another collection, and only on the tokens that
// collection had minted when the stage was placed: gated on its own, or on a
// collection gated on it in turn, every token minted would open one more mint.
func newStage(id, kind string, start, end, price, floor, supplyCap, perWallet int64,
	root, gate, currencyKey string) stage {
	ok := start >= time.Now().Unix() && end > start && end-start <= maxStageSeconds &&
		price >= 0 && supplyCap >= 0 && perWallet >= 0 && perWallet <= maxPerWallet
	var gateLimit int64
	switch kind {
	case KindFixed:
		ok = ok && perWallet > 0 && floor == 0 && root == "" && gate == ""
	case KindAllowlist:
		ok = ok && perWallet == 0 && floor == 0 && validRoot(root) && gate == ""
	case KindHolder:
		ok = ok && perWallet > 0 && floor == 0 && root == "" && gate != "" && gate != id
		if ok {
			gateLimit = nft.GetInfo(gate).Minted // an unknown gate collection aborts
		}
	case KindDutch:
		ok = ok && perWallet > 0 && floor >= 0 && floor < price && root == "" && gate == ""
	default:
		ok = false
	}
	if !ok {
		panic("launchpad/drops: invalid stage")
	}
	return stage{Kind: kind, Start: start, End: end, Price: price, Floor: floor,
		Currency: currencyKey, SupplyCap: supplyCap, PerWallet: perWallet,
		Root: root, Gate: gate, GateLimit: gateLimit}
}

// place writes s at index (len(list) appends) after checking that the caller
// is the collection's creator, the mint lane accepts the currency, the
// protocol fee is within what the creator accepts and no other stage
// overlaps. The fee is pinned on the stage: a later change does not reach it.
func place(cur realm, id string, index int, s stage, maxFeeBPS int64) {
	requireCreator(cur, id)
	s.FeeBPS = policy(config.LaneNFTDrops, s.Currency).primaryFeeBPS
	if s.FeeBPS > maxFeeBPS || s.FeeBPS > maxPrimaryFeeBPS {
		panic("launchpad/drops: protocol fee above the accepted maximum")
	}
	list := stagesOf(id)
	for i, other := range list {
		if i != index && s.Start < other.End && other.Start < s.End {
			panic("launchpad/drops: stages overlap")
		}
	}
	if index == len(list) {
		list = append(list, s)
	} else {
		list[index] = s
	}
	stages.Set(id, list)
	emitStage(id, index, s)
}

// AddStage schedules a mint window and returns its index. The arguments are
// the terms of the stage, then the highest protocol fee the creator accepts.
// A collection has ten stages for its whole life: a stage that ended keeps
// its slot.
func AddStage(cur realm, id, kind string, start, end, price, floor, supplyCap,
	perWallet int64, root, gate, currencyKey string, maxFeeBPS int64) int {
	index := len(stagesOf(id))
	if index >= maxStages {
		panic("launchpad/drops: too many stages")
	}
	place(cur, id, index, newStage(id, kind, start, end, price, floor, supplyCap,
		perWallet, root, gate, currencyKey), maxFeeBPS)
	return index
}

// EditStage replaces a stage that has not started. Once a stage has opened
// its terms are final, whatever the replacement would have been: it can only
// be ended.
func EditStage(cur realm, id string, index int, kind string, start, end, price,
	floor, supplyCap, perWallet int64, root, gate, currencyKey string,
	maxFeeBPS int64) {
	list := stagesOf(id)
	if index < 0 || index >= len(list) {
		panic("launchpad/drops: unknown stage")
	}
	if time.Now().Unix() >= list[index].Start {
		panic("launchpad/drops: stage already started")
	}
	place(cur, id, index, newStage(id, kind, start, end, price, floor, supplyCap,
		perWallet, root, gate, currencyKey), maxFeeBPS)
}

// EndStage closes an open stage at once and for good. It asks no lane: a
// creator stops its own sale whatever is paused.
func EndStage(cur realm, id string, index int) {
	requireCreator(cur, id)
	list := stagesOf(id)
	if index < 0 || index >= len(list) {
		panic("launchpad/drops: unknown stage")
	}
	s := &list[index]
	now := time.Now().Unix()
	if now < s.Start || now >= s.End {
		panic("launchpad/drops: stage closed")
	}
	s.End = now
	stages.Set(id, list)
	emitStage(id, index, *s)
}

// priceAt is the stage price at a time inside its window.
func priceAt(s stage, now int64) int64 {
	if s.Kind != KindDutch {
		return s.Price
	}
	return s.Price - sm.MulDiv(s.Price-s.Floor, now-s.Start, s.End-s.Start)
}

func stageKey(id string, index int) string { return id + "/" + strconv.Itoa(index) + "/" }

// AllowlistLeaf is the Merkle leaf that lets who mint up to allowance tokens
// in one stage: sha256(0x00 || "launchpad-drop-v1|<collection>|<stage>|<address>|<allowance>").
// Only the chain's spelling of an address makes a leaf: a list written in
// capitals would name accounts that can never claim.
func AllowlistLeaf(id string, index int, who address, allowance int64) merkle.Hash {
	if !meta.ValidAddress(who) {
		panic("launchpad/drops: invalid account")
	}
	return merkle.Leaf([]byte("launchpad-drop-v1|" + id + "|" + strconv.Itoa(index) +
		"|" + who.String() + "|" + strconv.FormatInt(allowance, 10)))
}

// entitled checks what the stage's kind requires of the buyer and returns how
// many tokens that wallet may mint in the stage. For a holder stage it also
// returns the key under which the gate token must be recorded as used.
func entitled(s stage, id string, index int, buyer address, allowance int64,
	proof string, gateNumber int64) (limit int64, gateKey string) {
	switch s.Kind {
	case KindAllowlist:
		root, _ := merkle.ParseHash(s.Root)
		path, err := merkle.ParseProof(proof)
		if err != nil || gateNumber != 0 || allowance > maxPerWallet ||
			!merkle.Verify(root, AllowlistLeaf(id, index, buyer, allowance), path) {
			panic("launchpad/drops: not on the allowlist")
		}
		return allowance, ""
	case KindHolder:
		gateKey = stageKey(id, index) + strconv.FormatInt(gateNumber, 10)
		if allowance != 0 || proof != "" || gated.Has(gateKey) ||
			nft.OwnerOf(s.Gate, gateNumber) != buyer {
			panic("launchpad/drops: gate token missing or already used")
		}
		if gateNumber > s.GateLimit {
			panic("launchpad/drops: gate token minted after the stage was scheduled")
		}
	default:
		if allowance != 0 || proof != "" || gateNumber != 0 {
			panic("launchpad/drops: this stage takes no allowance, proof or gate token")
		}
	}
	return s.PerWallet, gateKey
}

// Mint sells the caller one token of an open stage and returns its number.
// currencyKey and offered are what the caller accepts to pay: the stage must
// be priced in that currency, and offered is the most it will take. Native
// coins are attached for exactly offered and the difference with the price
// comes back, which is what makes a falling price payable; a token is pulled
// for exactly the price. The price is split between the treasury (the fee
// pinned on the stage) and the creator. allowance and proof are for an
// allowlist stage, gateNumber for a holder stage; elsewhere they are zero and
// empty.
func Mint(cur realm, id string, index int, currencyKey string, offered,
	allowance int64, proof string, gateNumber int64) int64 {
	buyer := directCaller(cur)
	list := stagesOf(id)
	if index < 0 || index >= len(list) {
		panic("launchpad/drops: unknown stage")
	}
	s := &list[index]
	if s.Currency != currencyKey {
		panic("launchpad/drops: stage priced in another currency")
	}
	now := time.Now().Unix()
	if now < s.Start || now >= s.End || (s.SupplyCap > 0 && s.Minted >= s.SupplyCap) {
		panic("launchpad/drops: stage closed")
	}
	p := policy(config.LaneNFTDrops, s.Currency)
	wallet := stageKey(id, index) + buyer.String()
	var count int64
	if v := minted.Get(wallet); v != nil {
		count = v.(int64)
	}
	limit, gateKey := entitled(*s, id, index, buyer, allowance, proof, gateNumber)
	if count >= limit {
		panic("launchpad/drops: wallet limit reached")
	}
	price := priceAt(*s, now)
	held := take(cur, s.Currency, price, offered)
	number := nft.MintTo(cross(cur), id, buyer)
	creator := nft.GetInfo(id).Creator
	fee := sm.BPS(price, s.FeeBPS)
	pay(cur, s.Currency, p.treasury, fee)
	pay(cur, s.Currency, creator, price-fee)
	settled(cur, s.Currency, held)
	s.Minted++
	stages.Set(id, list)
	minted.Set(wallet, count+1)
	if gateKey != "" {
		gated.Set(gateKey, true)
	}
	chain.Emit("Minted", "collection", id, "number", strconv.FormatInt(number, 10),
		"stage", strconv.Itoa(index), "buyer", buyer.String(),
		"currency", s.Currency, "price", strconv.FormatInt(price, 10),
		"fee", strconv.FormatInt(fee, 10), "treasury", p.treasury.String(),
		"creator", creator.String())
	return number
}

func Render(path string) string {
	return "# Launchpad NFT drops\n\n" + strconv.Itoa(stages.Size()) +
		" collections have mint stages.\n"
}
