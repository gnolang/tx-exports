// Package mint is the platform's first minter (design §2.5.3): sale
// phases, fixed price or Dutch auction, live and merkle allowlists, lifetime
// wallet caps, and payment settlement. It is replaceable: core binds each
// collection to the minter that created it, so a future mint/v2 serves new
// collections without touching sales in progress.
//
// Creator flow (one multi-message transaction from the frontend; safety does
// not depend on atomicity because nobody can mint a Draft):
//
//	Create -> AddPhase x1..3 -> Launch
//
// Collector flow: Mint, with Price / Phases / Eligible as the read side.
package mint

import (
	"chain"
	"chain/runtime"
	"strconv"

	"gno.land/p/nt/avl/v0"
	"gno.land/p/nt/ufmt/v0"

	"gno.land/p/g19dzk54hhsdc3gllpksuj6gu4a3e6fl8cr6rn4w/minhwa/safe/v1"
	"gno.land/p/g19dzk54hhsdc3gllpksuj6gu4a3e6fl8cr6rn4w/minhwa/types/v1"
	"gno.land/r/g19dzk54hhsdc3gllpksuj6gu4a3e6fl8cr6rn4w/minhwa/core"
)

const MaxPhases = 3

// sale is this minter's per-collection state. Phases can change only while
// core says Draft; after Launch they are frozen with the rest (I-6).
type sale struct {
	phases []types.Phase
}

var sales avl.Tree // cid -> *sale

// Create opens a Draft collection for the calling wallet and pays the
// protocol's create fee from the attached ugnot (excess refunded).
// Empty payee strings default to "creator:10000". expectedCID, when set,
// makes the transaction fail instead of creating a different id than the
// frontend showed (OA B2).
func Create(cur realm, name, symbol, description, engineID, params string,
	maxSupply, royaltyBps int64, primaryPayees, royaltyPayees, expectedCID string,
) string {
	paid := received(cur)
	creator := cur.Previous().Address()
	fee := core.FeeConfig()
	if paid < fee.CreateFee {
		panic("create fee is " + itoa(fee.CreateFee) + "ugnot, sent " + itoa(paid))
	}
	self := creator.String() + ":10000"
	if primaryPayees == "" {
		primaryPayees = self
	}
	if royaltyPayees == "" {
		royaltyPayees = self
	}

	cid := core.CreateCollection(cross(cur), creator, types.CollectionSpec{
		Name: name, Symbol: symbol, Description: description,
		EngineID: engineID, Params: params,
		MaxSupply: maxSupply, RoyaltyBps: royaltyBps,
		PrimaryPayees: primaryPayees, RoyaltyPayees: royaltyPayees,
	})
	if expectedCID != "" && cid != expectedCID {
		panic("collection id would be " + cid + ", expected " + expectedCID + "; retry")
	}
	sales.Set(cid, &sale{})

	pay(cur, fee.Treasury, fee.CreateFee)
	pay(cur, creator, paid-fee.CreateFee)
	return cid
}

// AddPhase appends a sale phase. Phases are ordered and do not overlap.
// kind is "allow" (set required) or "public" (set empty); a fixed price has
// startPrice == floorPrice and zero steps; walletCap 0 means no cap.
func AddPhase(cur realm, cid, kind, set string,
	startHeight, endHeight, startPrice, floorPrice, stepBlocks, stepAmount, walletCap int64,
) {
	assertNoDeposit(cur)
	s := mustDraftSale(cur, cid)
	if len(s.phases) >= MaxPhases {
		panic("at most " + itoa(MaxPhases) + " phases")
	}
	p := types.Phase{
		Kind: kind, Set: set,
		StartHeight: startHeight, EndHeight: endHeight,
		StartPrice: startPrice, FloorPrice: floorPrice,
		StepBlocks: stepBlocks, StepAmount: stepAmount,
		WalletCap: walletCap,
	}
	if err := p.Validate(); err != nil {
		panic(err)
	}
	if set != "" {
		parseSet(set)
	}
	if n := len(s.phases); n > 0 && p.StartHeight <= s.phases[n-1].EndHeight {
		panic("phases must not overlap: start after height " + itoa(s.phases[n-1].EndHeight))
	}
	s.phases = append(s.phases, p)
	chain.Emit("PhaseAdded", "cid", cid, "index", itoa(int64(len(s.phases)-1)), "kind", kind, "set", set)
}

