// Package tollgate implements the on-chain HTTP 402 (x402) metering vault,
// Ed25519-authenticated prepaid credit passes, fixed-window subscriptions,
// challenge-window settlements with buyer reclaim protection, and verifiable
// SHA-256 receipt anchoring for Gno.land.
package tollgate

import (
	"chain"
	"chain/banker"
	"chain/runtime"
	"chain/runtime/unsafe"
	"crypto/sha256"
	"strconv"
	"strings"

	ptollgate "gno.land/p/g1zt8w45ecxhlsdse7hd5gwr6xzcaxy9zsej6hl2/tollgate"
	"gno.land/p/nt/markdown/sanitize/v0"
	"gno.land/p/nt/seqid/v0"
)

func mustCurrent(cur realm) {
	if !cur.IsCurrent() {
		panic("tollgate: spoofed realm capability")
	}
}

func readDirectUgnot(cur realm) int64 {
	if !cur.IsCurrent() {
		panic("tollgate: spoofed realm capability")
	}
	if !cur.Previous().IsUserCall() {
		panic("tollgate: payment must be a direct user call")
	}
	sent := unsafe.OriginSend()
	var total int64
	for _, c := range sent {
		if c.Denom != "ugnot" {
			panic("tollgate: only ugnot is accepted")
		}
		total = satAdd(total, c.Amount)
	}
	if total <= 0 {
		panic("tollgate: positive ugnot payment required")
	}
	return total
}

// satAdd prevents silent int64 wraparound on telemetry/revenue accumulators.
func satAdd(a, b int64) int64 {
	if b <= 0 {
		return a
	}
	if a > maxInt64-b {
		return maxInt64
	}
	return a + b
}

func idKey(id uint64) string {
	return seqid.ID(id).Binary()
}

func nonceKey(serviceID uint64, nonce string) string {
	return strconv.FormatUint(serviceID, 10) + ":" + nonce
}

func appendLP(b *strings.Builder, s string) {
	b.WriteString(strconv.Itoa(len(s)))
	b.WriteByte(':')
	b.WriteString(s)
	b.WriteByte('|')
}

// VoucherMessage builds the canonical domain-separated byte message signed by
// a buyer's Ed25519 voucher key for off-chain HTTP authentication and optional
// on-chain ClaimSettlement / ConsumeSubscription cryptographic proof.
func VoucherMessage(
	chainID string,
	serviceID uint64,
	passID uint64,
	subID uint64,
	units int64,
	nonce string,
	resourceHash string,
) string {
	var b strings.Builder
	b.WriteString(VoucherDomain)
	b.WriteByte('|')
	appendLP(&b, chainID)
	b.WriteString(strconv.FormatUint(serviceID, 10))
	b.WriteByte('|')
	b.WriteString(strconv.FormatUint(passID, 10))
	b.WriteByte('|')
	b.WriteString(strconv.FormatUint(subID, 10))
	b.WriteByte('|')
	b.WriteString(strconv.FormatInt(units, 10))
	b.WriteByte('|')
	appendLP(&b, nonce)
	appendLP(&b, resourceHash)
	return b.String()
}

const maxPayWordSteps int64 = 1024

func hexEncode32(sum [32]byte) string {
	const digits = "0123456789abcdef"
	var out [64]byte
	for i := 0; i < 32; i++ {
		out[2*i] = digits[sum[i]>>4]
		out[2*i+1] = digits[sum[i]&0x0f]
	}
	return string(out[:])
}

// PayWordStep advances a Rivest-Shamir PayWord SHA-256 hash-chain voucher by 1 unit.
func PayWordStep(chainID string, prevHex string) string {
	sum := sha256.Sum256([]byte("tollgate-payword-v1|" + chainID + "|" + prevHex))
	return hexEncode32(sum)
}

func verifyPayWord(chainID string, anchorHex string, preimageHex string, steps int64) bool {
	if steps <= 0 || steps > maxPayWordSteps {
		return false
	}
	if !ptollgate.IsValidHexDigest(anchorHex) || !ptollgate.IsValidHexDigest(preimageHex) {
		return false
	}
	cur := preimageHex
	for i := int64(0); i < steps; i++ {
		cur = PayWordStep(chainID, cur)
	}
	var diff byte
	for i := 0; i < 64; i++ {
		diff |= cur[i] ^ anchorHex[i]
	}
	return diff == 0
}

func validateOptionalPubKey(pubKeyHex string) string {
	pubKeyHex = strings.TrimSpace(strings.ToLower(pubKeyHex))
	if pubKeyHex == "" {
		return ""
	}
	if !ptollgate.IsValidHexDigest(pubKeyHex) {
		panic("tollgate: invalid voucherPubKeyHex (expect empty or 64-char lowercase Ed25519 hex)")
	}
	return pubKeyHex
}

func getServiceRecord(id uint64) *serviceRecord {
	if id == 0 {
		return nil
	}
	v := services.Get(idKey(id))
	if v == nil {
		return nil
	}
	return v.(*serviceRecord)
}

func getPassRecord(id uint64) *passRecord {
	if id == 0 {
		return nil
	}
	v := passes.Get(idKey(id))
	if v == nil {
		return nil
	}
	return v.(*passRecord)
}

func getSubRecord(id uint64) *subRecord {
	if id == 0 {
		return nil
	}
	v := subs.Get(idKey(id))
	if v == nil {
		return nil
	}
	return v.(*subRecord)
}

func getSettlementRecord(id uint64) *settlementRecord {
	if id == 0 {
		return nil
	}
	v := settlements.Get(idKey(id))
	if v == nil {
		return nil
	}
	return v.(*settlementRecord)
}

