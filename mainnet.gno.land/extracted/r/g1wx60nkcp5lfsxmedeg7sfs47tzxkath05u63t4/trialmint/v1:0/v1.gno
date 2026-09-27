package trialmint

import (
	"chain"
	"chain/banker"
	"chain/runtime"
	unsaferealm "chain/runtime/unsafe"
	"crypto/sha256"
	"strings"

	artpkg "gno.land/p/g1wx60nkcp5lfsxmedeg7sfs47tzxkath05u63t4/art3d"
	grc721 "gno.land/p/g1wx60nkcp5lfsxmedeg7sfs47tzxkath05u63t4/grc721v2"
	stable "gno.land/r/g1wx60nkcp5lfsxmedeg7sfs47tzxkath05u63t4/trialmint/stable"
	"gno.land/p/nt/seqid/v0"
	"gno.land/p/nt/ufmt/v0"
)

var (
	collectionOwnerHere address = "g1wx60nkcp5lfsxmedeg7sfs47tzxkath05u63t4"

	mintingOpen = true

	maxMintsPerWallet int64 = 0

	nextID seqid.ID
)

func MintAssembled(cur realm, to address) grc721.TokenID {
	if !mintingOpen {
		panic("minting is closed")
	}
	if maxMintsPerWallet > 0 && callerAddress() != collectionOwnerHere && stable.MintsByWallet(to) >= maxMintsPerWallet {
		panic(ufmt.Sprintf("wallet %s has already reached the %d-mint limit for this collection", to.String(), maxMintsPerWallet))
	}

	caller := callerAddress()
	requiredPrice := stable.EffectivePrice(caller)
	if requiredPrice != 0 {
		runtime.AssertOriginCall()
		if !unsaferealm.PreviousRealm().IsUserCall() {
			panic("payment verification requires a direct user call")
		}
		got := unsaferealm.OriginSend().AmountOf("ugnot")
		if got != requiredPrice {
			panic(ufmt.Sprintf("payment required: exactly %d ugnot, got %d", requiredPrice, got))
		}
		b := banker.NewBanker(banker.BankerTypeRealmSend, cur)
		b.SendCoins(cur.Address(), stable.Owner(), chain.Coins{{Denom: "ugnot", Amount: got}})
	}

	tp, comboKey := assembleUniqueTraits()

	tid := grc721.TokenID(ufmt.Sprintf("%d", uint64(nextID)+1))
	stable.RecordMint(cross(cur), to, caller, tid, tp.Chain, tp.ShapeIdx, tp.ColorIdx, tp.Metal, tp.Active, comboKey, rarityTier(tp))

	nextID.Next()

	return tid
}

type traitPreset struct {
	Chain    string
	ShapeIdx int
	ColorIdx int
	Metal    string
	Active   bool
}

func traitComboKey(chainName string, shapeIdx, colorIdx int, metal string, active bool) string {
	return ufmt.Sprintf("%s|%d|%d|%s|%t", chainName, shapeIdx, colorIdx, metal, active)
}

const activeProbability = 0.2

type prng struct {
	seed string
	n    int
}

func newPRNG(seed string) *prng { return &prng{seed: seed} }

func (p *prng) next() uint64 {
	p.n++
	material := ufmt.Sprintf("%s:%d", p.seed, p.n)
	sum := sha256.Sum256([]byte(material))
	var v uint64
	for i := 0; i < 8; i++ {
		v = v<<8 | uint64(sum[i])
	}
	return v
}

func (p *prng) floatIn(lo, hi float64) float64 {
	frac := float64(p.next()%1000000) / 1000000.0
	return lo + frac*(hi-lo)
}

func (p *prng) intn(n int) int {
	if n <= 1 {
		return 0
	}
	return int(p.next() % uint64(n))
}

func randomTraitPreset(attempt int) traitPreset {
	material := ufmt.Sprintf("assemble:%d:%d:%s:%d",
		runtime.ChainHeight(), uint64(nextID), callerAddress().String(), attempt)
	rnd := newPRNG(material)

	chainName := chainRoster[rnd.intn(len(chainRoster))]
	stone := artpkg.StoneForChain(chainName)
	colorIdx := artpkg.PickColorIndex(stone, rnd.next())
	var shapeIdx int
	if stone == "Pearl" {
		shapeIdx = rnd.intn(len(artpkg.PearlShapeNames))
	} else {
		cuts := artpkg.CutsForStone(stone)
		shapeIdx = cuts[rnd.intn(len(cuts))]
	}
	metal := artpkg.MetalNames[rnd.intn(len(artpkg.MetalNames))]
	active := rnd.floatIn(0, 1) < activeProbability || artpkg.ChainAlwaysActive(chainName)

	return traitPreset{Chain: chainName, ShapeIdx: shapeIdx, ColorIdx: colorIdx, Metal: metal, Active: active}
}