// ClearPhases removes every phase of a Draft.
func ClearPhases(cur realm, cid string) {
	assertNoDeposit(cur)
	s := mustDraftSale(cur, cid)
	s.phases = nil
	chain.Emit("PhasesCleared", "cid", cid)
}

// Launch freezes the sale. creatorCommit is safe.Commit(chainID, cid,
// "creator", secret), computed off-chain — never send the secret to a node
// before reveal.
func Launch(cur realm, cid, creatorCommit string, revealWindow int64, useBeacon bool) {
	assertNoDeposit(cur)
	s := mustDraftSale(cur, cid)
	if len(s.phases) == 0 {
		panic("add at least one phase before launching")
	}
	core.Launch(cross(cur), cid, types.LaunchSpec{
		StartHeight:   s.phases[0].StartHeight,
		EndHeight:     s.phases[len(s.phases)-1].EndHeight,
		RevealWindow:  revealWindow,
		CreatorCommit: creatorCommit,
		UseBeacon:     useBeacon,
	})
}

// Abort returns a launched collection with no mints to Draft (core rules).
func Abort(cur realm, cid string) {
	assertNoDeposit(cur)
	assertCreator(cur, cid)
	core.AbortLaunch(cross(cur), cid)
}

// Reserve mints the creator's reserve to the creator before the sale.
func Reserve(cur realm, cid string, count int64) string {
	assertNoDeposit(cur)
	creator := assertCreator(cur, cid)
	first, last := core.ReserveTo(cross(cur), cid, creator, count)
	return itoa(first) + "-" + itoa(last)
}

// Mint buys count tokens in the phase open at this block, at that block's
// unit price, never above maxUnitPrice (a Dutch step cannot surprise the
// buyer). proof is the merkle proof for merkle sets, otherwise "". Returns
// "first-last". Every attached unit is paid out or refunded (I-3, I-4).
func Mint(cur realm, cid string, count, maxUnitPrice int64, proof string) string {
	paid := received(cur)
	buyer := cur.Previous().Address()
	h := runtime.ChainHeight()
	p, ok := mustSale(cid).phaseAt(h)
	if !ok {
		panic("no sale phase is open at height " + itoa(h))
	}
	if count <= 0 || count > core.MaxMintPerTx {
		panic("count must be 1.." + itoa(core.MaxMintPerTx))
	}
	if ok, reason := eligible(cid, p.Set, buyer, proof); !ok {
		panic(reason)
	}
	if p.WalletCap > 0 && core.MintedBy(cid, buyer)+count > p.WalletCap {
		panic("wallet cap: " + itoa(p.WalletCap) + " per wallet, already minted " + itoa(core.MintedBy(cid, buyer)))
	}
	price := p.PriceAt(h)
	if price > maxUnitPrice {
		panic("unit price at this block is " + itoa(price) + "ugnot, above maxUnitPrice " + itoa(maxUnitPrice))
	}
	cost := price * count
	if paid < cost {
		panic("send " + itoa(cost) + "ugnot, sent " + itoa(paid))
	}

	first, last := core.MintTo(cross(cur), cid, buyer, count)

	fee := core.FeeConfig()
	protocol := safe.BpsOf(cost, fee.PrimaryBps)
	payees := core.PrimaryPayees(cid)
	shares := safe.SplitByBps(cost-protocol, payees)
	pay(cur, fee.Treasury, protocol)
	for i, payee := range payees {
		pay(cur, payee.Addr, shares[i])
	}
	pay(cur, buyer, paid-cost)

	chain.Emit("Sale", "cid", cid, "buyer", buyer.String(), "first", itoa(first), "last", itoa(last),
		"unitPrice", itoa(price), "protocolFee", itoa(protocol))
	return itoa(first) + "-" + itoa(last)
}