func getReceiptRecord(id uint64) *receiptRecord {
	if id == 0 {
		return nil
	}
	v := receipts.Get(idKey(id))
	if v == nil {
		return nil
	}
	return v.(*receiptRecord)
}

// RegisterService registers a new HTTP 402 / Tollgate metered API service.
func RegisterService(
	cur realm,
	slug string,
	name string,
	endpointURL string,
	payTo address,
	unitPriceUgnot int64,
	subPriceUgnot int64,
	subBlocks int64,
	subQuota int64,
	challengeBlocks int64,
	description string,
) uint64 {
	if !cur.IsCurrent() {
		panic("tollgate: spoofed realm capability")
	}
	owner := cur.Previous().Address()

	slug = strings.TrimSpace(slug)
	if !ptollgate.ValidateSlug(slug) {
		panic("tollgate: invalid service slug (use 2..40 lowercase a-z0-9-)")
	}
	if slugIndex.Has(slug) {
		panic("tollgate: slug already registered")
	}
	name = strings.TrimSpace(sanitize.StripBidiAndZeroWidth(name))
	if name == "" || len(name) > maxNameLen {
		panic("tollgate: invalid service name")
	}
	endpointURL = strings.TrimSpace(sanitize.URL(endpointURL))
	if endpointURL == "" || len(endpointURL) > maxURLLen {
		panic("tollgate: invalid endpoint URL")
	}
	description = strings.TrimSpace(sanitize.StripBidiAndZeroWidth(description))
	if len(description) > maxDescLen {
		panic("tollgate: description exceeds max length")
	}
	if !payTo.IsValid() {
		payTo = owner
	}
	if unitPriceUgnot <= 0 || unitPriceUgnot > maxAmountPerTx {
		panic("tollgate: unitPriceUgnot out of bounds")
	}
	if subPriceUgnot < 0 || subPriceUgnot > maxAmountPerTx {
		panic("tollgate: subPriceUgnot out of bounds")
	}
	if subPriceUgnot > 0 && (subBlocks < minExpiryBlocks || subBlocks > maxExpiryBlocks || subQuota <= 0 || subQuota > maxUnitsPerTx) {
		panic("tollgate: subscription requires valid subBlocks and subQuota")
	}
	if challengeBlocks < ptollgate.MinChallengeBlocks || challengeBlocks > ptollgate.MaxChallengeBlocks {
		panic("tollgate: challengeBlocks out of bounds")
	}

	sid := nextServiceID.Next()
	rec := &serviceRecord{
		id:              uint64(sid),
		slug:            slug,
		name:            name,
		description:     description,
		endpointURL:     endpointURL,
		owner:           owner,
		payTo:           payTo,
		unitPriceUgnot:  unitPriceUgnot,
		subPriceUgnot:   subPriceUgnot,
		subBlocks:       subBlocks,
		subQuota:        subQuota,
		challengeBlocks: challengeBlocks,
		paused:          false,
		createdHeight:   runtime.ChainHeight(),
	}
	services.Set(sid.Binary(), rec)
	slugIndex.Set(slug, uint64(sid))

	chain.Emit(
		"ServiceRegistered",
		"service_id", strconv.FormatUint(rec.id, 10),
		"slug", slug,
		"owner", owner.String(),
		"pay_to", payTo.String(),
		"unit_price_ugnot", strconv.FormatInt(unitPriceUgnot, 10),
	)
	return rec.id
}

// UpdateServicePricing lets the service owner adjust unit and subscription prices.
func UpdateServicePricing(
	cur realm,
	serviceID uint64,
	unitPriceUgnot int64,
	subPriceUgnot int64,
	subBlocks int64,
	subQuota int64,
) {
	if !cur.IsCurrent() {
		panic("tollgate: spoofed realm capability")
	}
	svc := getServiceRecord(serviceID)
	if svc == nil {
		panic("tollgate: service not found")
	}
	if cur.Previous().Address() != svc.owner {
		panic("tollgate: only service owner may update pricing")
	}
	if unitPriceUgnot <= 0 || unitPriceUgnot > maxAmountPerTx || subPriceUgnot < 0 || subPriceUgnot > maxAmountPerTx {
		panic("tollgate: invalid pricing parameters")
	}
	if subPriceUgnot > 0 && (subBlocks < minExpiryBlocks || subBlocks > maxExpiryBlocks || subQuota <= 0 || subQuota > maxUnitsPerTx) {
		panic("tollgate: subscription requires valid subBlocks and subQuota")
	}
	svc.unitPriceUgnot = unitPriceUgnot
	svc.subPriceUgnot = subPriceUgnot
	svc.subBlocks = subBlocks
	svc.subQuota = subQuota

	chain.Emit(
		"ServicePricingUpdated",
		"service_id", strconv.FormatUint(serviceID, 10),
		"unit_price_ugnot", strconv.FormatInt(unitPriceUgnot, 10),
		"sub_price_ugnot", strconv.FormatInt(subPriceUgnot, 10),
	)
}

// SetServicePaused pauses or unpauses new passes/subscriptions on a service.
func SetServicePaused(cur realm, serviceID uint64, paused bool) {
	if !cur.IsCurrent() {
		panic("tollgate: spoofed realm capability")
	}
	svc := getServiceRecord(serviceID)
	if svc == nil {
		panic("tollgate: service not found")
	}
	if cur.Previous().Address() != svc.owner {
		panic("tollgate: only service owner may pause service")
	}
	svc.paused = paused
	state := StatusActive
	if paused {
		state = StatusPaused
	}
	chain.Emit("ServiceStatusChanged", "service_id", strconv.FormatUint(serviceID, 10), "status", state)
}