const maxAssembleAttempts = 200

func assembleUniqueTraits() (traitPreset, string) {
	for attempt := 0; attempt < maxAssembleAttempts; attempt++ {
		tp := randomTraitPreset(attempt)
		key := traitComboKey(tp.Chain, tp.ShapeIdx, tp.ColorIdx, tp.Metal, tp.Active)
		if stable.IsTraitComboAvailable(key) {
			return tp, key
		}
	}
	panic("could not find an unused trait combination after many attempts -- the collection may be fully minted")
}

func IsTraitComboAvailable(chainName string, shapeIdx, colorIdx int, metal string, active bool) bool {
	key := traitComboKey(chainName, shapeIdx, colorIdx, metal, active)
	return stable.IsTraitComboAvailable(key)
}

func MaxUniqueTraitCombos() int64 {
	var total int64
	for _, chainName := range chainRoster {
		stone := artpkg.StoneForChain(chainName)
		shapeCount := len(artpkg.CutsForStone(stone))
		if stone == "Pearl" {
			shapeCount = len(artpkg.PearlShapeNames)
		}
		states := int64(2) // active or sunset
		if artpkg.ChainAlwaysActive(chainName) {
			states = 1
		}
		total += int64(artpkg.ColorPaletteSize(stone)) * int64(shapeCount) * states
	}
	return total * int64(len(artpkg.MetalNames))
}

func ComboProbability(chainName string, shapeIdx, colorIdx int, active bool) float64 {
	stone := artpkg.StoneForChain(chainName)
	same := 0
	for _, c := range chainRoster {
		if artpkg.StoneForChain(c) == stone {
			same++
		}
	}
	p := float64(same) / float64(len(chainRoster))
	if stone == "Pearl" {
		p /= float64(len(artpkg.PearlShapeNames))
	} else {
		p /= float64(len(artpkg.CutsForStone(stone)))
	}
	p *= artpkg.ColorProbability(stone, colorIdx)
	if !artpkg.ChainAlwaysActive(chainName) {
		if active {
			p *= activeProbability
		} else {
			p *= 1 - activeProbability
		}
	}
	return p
}

var rarityTiers = []struct {
	name string
	maxP float64
}{
	{"Legendary", 0.000127233877},
	{"Epic", 0.000423465423},
	{"Rare", 0.000754985755},
	{"Uncommon", 0.00364957265},
}

func rarityTier(tp traitPreset) string {
	p := ComboProbability(tp.Chain, tp.ShapeIdx, tp.ColorIdx, tp.Active)
	for _, t := range rarityTiers {
		if p <= t.maxP {
			return t.name
		}
	}
	return "Common"
}

var chainRoster = []string{
	"TEST-1", "TEST-2", "TEST-3", "TEST-4", "TEST-5", "TEST-6", "TEST-7",
	"TEST-8", "TEST-9", "TEST-10", "TEST-11", "TEST-12", "TEST-13",
	"TOPAZ-1", "SAPPHIRE-1", "PEARL-1", "BETANET", "GNOLAND-1",
}

func AddChain(cur realm, chainName string) {
	assertOwner()
	if chainName == "" {
		panic("chain name must not be empty")
	}
	for _, c := range chainRoster {
		if c == chainName {
			panic("chain already in the roster")
		}
	}
	chainRoster = append(chainRoster, chainName)
}

func ChainRosterSize() int64 { return int64(len(chainRoster)) }
func ChainRosterCSV() string { return strings.Join(chainRoster, ";") }

func callerAddress() address {
	return unsaferealm.PreviousRealm().Address()
}

func assertOwner() {
	if callerAddress() != collectionOwnerHere {
		panic("unauthorized: caller is not the collection owner")
	}
}

func MintingOpen() bool { return mintingOpen }

func SetMintingOpen(cur realm, open bool) {
	assertOwner()
	mintingOpen = open
	stable.ReportMintingOpen(cross(cur), open)
}

func MaxMintsPerWallet() int64 { return maxMintsPerWallet }

func SetMaxMintsPerWallet(cur realm, max int64) {
	assertOwner()
	if max < 0 {
		panic("max must be non-negative (0 = unlimited)")
	}
	maxMintsPerWallet = max
	stable.ReportMaxMintsPerWallet(cross(cur), max)
}

func MintsByWallet(owner address) int64 {
	return stable.MintsByWallet(owner)
}
