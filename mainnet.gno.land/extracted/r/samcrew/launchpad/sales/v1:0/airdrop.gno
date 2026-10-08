package sales

import (
	"strconv"
	"strings"

	"chain"
	"gno.land/p/samcrew/launchpad/currency/v1"
	"gno.land/p/samcrew/launchpad/merkle/v1"
	"gno.land/p/samcrew/launchpad/meta/v1"
	sm "gno.land/p/samcrew/launchpad/safemath/v1"
	"gno.land/r/samcrew/launchpad/config/v1"
	"gno.land/r/samcrew/launchpad/tokens/v1"
)

const maxAirdropProofBytes = merkle.MaxDepth*64 + merkle.MaxDepth - 1

// AirdropRecord keeps the whole funded allocation encumbered until recipients
// claim. Claims never expire, and nothing sweeps or returns an unclaimed
// remainder.
type AirdropRecord struct {
	Root    string
	Total   int64
	Claimed int64
}

func requireAirdropRoot(root string) {
	h, err := merkle.ParseHash(root)
	if err != nil || merkle.FormatHash(h) != root || h == (merkle.Hash{}) {
		panic("launchpad/sales: invalid airdrop root")
	}
}

// CreateAirdrop funds one immutable campaign for a token from its creator's
// allowance. Its Merkle leaves are sha256(0x00 ||
// "launchpad-airdrop-v1|<token-id>|<index>|<beneficiary>|<amount>").
// The token ID in every leaf prevents a proof from authorizing a claim on a
// different launch, even if two creators publish the same tree shape.
func CreateAirdrop(cur realm, id, root string, total int64) {
	creator := directCaller(cur)
	currency.AssertNoCoins(0, cur)
	info := tokens.GetInfo(id)
	if info.Creator != creator || total <= 0 || airdropOf(id).Total != 0 {
		panic("launchpad/sales: creator airdrop only")
	}
	requireAirdropRoot(root)
	config.AssertLaneOpen(config.LaneAirdrop, info.CurrencyKey)
	tokens.TransferFrom(cross(cur), id, creator, chain.PackageAddress(salesPath), total)
	airdrops.Set(id, AirdropRecord{Root: root, Total: total})
	setTokenOwed(id, sm.Add(tokenOwed(id), total))
	if tokens.BalanceOf(id, chain.PackageAddress(salesPath)) < tokenOwed(id) {
		panic("launchpad/sales: token custody shortfall")
	}
	chain.Emit("LaunchpadAirdropCreated", "id", id, "creator", creator.String(),
		"root", root, "total", strconv.FormatInt(total, 10))
}

func GetAirdrop(id string) AirdropRecord {
	r := airdropOf(id)
	if r.Total == 0 {
		panic("launchpad/sales: airdrop not found")
	}
	return r
}

func AirdropClaimed(id string, index int) bool {
	if index < 0 {
		panic("launchpad/sales: invalid airdrop index")
	}
	return airdropClaims.Has(indexKey(id, index))
}

// ClaimAirdrop remains available while the airdrop lane is paused. Anyone can
// submit a proof; the destination is always the leaf's beneficiary. A leaf
// whose beneficiary is not written as the chain writes a caller's address can
// never be claimed: the token ledger would credit a balance no caller can
// reach.
func ClaimAirdrop(cur realm, id string, index int, beneficiary address, amount int64, proof string) {
	if !cur.IsCurrent() {
		panic("launchpad/sales: stale realm context")
	}
	currency.AssertNoCoins(0, cur)
	if index < 0 || amount <= 0 || len(proof) > maxAirdropProofBytes ||
		!meta.ValidAddress(beneficiary) ||
		beneficiary == chain.PackageAddress(salesPath) {
		panic("launchpad/sales: invalid airdrop claim")
	}
	r := GetAirdrop(id)
	key := indexKey(id, index)
	if airdropClaims.Has(key) {
		panic("launchpad/sales: airdrop already claimed")
	}
	h, _ := merkle.ParseHash(r.Root)
	p, err := merkle.ParseProof(proof)
	if err != nil {
		panic("launchpad/sales: invalid airdrop proof")
	}
	if proof != "" {
		parts := strings.Split(proof, ",")
		for i, sibling := range p {
			if merkle.FormatHash(sibling) != parts[i] {
				panic("launchpad/sales: invalid airdrop proof")
			}
		}
	}
	leaf := merkle.Leaf([]byte("launchpad-airdrop-v1|" + id + "|" +
		strconv.Itoa(index) + "|" + beneficiary.String() + "|" +
		strconv.FormatInt(amount, 10)))
	if !merkle.Verify(h, leaf, p) || sm.Add(r.Claimed, amount) > r.Total {
		panic("launchpad/sales: airdrop proof or allocation denied")
	}
	r.Claimed = sm.Add(r.Claimed, amount)
	airdropClaims.Set(key, true)
	airdrops.Set(id, r)
	setTokenOwed(id, sm.Sub(tokenOwed(id), amount))
	tokens.Transfer(cross(cur), id, beneficiary, amount)
	if tokens.BalanceOf(id, chain.PackageAddress(salesPath)) < tokenOwed(id) {
		panic("launchpad/sales: token custody shortfall")
	}
	chain.Emit("LaunchpadAirdropClaimed", "id", id,
		"index", strconv.Itoa(index), "beneficiary", beneficiary.String(),
		"amount", strconv.FormatInt(amount, 10))
}
