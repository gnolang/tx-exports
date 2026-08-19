package insurancepool

import (
	"chain"
	"chain/banker"
	"chain/runtime"
	"chain/runtime/unsafe"

	"gno.land/p/nt/avl/v0"
	"gno.land/p/nt/ufmt/v0"

	"gno.land/p/g16m0r7rm7fv5hx0ekr7gvx8g4fr7eu08nzhk6gt/fixedpoint"
	"gno.land/p/g16m0r7rm7fv5hx0ekr7gvx8g4fr7eu08nzhk6gt/median"
	"gno.land/p/g16m0r7rm7fv5hx0ekr7gvx8g4fr7eu08nzhk6gt/ratelimit"
)

type Policy struct {
	Holder   address
	Coverage fixedpoint.Fixed
	Premium  fixedpoint.Fixed
	Active   bool
}

const coverageMultiplierRaw int64 = 3000000 // 3x coverage of premium
const minReportsForPayout = 3

var (
	admin        address
	policies     *avl.Tree // holder addr -> *Policy
	reporters    *avl.Tree // reporter addr -> bool
	claimReports *avl.Tree // holder addr -> *avl.Tree(reporter addr -> int64 loss)
	claimBuckets *avl.Tree // reporter addr -> *ratelimit.TokenBucket
)

func init() {
	admin = address("g16m0r7rm7fv5hx0ekr7gvx8g4fr7eu08nzhk6gt")
	policies = avl.NewTree()
	reporters = avl.NewTree()
	claimReports = avl.NewTree()
	claimBuckets = avl.NewTree()
}

func assertUserCall(cur realm) address {
	if !cur.Previous().IsUserCall() {
		panic("insurancepool: must be a direct user call")
	}
	return cur.Previous().Address()
}

func AddReporter(cur realm, addr address) {
	caller := assertUserCall(cur)
	if caller != admin {
		panic("insurancepool: admin only")
	}
	reporters.Set(string(addr), true)
}

func BuyPolicy(cur realm) {
	caller := assertUserCall(cur)
	sent := unsafe.OriginSend()
	amount := sent.AmountOf("ugnot")
	if amount <= 0 {
		panic("insurancepool: must send ugnot premium")
	}

	premium := fixedpoint.FromRaw(amount)
	coverage := premium.Mul(fixedpoint.FromRaw(coverageMultiplierRaw))

	key := string(caller)
	if policies.Has(key) {
		existing := policies.Get(key)
		p := existing.(*Policy)
		p.Premium = p.Premium.Add(premium)
		p.Coverage = p.Coverage.Add(coverage)
		p.Active = true
	} else {
		policies.Set(key, &Policy{
			Holder:   caller,
			Coverage: coverage,
			Premium:  premium,
			Active:   true,
		})
	}
}

func SubmitClaimReport(cur realm, holder address, lossAmount int64) {
	caller := assertUserCall(cur)
	if !reporters.Has(string(caller)) {
		panic("insurancepool: not an authorized reporter")
	}
	if lossAmount <= 0 {
		panic("insurancepool: loss amount must be positive")
	}
	if !policies.Has(string(holder)) {
		panic("insurancepool: no policy for holder")
	}

	now := runtime.ChainHeight()
	var bucket *ratelimit.TokenBucket
	if claimBuckets.Has(string(caller)) {
		bRaw := claimBuckets.Get(string(caller))
		bucket = bRaw.(*ratelimit.TokenBucket)
	} else {
		bucket = ratelimit.NewTokenBucket(5, 1, now)
		claimBuckets.Set(string(caller), bucket)
	}
	if !bucket.Allow(now, 1) {
		panic("insurancepool: rate limit exceeded for reporter")
	}

	var reportTree *avl.Tree
	if claimReports.Has(string(holder)) {
		rt := claimReports.Get(string(holder))
		reportTree = rt.(*avl.Tree)
	} else {
		reportTree = avl.NewTree()
		claimReports.Set(string(holder), reportTree)
	}
	reportTree.Set(string(caller), lossAmount)
}

func FinalizeClaim(cur realm, holder address) {
	assertUserCall(cur)

	if !policies.Has(string(holder)) {
		panic("insurancepool: no policy for holder")
	}
	polRaw := policies.Get(string(holder))
	p := polRaw.(*Policy)
	if !p.Active {
		panic("insurancepool: policy not active")
	}

	if !claimReports.Has(string(holder)) {
		panic("insurancepool: no claim reports submitted")
	}
	rtRaw := claimReports.Get(string(holder))
	reportTree := rtRaw.(*avl.Tree)
	if reportTree.Size() < minReportsForPayout {
		panic("insurancepool: not enough reports yet")
	}

	values := make([]int64, 0, reportTree.Size())
	reportTree.Iterate("", "", func(key string, value interface{}) bool {
		values = append(values, value.(int64))
		return false
	})

	medianLoss := median.Median(values)
	payout := fixedpoint.FromRaw(medianLoss)
	if payout.Cmp(p.Coverage) > 0 {
		payout = p.Coverage
	}

	realmAddr := cur.Address()
	b := banker.NewBanker(banker.BankerTypeRealmSend, cur)
	have := b.GetCoins(realmAddr).AmountOf("ugnot")

	payoutRaw := payout.Raw
	if payoutRaw > have {
		payoutRaw = have
	}
	if payoutRaw <= 0 {
		panic("insurancepool: nothing to pay out")
	}

	b.SendCoins(realmAddr, p.Holder, chain.Coins{chain.NewCoin("ugnot", payoutRaw)})

	p.Active = false
	claimReports.Remove(string(holder))
}

func Render(path string) string {
	out := "# Insurance Pool\n\n"
	out += ufmt.Sprintf("Total policies: %d\n\n", policies.Size())
	policies.Iterate("", "", func(key string, value interface{}) bool {
		p := value.(*Policy)
		out += ufmt.Sprintf("- %s | coverage=%s premium=%s active=%t\n",
			key, p.Coverage.String(), p.Premium.String(), p.Active)
		return false
	})
	return out
}