// OpenPass locks buyer ugnot into an on-chain prepaid credit vault for high-frequency
// metered API calls. When voucherPubKeyHex (64-char Ed25519 hex) is set, both the
// HTTP gateway AND on-chain ClaimSettlement verify buyer Ed25519 voucher signatures.
// If maxPerCallUgnot <= 0, it safely defaults to the service's current unitPriceUgnot.
func OpenPass(
	cur realm,
	serviceID uint64,
	maxPerCallUgnot int64,
	expiryBlocks int64,
	voucherPubKeyHex string,
) uint64 {
	if !cur.IsCurrent() {
		panic("tollgate: spoofed realm capability")
	}
	if !cur.Previous().IsUserCall() {
		panic("tollgate: payment must be a direct user call")
	}
	sent := readDirectUgnot(cur)
	svc := getServiceRecord(serviceID)
	if svc == nil {
		panic("tollgate: service not found")
	}
	if svc.paused {
		panic("tollgate: service is paused")
	}
	if expiryBlocks < minExpiryBlocks || expiryBlocks > maxExpiryBlocks {
		panic("tollgate: expiryBlocks out of bounds")
	}
	// P0 #5: Safe default per-call cap equals current unitPriceUgnot (never whole deposit).
	if maxPerCallUgnot <= 0 {
		maxPerCallUgnot = svc.unitPriceUgnot
	}
	if maxPerCallUgnot < svc.unitPriceUgnot {
		panic("tollgate: maxPerCallUgnot below service unit price")
	}
	cleanPub := validateOptionalPubKey(voucherPubKeyHex)

	buyer := cur.Previous().Address()
	sessAddr, _, _, isSess := runtime.GetSessionInfo()
	height := runtime.ChainHeight()

	pid := nextPassID.Next()
	rec := &passRecord{
		id:              uint64(pid),
		serviceID:       serviceID,
		buyer:           buyer,
		depositUgnot:    sent,
		maxPerCallUgnot: maxPerCallUgnot,
		expiryHeight:    height + expiryBlocks,
		openedHeight:    height,
		usedSessionKey:  isSess,
		sessionKeyAddr:  sessAddr,
		voucherPubKey:   cleanPub,
	}
	passes.Set(pid.Binary(), rec)
	activePassesCount++
	totalDepositedUgnot = satAdd(totalDepositedUgnot, sent)

	chain.Emit(
		"PassOpened",
		"pass_id", strconv.FormatUint(rec.id, 10),
		"service_id", strconv.FormatUint(serviceID, 10),
		"buyer", buyer.String(),
		"deposit_ugnot", strconv.FormatInt(sent, 10),
		"expiry_height", strconv.FormatInt(rec.expiryHeight, 10),
	)
	return rec.id
}

// TopUpPass adds more ugnot and optionally extends expiry of an active pass.
func TopUpPass(cur realm, passID uint64, extendBlocks int64) {
	if !cur.IsCurrent() {
		panic("tollgate: spoofed realm capability")
	}
	if !cur.Previous().IsUserCall() {
		panic("tollgate: payment must be a direct user call")
	}
	sent := readDirectUgnot(cur)
	p := getPassRecord(passID)
	if p == nil {
		panic("tollgate: pass not found")
	}
	if p.closed {
		panic("tollgate: pass is closed")
	}
	if cur.Previous().Address() != p.buyer {
		panic("tollgate: only pass buyer may top up")
	}
	if extendBlocks < 0 || extendBlocks > maxExpiryBlocks {
		panic("tollgate: invalid extendBlocks")
	}
	if p.depositUgnot > maxInt64-sent {
		panic("tollgate: deposit overflow")
	}
	p.depositUgnot += sent
	if extendBlocks > 0 {
		base := p.expiryHeight
		if h := runtime.ChainHeight(); h > base {
			base = h
		}
		p.expiryHeight = base + extendBlocks
	}
	totalDepositedUgnot = satAdd(totalDepositedUgnot, sent)

	chain.Emit(
		"PassToppedUp",
		"pass_id", strconv.FormatUint(passID, 10),
		"added_ugnot", strconv.FormatInt(sent, 10),
		"expiry_height", strconv.FormatInt(p.expiryHeight, 10),
	)
}

// RequestEarlyClose shortens a pass expiry to height + service.challengeBlocks so
// the provider gets one bounded settlement window and cannot lock buyer funds.
func RequestEarlyClose(cur realm, passID uint64) int64 {
	if !cur.IsCurrent() {
		panic("tollgate: spoofed realm capability")
	}
	p := getPassRecord(passID)
	if p == nil {
		panic("tollgate: pass not found")
	}
	if p.closed {
		panic("tollgate: pass already closed")
	}
	if cur.Previous().Address() != p.buyer {
		panic("tollgate: only pass buyer may request close")
	}
	svc := getServiceRecord(p.serviceID)
	target := runtime.ChainHeight() + svc.challengeBlocks
	if target < p.expiryHeight {
		p.expiryHeight = target
	}
	chain.Emit(
		"PassEarlyCloseRequested",
		"pass_id", strconv.FormatUint(passID, 10),
		"expiry_height", strconv.FormatInt(p.expiryHeight, 10),
	)
	return p.expiryHeight
}