func (s *sale) phaseAt(h int64) (types.Phase, bool) {
	for _, p := range s.phases {
		if p.Covers(h) {
			return p, true
		}
	}
	return types.Phase{}, false
}

func mustSale(cid string) *sale {
	v := sales.Get(cid)
	if v == nil {
		panic("collection " + cid + " was not created by this minter")
	}
	return v.(*sale)
}

func mustDraftSale(cur realm, cid string) *sale {
	assertCreator(cur, cid)
	if core.Info(cid).State != types.StateDraft {
		panic("phases are frozen after launch")
	}
	return mustSale(cid)
}

func assertCreator(cur realm, cid string) address {
	who := cur.Previous().Address()
	if core.Info(cid).Creator != who {
		panic("only the collection's creator can do this")
	}
	return who
}

// --- reads -------------------------------------------------------------------

// Price is the unit price at height h, or -1 when no phase covers h.
func Price(cid string, h int64) int64 {
	p, ok := mustSale(cid).phaseAt(h)
	if !ok {
		return -1
	}
	return p.PriceAt(h)
}

// Phases is the phase list as JSON.
func Phases(cid string) string {
	w := &safe.JSONWriter{}
	w.BeginArray()
	for _, p := range mustSale(cid).phases {
		w.BeginObject()
		w.StrField("kind", p.Kind)
		w.StrField("set", p.Set)
		w.IntField("startHeight", p.StartHeight)
		w.IntField("endHeight", p.EndHeight)
		w.IntField("startPrice", p.StartPrice)
		w.IntField("floorPrice", p.FloorPrice)
		w.IntField("stepBlocks", p.StepBlocks)
		w.IntField("stepAmount", p.StepAmount)
		w.IntField("walletCap", p.WalletCap)
		w.EndObject()
	}
	w.EndArray()
	return w.String()
}

// Eligible answers "can addr mint now, and how many?" with the same checks
// Mint runs, so the UI never disagrees with the chain (OA B3). JSON:
// {phase, kind, eligible, reason, remainingCap (-1 = no cap), price}.
func Eligible(cid string, addr address, proof string) string {
	h := runtime.ChainHeight()
	w := &safe.JSONWriter{}
	w.BeginObject()
	idx, p := -1, types.Phase{}
	for i, q := range mustSale(cid).phases {
		if q.Covers(h) {
			idx, p = i, q
			break
		}
	}
	w.IntField("phase", int64(idx))
	if idx < 0 {
		w.BoolField("eligible", false)
		w.StrField("reason", "no sale phase is open at height "+itoa(h))
		w.EndObject()
		return w.String()
	}
	ok, reason := eligible(cid, p.Set, addr, proof)
	remaining := int64(-1)
	if p.WalletCap > 0 {
		remaining = p.WalletCap - core.MintedBy(cid, addr)
		if remaining < 0 {
			remaining = 0
		}
		if remaining == 0 && ok {
			ok, reason = false, "wallet cap reached"
		}
	}
	if ok && core.Info(cid).State != types.StateMinting {
		ok, reason = false, "collection is not minting"
	}
	w.StrField("kind", p.Kind)
	w.BoolField("eligible", ok)
	w.StrField("reason", reason)
	w.IntField("remainingCap", remaining)
	w.IntField("price", p.PriceAt(h))
	w.EndObject()
	return w.String()
}

func Render(path string) string {
	if path == "" {
		return "# mint/v1\n\nSale phases of the platform's collections. Use `:<cid>` for one collection.\n"
	}
	s := mustSale(path) // only known collection ids get this far
	out := "# Sale of collection " + path + "\n\n"
	for i, p := range s.phases {
		out += ufmt.Sprintf("%d. %s phase, heights %d-%d, price %d -> %d ugnot, wallet cap %d\n",
			i+1, p.Kind, p.StartHeight, p.EndHeight, p.StartPrice, p.FloorPrice, p.WalletCap)
	}
	return out
}

func itoa(n int64) string { return strconv.FormatInt(n, 10) }
