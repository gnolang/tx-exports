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

const (
	admin = address("g16m0r7rm7fv5hx0ekr7gvx8g4fr7eu08nzhk6gt")

	// premium = coverage * PremiumRatePPM / fixedpoint.Scale
	PremiumRatePPM = int64(50000) // %5, fixedpoint raw units (out of 1_000_000)

	MinReporters        = int64(3)
	ClaimBucketCap      = int64(3)
	ClaimRefillPerBlock = int64(1)
)

type Member struct {
	Coverage  int64
	PremiumPd int64
	Active    bool
}

type Claim struct {
	Claimant  address
	Coverage  int64
	Readings  []int64
	Reported  *avl.Tree
	Resolved  bool
	Approved  bool
	PayoutAmt int64
}

var (
	reporters     = avl.NewTree() // addr(string) -> bool
	reporterCount int64
	members       = avl.NewTree() // addr(string) -> *Member
	claims        = avl.NewTree() // claimID(string) -> *Claim
	claimLimits   = avl.NewTree() // addr(string) -> *ratelimit.TokenBucket
	nextClaimID   int64
)

func onlyAdmin(cur realm) {
	if cur.Previous().Address() != admin {
		panic("insurancepool: admin only")
	}
}

func AddReporter(cur realm, addr address) {
	onlyAdmin(cur)
	if reporters.Get(addr.String()) == nil {
		reporterCount++
	}
	reporters.Set(addr.String(), true)
}

func RemoveReporter(cur realm, addr address) {
	onlyAdmin(cur)
	if reporters.Get(addr.String()) != nil {
		reporterCount--
	}
	reporters.Remove(addr.String())
}

func isReporter(addr address) bool {
	return reporters.Get(addr.String()) != nil
}

func calcPremium(coverage int64) int64 {
	rate := fixedpoint.FromRaw(PremiumRatePPM)
	premiumFixed := fixedpoint.FromInt(coverage).Mul(rate)
	return premiumFixed.Raw / fixedpoint.Scale
}

// Join: uye havuza katilir, prim gonderir
func Join(cur realm, coverage int64) {
	if !cur.Previous().IsUserCall() {
		panic("insurancepool: only direct user calls can join")
	}
	if coverage <= 0 {
		panic("insurancepool: coverage must be positive")
	}

	payer := cur.Previous().Address()
	if members.Get(payer.String()) != nil {
		panic("insurancepool: already a member")
	}

	premium := calcPremium(coverage)

	sent := unsafe.OriginSend()
	paid := sent.AmountOf("ugnot")
	if paid < premium {
		panic(ufmt.Sprintf("insurancepool: insufficient premium, need %d ugnot", premium))
	}

	members.Set(payer.String(), &Member{Coverage: coverage, PremiumPd: premium, Active: true})
}

// SubmitClaim: uye hasar talebi acar (rate-limited)
func SubmitClaim(cur realm) int64 {
	if !cur.Previous().IsUserCall() {
		panic("insurancepool: only direct user calls can submit a claim")
	}
	caller := cur.Previous().Address()

	mRaw := members.Get(caller.String())
	if mRaw == nil {
		panic("insurancepool: not a member")
	}
	m := mRaw.(*Member)
	if !m.Active {
		panic("insurancepool: membership not active")
	}

	nowHeight := runtime.ChainHeight()

	var bucket *ratelimit.TokenBucket
	bRaw := claimLimits.Get(caller.String())
	if bRaw == nil {
		bucket = ratelimit.NewTokenBucket(ClaimBucketCap, ClaimRefillPerBlock, nowHeight)
		claimLimits.Set(caller.String(), bucket)
	} else {
		bucket = bRaw.(*ratelimit.TokenBucket)
	}
	if !bucket.Allow(nowHeight, 1) {
		panic("insurancepool: claim rate limit exceeded, try again later")
	}

	nextClaimID++
	id := nextClaimID
	c := &Claim{
		Claimant: caller,
		Coverage: m.Coverage,
		Readings: []int64{},
		Reported: avl.NewTree(),
	}
	claims.Set(itoa(id), c)
	return id
}

// ReportClaim: reporter, claim icin 0..fixedpoint.Scale arasi bir odeme carpani bildirir
func ReportClaim(cur realm, claimID int64, multiplier int64) {
	caller := cur.Previous().Address()
	if !isReporter(caller) {
		panic("insurancepool: not an authorized reporter")
	}
	if multiplier < 0 || multiplier > fixedpoint.Scale {
		panic("insurancepool: multiplier out of range")
	}

	c := mustGetClaim(claimID)
	if c.Resolved {
		panic("insurancepool: claim already resolved")
	}
	if c.Reported.Get(caller.String()) != nil {
		panic("insurancepool: reporter already reported for this claim")
	}

	c.Reported.Set(caller.String(), true)
	c.Readings = append(c.Readings, multiplier)
}

// ResolveClaim: min. MinReporters rapor sonrasi medyan hesaplanir, odeme yapilir
func ResolveClaim(cur realm, claimID int64) {
	c := mustGetClaim(claimID)
	if c.Resolved {
		panic("insurancepool: claim already resolved")
	}
	if int64(len(c.Readings)) < MinReporters {
		panic("insurancepool: not enough reporters yet")
	}

	med := median.Median(c.Readings)
	multiplierFixed := fixedpoint.FromRaw(med)
	payoutFixed := fixedpoint.FromInt(c.Coverage).Mul(multiplierFixed)
	payout := payoutFixed.Raw / fixedpoint.Scale

	realmAddr := cur.Address()
	b := banker.NewBanker(banker.BankerTypeRealmSend, cur)
	have := b.GetCoins(realmAddr).AmountOf("ugnot")
	if payout > have {
		payout = have
	}

	// effects once, sonra interaction
	c.Resolved = true
	c.Approved = med > 0
	c.PayoutAmt = payout

	if payout > 0 {
		b.SendCoins(realmAddr, c.Claimant, chain.Coins{chain.NewCoin("ugnot", payout)})
	}
}

func mustGetClaim(claimID int64) *Claim {
	raw := claims.Get(itoa(claimID))
	if raw == nil {
		panic("insurancepool: claim not found")
	}
	c, ok := raw.(*Claim)
	if !ok {
		panic("insurancepool: internal error, corrupted claim entry")
	}
	return c
}

func itoa(i int64) string {
	return ufmt.Sprintf("%d", i)
}

func GetClaim(claimID int64) string {
	raw := claims.Get(itoa(claimID))
	if raw == nil {
		return "claim not found"
	}
	c := raw.(*Claim)
	return ufmt.Sprintf(
		"claim #%d | claimant=%s | coverage=%d | reports=%d | resolved=%t | approved=%t | payout=%d",
		claimID, c.Claimant.String(), c.Coverage, len(c.Readings), c.Resolved, c.Approved, c.PayoutAmt,
	)
}

func GetMember(addr address) string {
	raw := members.Get(addr.String())
	if raw == nil {
		return "not a member"
	}
	m := raw.(*Member)
	return ufmt.Sprintf("coverage=%d premium=%d active=%t", m.Coverage, m.PremiumPd, m.Active)
}

func Render(path string) string {
	b := banker.NewReadonlyBanker()
	balance := b.GetCoins(unsafe.CurrentRealm().Address()).AmountOf("ugnot")
	return ufmt.Sprintf(
		"# InsurancePool\n\nPool balance: %d ugnot\nTotal claims: %d\nReporters: %d\n",
		balance, nextClaimID, reporterCount,
	)
}