// ClosePass refunds any unspent, non-pending ugnot back to the pass buyer once
// the pass has expired (or its service is paused) and no settlement is pending.
func ClosePass(cur realm, passID uint64) int64 {
	if !cur.IsCurrent() {
		panic("tollgate: spoofed realm capability")
	}
	p := getPassRecord(passID)
	if p == nil {
		panic("tollgate: pass not found")
	}
	if p.closed {
		panic("tollgate: pass already closed")
	}
	if cur.Previous().Address() != p.buyer {
		panic("tollgate: only pass buyer may close pass")
	}
	svc := getServiceRecord(p.serviceID)
	height := runtime.ChainHeight()
	if height < p.expiryHeight && !svc.paused {
		panic("tollgate: pass not expired yet (call RequestEarlyClose first)")
	}
	if p.pendingUgnot > 0 {
		panic("tollgate: pending settlements must resolve before closing")
	}

	refund, err := ptollgate.ComputeAvailable(p.depositUgnot, p.spentUgnot, p.pendingUgnot)
	if err != nil {
		panic(err.Error())
	}
	p.closed = true
	if activePassesCount > 0 {
		activePassesCount--
	}
	if refund > 0 {
		totalRefundedUgnot = satAdd(totalRefundedUgnot, refund)
		b := banker.NewBanker(banker.BankerTypeRealmSend, cur)
		b.SendCoins(cur.Address(), p.buyer, chain.NewCoins(chain.NewCoin("ugnot", refund)))
	}

	chain.Emit(
		"PassClosed",
		"pass_id", strconv.FormatUint(passID, 10),
		"buyer", p.buyer.String(),
		"refund_ugnot", strconv.FormatInt(refund, 10),
	)
	return refund
}

// Subscribe purchases a fixed-window quota subscription, optionally binds a
// buyer Ed25519 voucher public key, and pays the service provider immediately.
func Subscribe(cur realm, serviceID uint64, voucherPubKeyHex string) uint64 {
	if !cur.IsCurrent() {
		panic("tollgate: spoofed realm capability")
	}
	if !cur.Previous().IsUserCall() {
		panic("tollgate: payment must be a direct user call")
	}
	sent := readDirectUgnot(cur)
	svc := getServiceRecord(serviceID)
	if svc == nil {
		panic("tollgate: service not found")
	}
	if svc.paused {
		panic("tollgate: service is paused")
	}
	if svc.subPriceUgnot <= 0 {
		panic("tollgate: service does not offer subscriptions")
	}
	if sent < svc.subPriceUgnot {
		panic("tollgate: insufficient ugnot for subscription")
	}
	cleanPub := validateOptionalPubKey(voucherPubKeyHex)

	buyer := cur.Previous().Address()
	sessAddr, _, _, isSess := runtime.GetSessionInfo()
	height := runtime.ChainHeight()
	sid := nextSubID.Next()

	rec := &subRecord{
		id:             uint64(sid),
		serviceID:      serviceID,
		buyer:          buyer,
		paidUgnot:      svc.subPriceUgnot,
		quotaTotal:     svc.subQuota,
		quotaUsed:      0,
		startHeight:    height,
		expiryHeight:   height + svc.subBlocks,
		usedSessionKey: isSess,
		sessionKeyAddr: sessAddr,
		voucherPubKey:  cleanPub,
	}
	subs.Set(sid.Binary(), rec)
	svc.escrowedRevenue = satAdd(svc.escrowedRevenue, svc.subPriceUgnot)
	totalSubRevenueUgnot = satAdd(totalSubRevenueUgnot, svc.subPriceUgnot)

	b := banker.NewBanker(banker.BankerTypeRealmSend, cur)
	b.SendCoins(cur.Address(), svc.payTo, chain.NewCoins(chain.NewCoin("ugnot", svc.subPriceUgnot)))
	if change := sent - svc.subPriceUgnot; change > 0 {
		b.SendCoins(cur.Address(), buyer, chain.NewCoins(chain.NewCoin("ugnot", change)))
	}

	chain.Emit(
		"Subscribed",
		"sub_id", strconv.FormatUint(rec.id, 10),
		"service_id", strconv.FormatUint(serviceID, 10),
		"buyer", buyer.String(),
		"paid_ugnot", strconv.FormatInt(svc.subPriceUgnot, 10),
		"quota", strconv.FormatInt(svc.subQuota, 10),
		"expiry_height", strconv.FormatInt(rec.expiryHeight, 10),
	)
	return rec.id
}

// ConsumeSubscription records metered quota usage against an active subscription.
// If the subscription registered a voucherPubKey, buyerSigHex MUST be a valid
// Ed25519 signature over VoucherMessage(...).
func ConsumeSubscription(
	cur realm,
	subID uint64,
	units int64,
	nonce string,
	resourceHash string,
	buyerSigHex string,
) uint64 {
	if !cur.IsCurrent() {
		panic("tollgate: spoofed realm capability")
	}
	sub := getSubRecord(subID)
	if sub == nil {
		panic("tollgate: subscription not found")
	}
	svc := getServiceRecord(sub.serviceID)
	if cur.Previous().Address() != svc.owner {
		panic("tollgate: only service owner may consume subscription quota")
	}
	if runtime.ChainHeight() >= sub.expiryHeight {
		panic("tollgate: subscription expired")
	}
	// P0 #4: Overflow-safe quota check (never wraps negative).
	if units <= 0 || units > maxUnitsPerTx || units > sub.quotaTotal-sub.quotaUsed {
		panic("tollgate: subscription quota exceeded")
	}
	if !ptollgate.ValidateNonce(nonce) {
		panic("tollgate: invalid nonce")
	}
	if !ptollgate.IsValidHexDigest(resourceHash) {
		panic("tollgate: invalid resourceHash (expect 64-char lowercase sha256 hex)")
	}
	nk := nonceKey(sub.serviceID, nonce)
	if nonceUsed.Has(nk) {
		panic("tollgate: duplicate nonce")
	}

	buyerSigned := false
	if sub.voucherPubKey != "" {
		if !verifyPayWord(runtime.ChainID(), sub.voucherPubKey, buyerSigHex, units) {
			panic("tollgate: invalid PayWord SHA-256 buyer voucher preimage")
		}
		sub.voucherPubKey = buyerSigHex
		buyerSigned = true
	}

	sub.quotaUsed += units
	svc.totalCalls = satAdd(svc.totalCalls, units)

	commitment := ptollgate.ReceiptCommitment(
		runtime.ChainID(),
		sub.serviceID,
		0,
		sub.buyer.String(),
		svc.payTo.String(),
		units,
		0,
		nonce,
		resourceHash,
	)

	rid := nextReceiptID.Next()
	r := &receiptRecord{
		id:           uint64(rid),
		rail:         RailSubscription,
		serviceID:    sub.serviceID,
		subID:        sub.id,
		buyer:        sub.buyer,
		provider:     svc.payTo,
		units:        units,
		amountUgnot:  0,
		nonce:        nonce,
		resourceHash: resourceHash,
		commitment:   commitment,
		height:       runtime.ChainHeight(),
		buyerSigned:  buyerSigned,
	}
	receipts.Set(rid.Binary(), r)
	receiptHashIndex.Set(commitment, r.id)
	nonceUsed.Set(nk, r.id)

	chain.Emit(
		"SubscriptionUsageAnchored",
		"receipt_id", strconv.FormatUint(r.id, 10),
		"sub_id", strconv.FormatUint(subID, 10),
		"units", strconv.FormatInt(units, 10),
		"commitment", commitment,
	)
	return r.id
}

// ClaimSettlement lets the service provider submit a metered usage batch against
// a prepaid pass BEFORE pass expiry. If the pass bound an Ed25519 voucherPubKey,
// buyerSigHex is verified directly on-chain via crypto/ed25519.Verify.
func ClaimSettlement(
	cur realm,
	passID uint64,
	units int64,
	nonce string,
	resourceHash string,
	buyerSigHex string,
) uint64 {
	if !cur.IsCurrent() {
		panic("tollgate: spoofed realm capability")
	}
	p := getPassRecord(passID)
	if p == nil {
		panic("tollgate: pass not found")
	}
	if p.closed {
		panic("tollgate: pass is closed")
	}
	// P0 #3: Provider cannot file new claims once pass has expired (protects ClosePass).
	if runtime.ChainHeight() >= p.expiryHeight {
		panic("tollgate: pass expired; claims closed")
	}
	svc := getServiceRecord(p.serviceID)
	if cur.Previous().Address() != svc.owner {
		panic("tollgate: only service owner may claim settlement")
	}
	if units <= 0 || units > maxUnitsPerTx {
		panic("tollgate: units out of bounds")
	}
	if !ptollgate.ValidateNonce(nonce) {
		panic("tollgate: invalid nonce")
	}
	if !ptollgate.IsValidHexDigest(resourceHash) {
		panic("tollgate: invalid resourceHash (expect 64-char lowercase sha256 hex)")
	}
	nk := nonceKey(svc.id, nonce)
	if nonceUsed.Has(nk) {
		panic("tollgate: duplicate nonce")
	}

	buyerSigned := false
	if p.voucherPubKey != "" {
		if !verifyPayWord(runtime.ChainID(), p.voucherPubKey, buyerSigHex, units) {
			panic("tollgate: invalid PayWord SHA-256 buyer voucher preimage")
		}
		p.voucherPubKey = buyerSigHex
		buyerSigned = true
	}

	charge, err := ptollgate.ComputeCharge(svc.unitPriceUgnot, units)
	if err != nil {
		panic(err.Error())
	}
	// Overflow-safe per-call ceiling check: netUgnot <= maxPerCallUgnot * units
	if p.maxPerCallUgnot <= maxInt64/units && charge.NetUgnot > p.maxPerCallUgnot*units {
		panic("tollgate: batch exceeds pass maxPerCallUgnot ceiling")
	}
	avail, err := ptollgate.ComputeAvailable(p.depositUgnot, p.spentUgnot, p.pendingUgnot)
	if err != nil {
		panic(err.Error())
	}
	if charge.NetUgnot > avail {
		panic("tollgate: insufficient available pass balance")
	}

	height := runtime.ChainHeight()
	commitment := ptollgate.ReceiptCommitment(
		runtime.ChainID(),
		svc.id,
		p.id,
		p.buyer.String(),
		svc.payTo.String(),
		units,
		charge.NetUgnot,
		nonce,
		resourceHash,
	)

	rid := nextReceiptID.Next()
	stID := nextSettlementID.Next()
	r := &receiptRecord{
		id:           uint64(rid),
		rail:         RailMeteredPass,
		serviceID:    svc.id,
		passID:       p.id,
		settlementID: uint64(stID),
		buyer:        p.buyer,
		provider:     svc.payTo,
		units:        units,
		amountUgnot:  charge.NetUgnot,
		nonce:        nonce,
		resourceHash: resourceHash,
		commitment:   commitment,
		height:       height,
		buyerSigned:  buyerSigned,
	}
	receipts.Set(rid.Binary(), r)
	receiptHashIndex.Set(commitment, r.id)
	nonceUsed.Set(nk, r.id)

	st := &settlementRecord{
		id:            uint64(stID),
		serviceID:     svc.id,
		passID:        p.id,
		buyer:         p.buyer,
		provider:      svc.payTo,
		units:         units,
		grossUgnot:    charge.GrossUgnot,
		discountBps:   charge.DiscountBps,
		netUgnot:      charge.NetUgnot,
		nonce:         nonce,
		resourceHash:  resourceHash,
		commitment:    commitment,
		claimedHeight: height,
		challengeEnd:  height + svc.challengeBlocks,
		status:        StatusPending,
		receiptID:     r.id,
		buyerSigned:   buyerSigned,
	}
	settlements.Set(stID.Binary(), st)
	p.pendingUgnot += charge.NetUgnot

	chain.Emit(
		"SettlementClaimed",
		"settlement_id", strconv.FormatUint(st.id, 10),
		"pass_id", strconv.FormatUint(p.id, 10),
		"receipt_id", strconv.FormatUint(r.id, 10),
		"net_ugnot", strconv.FormatInt(charge.NetUgnot, 10),
		"challenge_end", strconv.FormatInt(st.challengeEnd, 10),
		"commitment", commitment,
	)
	return st.id
}

// DisputeSettlement freezes a pending settlement inside its challenge window.
func DisputeSettlement(cur realm, settlementID uint64, reason string) {
	if !cur.IsCurrent() {
		panic("tollgate: spoofed realm capability")
	}
	st := getSettlementRecord(settlementID)
	if st == nil {
		panic("tollgate: settlement not found")
	}
	if st.status != StatusPending {
		panic("tollgate: settlement is not pending")
	}
	if cur.Previous().Address() != st.buyer {
		panic("tollgate: only buyer may dispute settlement")
	}
	if runtime.ChainHeight() >= st.challengeEnd {
		panic("tollgate: challenge window has elapsed")
	}
	reason = strings.TrimSpace(sanitize.StripBidiAndZeroWidth(reason))
	if reason == "" || len(reason) > maxReasonLen {
		panic("tollgate: valid dispute reason required")
	}
	st.status = StatusDisputed
	st.disputeReason = reason

	chain.Emit(
		"SettlementDisputed",
		"settlement_id", strconv.FormatUint(settlementID, 10),
		"buyer", st.buyer.String(),
	)
}

// RefundDisputedSettlement lets the service owner concede a disputed or pending
// settlement, immediately releasing the locked ugnot back to the pass balance.
func RefundDisputedSettlement(cur realm, settlementID uint64) {
	if !cur.IsCurrent() {
		panic("tollgate: spoofed realm capability")
	}
	st := getSettlementRecord(settlementID)
	if st == nil {
		panic("tollgate: settlement not found")
	}
	if st.status != StatusDisputed && st.status != StatusPending {
		panic("tollgate: settlement cannot be refunded")
	}
	svc := getServiceRecord(st.serviceID)
	if cur.Previous().Address() != svc.owner {
		panic("tollgate: only service owner may refund settlement")
	}
	p := getPassRecord(st.passID)
	p.pendingUgnot -= st.netUgnot
	st.status = StatusRefunded

	chain.Emit(
		"SettlementRefunded",
		"settlement_id", strconv.FormatUint(settlementID, 10),
		"pass_id", strconv.FormatUint(st.passID, 10),
		"amount_ugnot", strconv.FormatInt(st.netUgnot, 10),
	)
}

// ReclaimDisputedSettlement (P0 #2) lets the buyer unconditionally unlock funds
// from a disputed settlement if the provider does not refund within one additional
// challenge window (st.challengeEnd + svc.challengeBlocks), preventing pass lockup.
func ReclaimDisputedSettlement(cur realm, settlementID uint64) {
	if !cur.IsCurrent() {
		panic("tollgate: spoofed realm capability")
	}
	st := getSettlementRecord(settlementID)
	if st == nil {
		panic("tollgate: settlement not found")
	}
	if st.status != StatusDisputed {
		panic("tollgate: settlement is not disputed")
	}
	if cur.Previous().Address() != st.buyer {
		panic("tollgate: only buyer may reclaim disputed settlement")
	}
	svc := getServiceRecord(st.serviceID)
	if runtime.ChainHeight() < st.challengeEnd+svc.challengeBlocks {
		panic("tollgate: provider response window still active")
	}
	p := getPassRecord(st.passID)
	p.pendingUgnot -= st.netUgnot
	st.status = StatusRefunded

	chain.Emit(
		"SettlementReclaimed",
		"settlement_id", strconv.FormatUint(settlementID, 10),
		"pass_id", strconv.FormatUint(st.passID, 10),
		"amount_ugnot", strconv.FormatInt(st.netUgnot, 10),
	)
}

// FinalizeSettlement releases an undisputed settlement's locked ugnot to the
// service payTo address once the challenge window has passed.
func FinalizeSettlement(cur realm, settlementID uint64) {
	if !cur.IsCurrent() {
		panic("tollgate: spoofed realm capability")
	}
	st := getSettlementRecord(settlementID)
	if st == nil {
		panic("tollgate: settlement not found")
	}
	if st.status != StatusPending {
		panic("tollgate: settlement is not pending")
	}
	if runtime.ChainHeight() < st.challengeEnd {
		panic("tollgate: challenge window still active")
	}

	p := getPassRecord(st.passID)
	svc := getServiceRecord(st.serviceID)

	p.pendingUgnot -= st.netUgnot
	p.spentUgnot += st.netUgnot
	p.settledCalls = satAdd(p.settledCalls, st.units)
	svc.totalCalls = satAdd(svc.totalCalls, st.units)
	svc.escrowedRevenue = satAdd(svc.escrowedRevenue, st.netUgnot)
	totalSettledUgnot = satAdd(totalSettledUgnot, st.netUgnot)
	st.status = StatusFinalized

	b := banker.NewBanker(banker.BankerTypeRealmSend, cur)
	b.SendCoins(cur.Address(), svc.payTo, chain.NewCoins(chain.NewCoin("ugnot", st.netUgnot)))

	chain.Emit(
		"SettlementFinalized",
		"settlement_id", strconv.FormatUint(settlementID, 10),
		"pay_to", svc.payTo.String(),
		"net_ugnot", strconv.FormatInt(st.netUgnot, 10),
	)
}

// RecordX402Receipt anchors an external gnolang/x402 direct bank-send HTTP 402
// settlement on chain (provider-attested, tracked separately from escrowed TVL).
func RecordX402Receipt(
	cur realm,
	serviceID uint64,
	buyer address,
	units int64,
	amountUgnot int64,
	nonce string,
	resourceHash string,
	txHash string,
) uint64 {
	if !cur.IsCurrent() {
		panic("tollgate: spoofed realm capability")
	}
	svc := getServiceRecord(serviceID)
	if svc == nil {
		panic("tollgate: service not found")
	}
	if cur.Previous().Address() != svc.owner {
		panic("tollgate: only service owner may anchor x402 receipts")
	}
	if !buyer.IsValid() {
		panic("tollgate: invalid buyer address")
	}
	// P0 #4: Bound units & amountUgnot to prevent telemetry overflow vandalism.
	if units <= 0 || units > maxUnitsPerTx || amountUgnot <= 0 || amountUgnot > maxAmountPerTx {
		panic("tollgate: units or amountUgnot out of bounds")
	}
	if !ptollgate.ValidateNonce(nonce) {
		panic("tollgate: invalid nonce")
	}
	if !ptollgate.IsValidHexDigest(resourceHash) {
		panic("tollgate: invalid resourceHash")
	}
	txHash = strings.TrimSpace(sanitize.StripBidiAndZeroWidth(txHash))
	if len(txHash) < 8 || len(txHash) > 128 {
		panic("tollgate: invalid txHash")
	}
	nk := nonceKey(serviceID, nonce)
	if nonceUsed.Has(nk) {
		panic("tollgate: duplicate nonce")
	}

	commitment := ptollgate.ReceiptCommitment(
		runtime.ChainID(),
		svc.id,
		0,
		buyer.String(),
		svc.payTo.String(),
		units,
		amountUgnot,
		nonce,
		resourceHash,
	)

	rid := nextReceiptID.Next()
	r := &receiptRecord{
		id:           uint64(rid),
		rail:         RailX402Direct,
		serviceID:    svc.id,
		buyer:        buyer,
		provider:     svc.payTo,
		units:        units,
		amountUgnot:  amountUgnot,
		nonce:        nonce,
		resourceHash: resourceHash,
		commitment:   commitment,
		txHash:       txHash,
		height:       runtime.ChainHeight(),
	}
	receipts.Set(rid.Binary(), r)
	receiptHashIndex.Set(commitment, r.id)
	nonceUsed.Set(nk, r.id)
	svc.totalCalls = satAdd(svc.totalCalls, units)
	svc.x402AttestedRevenue = satAdd(svc.x402AttestedRevenue, amountUgnot)
	totalX402AnchoredUgnot = satAdd(totalX402AnchoredUgnot, amountUgnot)

	chain.Emit(
		"X402ReceiptAnchored",
		"receipt_id", strconv.FormatUint(r.id, 10),
		"service_id", strconv.FormatUint(serviceID, 10),
		"buyer", buyer.String(),
		"amount_ugnot", strconv.FormatInt(amountUgnot, 10),
		"tx_hash", txHash,
		"commitment", commitment,
	)
	return r.id
}

// --- Read-only query surface (value copies only, zero mutable pointers) ---

func GetService(serviceID uint64) (ServiceView, bool) {
	svc := getServiceRecord(serviceID)
	if svc == nil {
		return ServiceView{}, false
	}
	return ServiceView{
		ID:                  svc.id,
		Slug:                svc.slug,
		Name:                svc.name,
		Description:         svc.description,
		EndpointURL:         svc.endpointURL,
		Owner:               svc.owner,
		PayTo:               svc.payTo,
		UnitPriceUgnot:      svc.unitPriceUgnot,
		SubPriceUgnot:       svc.subPriceUgnot,
		SubBlocks:           svc.subBlocks,
		SubQuota:            svc.subQuota,
		ChallengeBlocks:     svc.challengeBlocks,
		Paused:              svc.paused,
		CreatedHeight:       svc.createdHeight,
		TotalCalls:          svc.totalCalls,
		EscrowedRevenue:     svc.escrowedRevenue,
		X402AttestedRevenue: svc.x402AttestedRevenue,
	}, true
}

func GetServiceBySlug(slug string) (ServiceView, bool) {
	v := slugIndex.Get(slug)
	if v == nil {
		return ServiceView{}, false
	}
	return GetService(v.(uint64))
}

func GetPass(passID uint64) (PassView, bool) {
	p := getPassRecord(passID)
	if p == nil {
		return PassView{}, false
	}
	avail, _ := ptollgate.ComputeAvailable(p.depositUgnot, p.spentUgnot, p.pendingUgnot)
	return PassView{
		ID:              p.id,
		ServiceID:       p.serviceID,
		Buyer:           p.buyer,
		DepositUgnot:    p.depositUgnot,
		SpentUgnot:      p.spentUgnot,
		PendingUgnot:    p.pendingUgnot,
		AvailableUgnot:  avail,
		MaxPerCallUgnot: p.maxPerCallUgnot,
		ExpiryHeight:    p.expiryHeight,
		OpenedHeight:    p.openedHeight,
		Closed:          p.closed,
		UsedSessionKey:  p.usedSessionKey,
		SessionKeyAddr:  p.sessionKeyAddr,
		VoucherPubKey:   p.voucherPubKey,
		SettledCalls:    p.settledCalls,
	}, true
}

func GetSubscription(subID uint64) (SubscriptionView, bool) {
	s := getSubRecord(subID)
	if s == nil {
		return SubscriptionView{}, false
	}
	rem := s.quotaTotal - s.quotaUsed
	active := runtime.ChainHeight() <= s.expiryHeight && rem > 0
	return SubscriptionView{
		ID:             s.id,
		ServiceID:      s.serviceID,
		Buyer:          s.buyer,
		PaidUgnot:      s.paidUgnot,
		QuotaTotal:     s.quotaTotal,
		QuotaUsed:      s.quotaUsed,
		QuotaRemaining: rem,
		StartHeight:    s.startHeight,
		ExpiryHeight:   s.expiryHeight,
		Active:         active,
		VoucherPubKey:  s.voucherPubKey,
	}, true
}

func GetSettlement(settlementID uint64) (SettlementView, bool) {
	st := getSettlementRecord(settlementID)
	if st == nil {
		return SettlementView{}, false
	}
	return SettlementView{
		ID:            st.id,
		ServiceID:     st.serviceID,
		PassID:        st.passID,
		Buyer:         st.buyer,
		Provider:      st.provider,
		Units:         st.units,
		GrossUgnot:    st.grossUgnot,
		DiscountBps:   st.discountBps,
		NetUgnot:      st.netUgnot,
		Nonce:         st.nonce,
		ResourceHash:  st.resourceHash,
		Commitment:    st.commitment,
		ClaimedHeight: st.claimedHeight,
		ChallengeEnd:  st.challengeEnd,
		Status:        st.status,
		DisputeReason: st.disputeReason,
		ReceiptID:     st.receiptID,
		BuyerSigned:   st.buyerSigned,
	}, true
}

func receiptSettlementStatus(r *receiptRecord) string {
	if r.settlementID > 0 {
		if st := getSettlementRecord(r.settlementID); st != nil {
			return st.status
		}
	}
	if r.rail == RailX402Direct {
		return "provider-attested"
	}
	return "recorded"
}

func GetReceipt(receiptID uint64) (ReceiptView, bool) {
	r := getReceiptRecord(receiptID)
	if r == nil {
		return ReceiptView{}, false
	}
	return ReceiptView{
		ID:               r.id,
		Rail:             r.rail,
		ServiceID:        r.serviceID,
		PassID:           r.passID,
		SubID:            r.subID,
		SettlementID:     r.settlementID,
		SettlementStatus: receiptSettlementStatus(r),
		Buyer:            r.buyer,
		Provider:         r.provider,
		Units:            r.units,
		AmountUgnot:      r.amountUgnot,
		Nonce:            r.nonce,
		ResourceHash:     r.resourceHash,
		Commitment:       r.commitment,
		TxHash:           r.txHash,
		Height:           r.height,
		BuyerSigned:      r.buyerSigned,
	}, true
}

// VerifyReceiptByCommitment checks whether a canonical SHA-256 receipt digest
// is anchored on chain AND has NOT been refunded/invalidated by a dispute.
func VerifyReceiptByCommitment(commitmentHex string) (uint64, bool) {
	if !ptollgate.IsValidHexDigest(commitmentHex) {
		return 0, false
	}
	v := receiptHashIndex.Get(commitmentHex)
	if v == nil {
		return 0, false
	}
	rid := v.(uint64)
	r := getReceiptRecord(rid)
	if r == nil {
		return 0, false
	}
	if receiptSettlementStatus(r) == StatusRefunded {
		return rid, false
	}
	return rid, true
}

// CheckPassQuota is a fast read-only helper for HTTP gateways (via vm/qeval).
func CheckPassQuota(passID uint64, units int64) bool {
	p := getPassRecord(passID)
	if p == nil || p.closed || units <= 0 || units > maxUnitsPerTx {
		return false
	}
	if runtime.ChainHeight() >= p.expiryHeight {
		return false
	}
	svc := getServiceRecord(p.serviceID)
	if svc == nil || svc.paused {
		return false
	}
	charge, err := ptollgate.ComputeCharge(svc.unitPriceUgnot, units)
	if err != nil {
		return false
	}
	if p.maxPerCallUgnot <= maxInt64/units && charge.NetUgnot > p.maxPerCallUgnot*units {
		return false
	}
	avail, err := ptollgate.ComputeAvailable(p.depositUgnot, p.spentUgnot, p.pendingUgnot)
	if err != nil {
		return false
	}
	return avail >= charge.NetUgnot
}

// CheckSubscriptionActive verifies via vm/qeval whether a subscription has
// remaining quota and has not expired (overflow-safe).
func CheckSubscriptionActive(subID uint64, units int64) bool {
	s := getSubRecord(subID)
	if s == nil || units <= 0 || units > maxUnitsPerTx {
		return false
	}
	if runtime.ChainHeight() > s.expiryHeight {
		return false
	}
	return units <= s.quotaTotal-s.quotaUsed
}

// VaultBalanceUgnot returns the live ugnot locked in this realm using O(1) GetCoin.
func VaultBalanceUgnot() int64 {
	pkgAddr := chain.PackageAddress("gno.land/r/g1zt8w45ecxhlsdse7hd5gwr6xzcaxy9zsej6hl2/tollgate/v2")
	return banker.NewReadonlyBanker().GetCoin(pkgAddr, "ugnot")
}
