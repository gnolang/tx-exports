// Package whisper is the stateful Gno.land realm for Arobi Whisper — an end-to-end
// encrypted DeFi messenger with tiered subscriptions paid in GNOT (mirroring
// aura-genesis.org/whisper: Free 110 credits vs Pro 2,500 credits / 30 days),
// pay-per-message overage, native GNOT tipping, conditional HTLC/expiry escrows,
// programmable anti-spam inbox gating, and RFC 6962 cryptographic evidence proofs
// built directly on gno.land/p/g1jkstuy23a8e44jvdjajc5gjjry9vwevmkvmdak/assurance/v2.
//
// Zero plaintext or secret keys ever touch chain state. Clients seal messages locally
// using X25519 + HKDF-SHA256 + XChaCha20-Poly1305 (exact Arobi Whisper v1 wire format).
// Note: on a public chain, sender/recipient addresses, timestamps, tips, escrow amounts,
// and realm state (including operator/settlement sink) are publicly observable metadata;
// E2EE protects message plaintext only.
//
// Settlement: subscription and protocol fees are enforced on-chain in GNOT. The deployer
// becomes operator atomically inside init() during deployment (no post-deploy claim race).
// No payout address is hardcoded, printed in Render, or emitted in events.
package whisper

import (
	"chain"
	"chain/banker"
	"chain/runtime"
	"chain/runtime/unsafe"
	"strconv"
	"strings"

	"gno.land/p/g1jkstuy23a8e44jvdjajc5gjjry9vwevmkvmdak/assurance/v2"
	pw "gno.land/p/g1jkstuy23a8e44jvdjajc5gjjry9vwevmkvmdak/whisper/v2"
	"gno.land/p/nt/avl/v0"
)

const (
	denom = "ugnot"

	// Tier quotas mirroring live Arobi Whisper (aura-genesis.org/whisper).
	TierFree = "free"
	TierPro  = "pro"

	FreePeriodCredits int64 = 110
	ProPeriodCredits  int64 = 2500
	FreeMaxCipherB64  int   = 4096  // 4 KiB base64 on Free tier
	ProMaxCipherB64   int   = 16384 // 16 KiB base64 on Pro tier

	// ~30 days at ~2s/block.
	SubscriptionPeriodBlocks int64 = 1296000

	// Escrow safety bounds.
	MinEscrowUgnot     int64 = 1000
	MinEscrowTTLBlocks int64 = 5
	MaxEscrowTTLBlocks int64 = 15000000
	MaxEscrowFeeBps    int64 = 500 // hard protocol cap: never > 5%
)

// Identity binds a native Gno g1... address to local X25519/Ed25519 messaging keys,
// an optional claim-once @handle, subscription tier & credits, and anti-spam rules.
type Identity struct {
	Address          address
	EncPubHex        string // 32-byte X25519 public key (hex)
	SignPubHex       string // 32-byte Ed25519 public key (hex, optional cross-chain parity)
	Handle           string // optional claim-once handle
	DisplayName      string
	Tier             string // TierFree or TierPro
	Credits          int64
	SubExpiresHeight int64
	MinTipUgnot      int64
	AllowListOnly    bool
	Allowed          *avl.Tree // senderAddr -> bool
	Inbox            *avl.Tree // seqKey(n) -> message id, the n-th message received
	InboxCount       uint64
	Sent             *avl.Tree // seqKey(n) -> message id, the n-th message sent
	SentCount        uint64
	CreatedHeight    int64
	UpdatedHeight    int64
}

var (
	// Service pricing in ugnot (configurable by operator; zero hardcoded payout wallets).
	subscriptionPriceUgnot int64 = 25000000 // 25 GNOT per 30-day Pro period
	overageFeeUgnot        int64 = 10000    // 0.01 GNOT pay-per-message when credits == 0
	escrowFeeBps           int64 = 100      // 1.00% settlement fee on claimed DeFi escrows

	// Operator and settlement sink. Render and events do not print them; on a public chain
	// realm state and bank transfers remain publicly inspectable. deployer is bound once in init().
	deployer           address
	operator           address
	settlementSink     address
	accruedServiceFees int64

	// Storage whose gas per send stays flat as history grows: trees and counters, never a slice
	// appended to on every call (a slice's backing array is loaded and saved in full each time).
	identities    = avl.NewTree() // addr.String() -> *Identity
	handles       = avl.NewTree() // handle -> addr.String()
	identityCount uint64          // identities ever registered
	identitySeq   = avl.NewTree() // seqKey(n) -> addr.String(), in registration order

	messages     = avl.NewTree() // seqKey(id) -> *pw.SealedEnvelope
	messageCount uint64
	escrows      = avl.NewTree() // seqKey(id) -> *pw.EscrowRecord
	escrowCount  uint64

	// Append-only RFC 6962 accumulator over every message envelope & escrow transition.
	evidenceAcc   assurance.LedgerAccumulator // grows with every message across transactions: leaves in a tree
	totalTips     int64
	totalEscrowed int64
)

// ── Operator & Settlement Configuration ──────────────────────────────────────

// init binds the deploying account as deployer and operator atomically inside the
// deployment transaction itself, closing any post-deploy operator front-running window.
func init() {
	initOperatorFromDeployment()
}

func initOperatorFromDeployment() {
	deployer = unsafe.OriginCaller()
	operator = deployer
}

// Operator returns the current operator address.
func Operator() address { return operator }

// TransferOperator transfers operator control to a new address (operator only).
func TransferOperator(cur realm, next address) {
	mustOperator(cur)
	if !next.IsValid() {
		panic("invalid operator address")
	}
	operator = next
}

// SetSettlementSink privately sets an optional direct settlement sink for service fees
// (operator only; never exposed in Render() or public chain events).
func SetSettlementSink(cur realm, sink address) {
	mustOperator(cur)
	if sink != "" && !sink.IsValid() {
		panic("invalid settlement address")
	}
	settlementSink = sink
}

// SetPricing updates GNOT service pricing (operator only; escrowFeeBps capped at 5%).
func SetPricing(cur realm, subPriceUgnot, overageUgnot, escFeeBps int64) {
	mustOperator(cur)
	if subPriceUgnot < 0 || overageUgnot < 0 {
		panic("prices cannot be negative")
	}
	if escFeeBps < 0 || escFeeBps > MaxEscrowFeeBps {
		panic("escrowFeeBps out of range (0..500)")
	}
	subscriptionPriceUgnot = subPriceUgnot
	overageFeeUgnot = overageUgnot
	escrowFeeBps = escFeeBps
}

// CollectServiceFees withdraws ONLY accrued service fees (subscriptions, overages,
// settled escrow fees) to an operator-specified destination. Strictly isolated from
// user-locked DeFi escrows.
func CollectServiceFees(cur realm, to address) int64 {
	mustOperator(cur)
	if !to.IsValid() {
		panic("invalid destination address")
	}
	amount := accruedServiceFees
	if amount <= 0 {
		return 0
	}
	accruedServiceFees = 0
	bk := banker.NewBanker(banker.BankerTypeRealmSend, cur)
	bk.SendCoins(cur.Address(), to, chain.Coins{chain.NewCoin(denom, amount)})
	return amount
}

// ── Public Pricing Queries (no payout addresses exposed) ─────────────────────

func SubscriptionPriceUgnot() int64 { return subscriptionPriceUgnot }
func OverageFeeUgnot() int64        { return overageFeeUgnot }
func EscrowFeeBps() int64           { return escrowFeeBps }

// ── Identity, Tier & Subscription Lifecycle ──────────────────────────────────

// RegisterIdentity registers (or updates displayName/keys for) the caller's E2EE identity.
// New accounts start on the Free tier (110 credits) matching aura-genesis.org/whisper.
// Handles are strictly claim-once: once claimed, a handle cannot be changed or stolen.
func RegisterIdentity(cur realm, encPubHex, signPubHex, handle, displayName string) {
	prev := cur.Previous()
	if !prev.IsUserCall() {
		panic("register identity with a direct user call")
	}
	if err := pw.ValidateKeyHex(encPubHex); err != nil {
		panic("encPubHex: " + err.Error())
	}
	if signPubHex != "" {
		if err := pw.ValidateKeyHex(signPubHex); err != nil {
			panic("signPubHex: " + err.Error())
		}
	}
	if len(displayName) > 64 {
		panic("displayName too long (max 64)")
	}

	caller := prev.Address()
	key := caller.String()
	height := runtime.ChainHeight()

	var normHandle string
	if strings.TrimSpace(handle) != "" {
		var err error
		normHandle, err = pw.NormalizeHandle(handle)
		if err != nil {
			panic("handle: " + err.Error())
		}
	}

	if id, exists := identities.Get(key).(*Identity); exists && id != nil {
		if normHandle != "" {
			if id.Handle != "" && id.Handle != normHandle {
				panic("identity already owns @" + id.Handle + "; handles cannot be reassigned")
			}
			if id.Handle == "" {
				if handles.Has(normHandle) {
					panic("handle @" + normHandle + " is already taken")
				}
				handles.Set(normHandle, key)
				id.Handle = normHandle
			}
		}
		id.EncPubHex = encPubHex
		if signPubHex != "" {
			id.SignPubHex = signPubHex
		}
		if displayName != "" {
			id.DisplayName = displayName
		}
		id.UpdatedHeight = height
		chain.Emit("WhisperIdentityUpdated", "addr", key, "handle", id.Handle, "enc_pub", encPubHex)
		return
	}

	if normHandle != "" {
		if handles.Has(normHandle) {
			panic("handle @" + normHandle + " is already taken")
		}
		handles.Set(normHandle, key)
	}

	id := &Identity{
		Address:       caller,
		EncPubHex:     encPubHex,
		SignPubHex:    signPubHex,
		Handle:        normHandle,
		DisplayName:   displayName,
		Tier:          TierFree,
		Credits:       FreePeriodCredits,
		Allowed:       avl.NewTree(),
		Inbox:         avl.NewTree(),
		Sent:          avl.NewTree(),
		CreatedHeight: height,
		UpdatedHeight: height,
	}
	identities.Set(key, id)
	identityCount++
	identitySeq.Set(seqKey(identityCount), key)

	chain.Emit("WhisperIdentityRegistered",
		"addr", key,
		"handle", normHandle,
		"tier", TierFree,
		"credits", strconv.FormatInt(FreePeriodCredits, 10),
		"enc_pub", encPubHex,
		"height", strconv.FormatInt(height, 10),
	)
}

// Subscribe upgrades or extends the caller's Whisper identity to the Pro tier for 30 days
// (2,500 credits, 16 KiB envelopes, and DeFi HTLC escrows) by paying exact SubscriptionPriceUgnot in GNOT.
func Subscribe(cur realm) int64 {
	prev := cur.Previous()
	if !prev.IsUserCall() {
		panic("subscribe with a direct user call")
	}
	id := mustIdentity(prev.Address().String())
	paid := sentUgnot()
	if paid != subscriptionPriceUgnot {
		panic("send exact subscription price " + strconv.FormatInt(subscriptionPriceUgnot, 10) + denom +
			"; got " + strconv.FormatInt(paid, 10) + denom)
	}

	height := runtime.ChainHeight()
	baseExpiry := height
	if id.SubExpiresHeight > height {
		baseExpiry = id.SubExpiresHeight
	}
	id.Tier = TierPro
	id.SubExpiresHeight = baseExpiry + SubscriptionPeriodBlocks
	id.Credits = ProPeriodCredits
	id.UpdatedHeight = height

	settleServiceFee(cur, paid)

	chain.Emit("WhisperSubscribed",
		"addr", id.Address.String(),
		"tier", TierPro,
		"paid_ugnot", strconv.FormatInt(paid, 10),
		"credits", strconv.FormatInt(id.Credits, 10),
		"expires_height", strconv.FormatInt(id.SubExpiresHeight, 10),
	)
	return id.SubExpiresHeight
}

// EffectiveTier returns TierPro if the identity has an active subscription, else TierFree.
func EffectiveTier(addrOrHandle string) string {
	id := mustResolveIdentity(addrOrHandle)
	return effectiveTierOf(id, runtime.ChainHeight())
}

// RotateKeys rotates the caller's X25519 / Ed25519 keys without losing handle, subscription, or inbox history.
func RotateKeys(cur realm, newEncPubHex, newSignPubHex string) {
	prev := cur.Previous()
	if !prev.IsUserCall() {
		panic("rotate keys with a direct user call")
	}
	if err := pw.ValidateKeyHex(newEncPubHex); err != nil {
		panic("newEncPubHex: " + err.Error())
	}
	if newSignPubHex != "" {
		if err := pw.ValidateKeyHex(newSignPubHex); err != nil {
			panic("newSignPubHex: " + err.Error())
		}
	}
	id := mustIdentity(prev.Address().String())
	id.EncPubHex = newEncPubHex
	id.SignPubHex = newSignPubHex
	id.UpdatedHeight = runtime.ChainHeight()
	chain.Emit("WhisperKeysRotated", "addr", id.Address.String(), "enc_pub", newEncPubHex)
}

// SetInboxPolicy configures programmable DeFi anti-spam rules on the caller's inbox.
func SetInboxPolicy(cur realm, minTipUgnot int64, allowListOnly bool) {
	prev := cur.Previous()
	if !prev.IsUserCall() {
		panic("set inbox policy with a direct user call")
	}
	if minTipUgnot < 0 {
		panic("minTipUgnot cannot be negative")
	}
	id := mustIdentity(prev.Address().String())
	id.MinTipUgnot = minTipUgnot
	id.AllowListOnly = allowListOnly
	id.UpdatedHeight = runtime.ChainHeight()
	chain.Emit("WhisperInboxPolicy",
		"addr", id.Address.String(),
		"min_tip_ugnot", strconv.FormatInt(minTipUgnot, 10),
		"allowlist_only", strconv.FormatBool(allowListOnly),
	)
}

// SetAllowedSender adds or removes a sender address from the caller's inbox allowlist.
func SetAllowedSender(cur realm, senderAddr string, allowed bool) {
	prev := cur.Previous()
	if !prev.IsUserCall() {
		panic("set allowed sender with a direct user call")
	}
	id := mustIdentity(prev.Address().String())
	if allowed {
		id.Allowed.Set(senderAddr, true)
	} else {
		id.Allowed.Remove(senderAddr)
	}
	id.UpdatedHeight = runtime.ChainHeight()
}

// ── E2EE Messaging + GNOT Tipping & Tier Metering ────────────────────────────

// SendMessage delivers a client-sealed E2EE ciphertext envelope on-chain.
// Consumes 1 message credit from the sender's tier quota; if credits are exhausted,
// collects OverageFeeUgnot in GNOT automatically. Any remaining attached GNOT
// (required >= recipient.MinTipUgnot) forwards 100% straight to recipient.
func SendMessage(
	cur realm,
	toAddrOrHandle string,
	ephemeralPubHex string,
	nonceHex string,
	ciphertextB64 string,
	commitmentHex string,
) uint64 {
	prev := cur.Previous()
	if !prev.IsUserCall() {
		panic("send message with a direct user call")
	}
	sender := mustIdentity(prev.Address().String())
	recipient := mustResolveIdentity(toAddrOrHandle)
	checkCanSend(sender, recipient)
	validateEnvelopeFields(ephemeralPubHex, nonceHex, ciphertextB64, commitmentHex)

	height := runtime.ChainHeight()
	tier := effectiveTierOf(sender, height)
	maxCT := FreeMaxCipherB64
	if tier == TierPro {
		maxCT = ProMaxCipherB64
	}
	if len(ciphertextB64) > maxCT {
		panic("ciphertext exceeds " + tier + " tier payload limit (" + strconv.Itoa(maxCT) + " chars); subscribe to Pro for 16 KiB")
	}

	sent := sentUgnot()
	var serviceFee int64
	if sender.Credits > 0 {
		sender.Credits--
	} else {
		if sent < overageFeeUgnot {
			panic("message credits exhausted: subscribe to Pro or attach at least " +
				strconv.FormatInt(overageFeeUgnot, 10) + denom + " overage fee")
		}
		serviceFee = overageFeeUgnot
	}

	tip := sent - serviceFee
	if tip < recipient.MinTipUgnot {
		panic("recipient requires minimum tip of " + strconv.FormatInt(recipient.MinTipUgnot, 10) + denom +
			"; got " + strconv.FormatInt(tip, 10) + denom + " after service fee")
	}

	msgID := messageCount + 1
	env := &pw.SealedEnvelope{
		ID:              msgID,
		ChainID:         runtime.ChainID(),
		Realm:           cur.PkgPath(),
		From:            sender.Address.String(),
		To:              recipient.Address.String(),
		EphemeralPubHex: ephemeralPubHex,
		NonceHex:        nonceHex,
		CiphertextB64:   ciphertextB64,
		CommitmentHex:   commitmentHex,
		TipUgnot:        tip,
		EscrowID:        0,
		Height:          height,
	}
	leaf := env.LeafHash()
	env.LeafIndex = evidenceAcc.Append(leaf)
	recordMessage(env, sender, recipient)

	if serviceFee > 0 {
		settleServiceFee(cur, serviceFee)
	}
	if tip > 0 {
		totalTips += tip
		bk := banker.NewBanker(banker.BankerTypeRealmSend, cur)
		bk.SendCoins(cur.Address(), recipient.Address, chain.Coins{chain.NewCoin(denom, tip)})
	}

	chain.Emit("WhisperMessage",
		"id", strconv.FormatUint(msgID, 10),
		"from", env.From,
		"to", env.To,
		"tier", tier,
		"commitment", commitmentHex,
		"tip_ugnot", strconv.FormatInt(tip, 10),
		"service_fee_ugnot", strconv.FormatInt(serviceFee, 10),
		"leaf_index", strconv.FormatUint(env.LeafIndex, 10),
		"acc_root", assurance.Hex(evidenceAcc.Root()),
	)
	return msgID
}

// ── DeFi Encrypted Conditional Escrows (Pro Tier + 1% Settlement Fee) ────────

// SendEscrowMessage sends an E2EE ciphertext envelope paired with a locked DeFi GNOT escrow.
// Requires an active Pro subscription (matching Whisper's paid tier for advanced DeFi flows).
func SendEscrowMessage(
	cur realm,
	toAddrOrHandle string,
	ephemeralPubHex string,
	nonceHex string,
	ciphertextB64 string,
	commitmentHex string,
	hashLockHex string,
	ttlBlocks int64,
) (uint64, uint64) {
	prev := cur.Previous()
	if !prev.IsUserCall() {
		panic("send escrow message with a direct user call")
	}
	sender := mustIdentity(prev.Address().String())
	height := runtime.ChainHeight()
	if effectiveTierOf(sender, height) != TierPro {
		panic("DeFi encrypted escrows require an active Pro subscription (call Subscribe with " +
			strconv.FormatInt(subscriptionPriceUgnot, 10) + denom + ")")
	}
	recipient := mustResolveIdentity(toAddrOrHandle)
	if sender.Address == recipient.Address {
		panic("cannot create escrow to self")
	}
	checkCanSend(sender, recipient)
	validateEnvelopeFields(ephemeralPubHex, nonceHex, ciphertextB64, commitmentHex)

	if hashLockHex != "" {
		if _, err := assurance.ParseDigest(hashLockHex); err != nil {
			panic("hashLockHex: " + err.Error())
		}
	}
	if ttlBlocks < MinEscrowTTLBlocks || ttlBlocks > MaxEscrowTTLBlocks {
		panic("ttlBlocks out of allowed range")
	}

	amount := sentUgnot()
	escrowAmount := amount
	if sender.Credits > 0 {
		sender.Credits--
	} else if overageFeeUgnot > 0 {
		if amount < MinEscrowUgnot+overageFeeUgnot {
			panic("out of credits: escrow send must cover overage fee (" + strconv.FormatInt(overageFeeUgnot, 10) + denom + ") plus min escrow")
		}
		settleServiceFee(cur, overageFeeUgnot)
		escrowAmount = amount - overageFeeUgnot
	}
	if escrowAmount < MinEscrowUgnot {
		panic("escrow requires at least " + strconv.FormatInt(MinEscrowUgnot, 10) + denom)
	}
	if escrowAmount < recipient.MinTipUgnot {
		panic("escrow amount below recipient min tip")
	}

	msgID := messageCount + 1
	escID := escrowCount + 1

	env := &pw.SealedEnvelope{
		ID:              msgID,
		ChainID:         runtime.ChainID(),
		Realm:           cur.PkgPath(),
		From:            sender.Address.String(),
		To:              recipient.Address.String(),
		EphemeralPubHex: ephemeralPubHex,
		NonceHex:        nonceHex,
		CiphertextB64:   ciphertextB64,
		CommitmentHex:   commitmentHex,
		TipUgnot:        0,
		EscrowID:        escID,
		Height:          height,
	}
	env.LeafIndex = evidenceAcc.Append(env.LeafHash())
	recordMessage(env, sender, recipient)

	esc := &pw.EscrowRecord{
		ID:            escID,
		MessageID:     msgID,
		Sender:        sender.Address.String(),
		Recipient:     recipient.Address.String(),
		AmountUgnot:   escrowAmount,
		FeeBps:        escrowFeeBps, // locked at creation; later SetPricing never changes open escrows
		HashLockHex:   hashLockHex,
		ExpiryHeight:  height + ttlBlocks,
		Status:        pw.EscrowOpen,
		CreatedHeight: height,
	}
	escLeafIdx := evidenceAcc.Append(esc.LeafHash())
	escrows.Set(seqKey(escID), esc)
	escrowCount = escID
	totalEscrowed += escrowAmount

	chain.Emit("WhisperEscrowCreated",
		"escrow_id", strconv.FormatUint(escID, 10),
		"msg_id", strconv.FormatUint(msgID, 10),
		"from", esc.Sender,
		"to", esc.Recipient,
		"amount_ugnot", strconv.FormatInt(escrowAmount, 10),
		"fee_bps", strconv.FormatInt(esc.FeeBps, 10),
		"hash_lock", hashLockHex,
		"expiry_height", strconv.FormatInt(esc.ExpiryHeight, 10),
		"leaf_index", strconv.FormatUint(escLeafIdx, 10),
		"acc_root", assurance.Hex(evidenceAcc.Root()),
	)
	return msgID, escID
}

// ClaimEscrow settles an open DeFi escrow to its recipient (verifying preimage if hash-locked),
// strictly before ExpiryHeight so HTLC timeout guarantees never race with RefundEscrow.
// Collects the FeeBps locked when the escrow was created; remainder forwards to recipient.
func ClaimEscrow(cur realm, escrowID uint64, preimage string) int64 {
	prev := cur.Previous()
	if !prev.IsUserCall() {
		panic("claim escrow with a direct user call")
	}
	esc := mustEscrow(escrowID)
	if esc.Status != pw.EscrowOpen {
		panic("escrow is already " + string(esc.Status))
	}
	if runtime.ChainHeight() >= esc.ExpiryHeight {
		panic("escrow expired at height " + strconv.FormatInt(esc.ExpiryHeight, 10) + "; only the sender may refund it")
	}
	caller := prev.Address()
	if caller.String() != esc.Recipient {
		panic("only recipient " + esc.Recipient + " may claim escrow")
	}
	if esc.HashLockHex != "" {
		if pw.ComputeHashLock(preimage) != esc.HashLockHex {
			panic("invalid hashlock preimage")
		}
	}

	fee := (esc.AmountUgnot * esc.FeeBps) / 10000
	if fee >= esc.AmountUgnot {
		fee = 0
	}
	payout := esc.AmountUgnot - fee

	esc.Status = pw.EscrowClaimed
	esc.SettledHeight = runtime.ChainHeight()

	leafIdx := evidenceAcc.Append(esc.LeafHash())

	bk := banker.NewBanker(banker.BankerTypeRealmSend, cur)
	bk.SendCoins(cur.Address(), caller, chain.Coins{chain.NewCoin(denom, payout)})
	if fee > 0 {
		settleServiceFee(cur, fee)
	}

	chain.Emit("WhisperEscrowClaimed",
		"escrow_id", strconv.FormatUint(esc.ID, 10),
		"recipient", esc.Recipient,
		"payout_ugnot", strconv.FormatInt(payout, 10),
		"service_fee_ugnot", strconv.FormatInt(fee, 10),
		"leaf_index", strconv.FormatUint(leafIdx, 10),
		"acc_root", assurance.Hex(evidenceAcc.Root()),
	)
	return payout
}

// RefundEscrow returns 100% of an expired, unclaimed DeFi escrow back to its sender (zero fee).
func RefundEscrow(cur realm, escrowID uint64) int64 {
	prev := cur.Previous()
	if !prev.IsUserCall() {
		panic("refund escrow with a direct user call")
	}
	esc := mustEscrow(escrowID)
	if esc.Status != pw.EscrowOpen {
		panic("escrow is already " + string(esc.Status))
	}
	caller := prev.Address()
	if caller.String() != esc.Sender {
		panic("only sender " + esc.Sender + " may refund escrow")
	}
	height := runtime.ChainHeight()
	if height < esc.ExpiryHeight {
		panic("escrow has not expired yet; unlocks at height " + strconv.FormatInt(esc.ExpiryHeight, 10))
	}

	esc.Status = pw.EscrowRefunded
	esc.SettledHeight = height
	leafIdx := evidenceAcc.Append(esc.LeafHash())

	bk := banker.NewBanker(banker.BankerTypeRealmSend, cur)
	bk.SendCoins(cur.Address(), caller, chain.Coins{chain.NewCoin(denom, esc.AmountUgnot)})

	chain.Emit("WhisperEscrowRefunded",
		"escrow_id", strconv.FormatUint(esc.ID, 10),
		"sender", esc.Sender,
		"refund_ugnot", strconv.FormatInt(esc.AmountUgnot, 10),
		"leaf_index", strconv.FormatUint(leafIdx, 10),
		"acc_root", assurance.Hex(evidenceAcc.Root()),
	)
	return esc.AmountUgnot
}

// ── Public Read & Proof Queries ──────────────────────────────────────────────

// ResolveRecipient returns the public directory record for an address or @handle.
func ResolveRecipient(addrOrHandle string) string {
	id := mustResolveIdentity(addrOrHandle)
	tier := effectiveTierOf(id, runtime.ChainHeight())
	return id.Address.String() + "|" + id.EncPubHex + "|" + id.Handle + "|" + tier + "|" +
		strconv.FormatInt(id.MinTipUgnot, 10) + "|" + strconv.FormatBool(id.AllowListOnly)
}

func Root() string            { return assurance.Hex(evidenceAcc.Root()) }
func AccumulatorSize() uint64 { return evidenceAcc.Size() }
func MessageCount() uint64    { return messageCount }
func EscrowCount() uint64     { return escrowCount }

func MessageLeafHex(msgID uint64) string {
	if msgID == 0 || msgID > messageCount {
		panic("no message " + strconv.FormatUint(msgID, 10))
	}
	return assurance.Hex(messages.Get(seqKey(msgID)).(*pw.SealedEnvelope).LeafHash())
}

func ProofForLeaf(leafIndex, treeSize uint64) string {
	proof, err := evidenceAcc.Proof(leafIndex, treeSize)
	if err != nil {
		panic(err.Error())
	}
	parts := make([]string, len(proof))
	for i, h := range proof {
		parts[i] = assurance.Hex(h)
	}
	return strings.Join(parts, ",")
}

func VerifyLeafProof(leafIndex, treeSize uint64, leafHex, proofCSV string) bool {
	if leafIndex >= treeSize || treeSize > evidenceAcc.Size() {
		return false
	}
	leaf, err := assurance.ParseDigest(leafHex)
	if err != nil {
		return false
	}
	rootAt, err := evidenceAcc.RootAt(treeSize)
	if err != nil {
		return false
	}
	var proof [][32]byte
	if strings.TrimSpace(proofCSV) != "" {
		for _, tok := range strings.Split(proofCSV, ",") {
			d, err := assurance.ParseDigest(strings.TrimSpace(tok))
			if err != nil {
				return false
			}
			proof = append(proof, d)
		}
	}
	return assurance.VerifyInclusion(leafIndex, treeSize, leaf, proof, rootAt)
}

// ── Internal Helpers ─────────────────────────────────────────────────────────

func settleServiceFee(cur realm, amount int64) {
	if amount <= 0 {
		return
	}
	if settlementSink != "" {
		bk := banker.NewBanker(banker.BankerTypeRealmSend, cur)
		bk.SendCoins(cur.Address(), settlementSink, chain.Coins{chain.NewCoin(denom, amount)})
		return
	}
	accruedServiceFees += amount
}

func mustOperator(cur realm) {
	prev := cur.Previous()
	if !prev.IsUserCall() {
		panic("operator action requires a direct user call")
	}
	if operator == "" {
		panic("operator not initialized")
	}
	if prev.Address() != operator {
		panic("unauthorized: operator only")
	}
}

func effectiveTierOf(id *Identity, height int64) string {
	if id.Tier == TierPro && id.SubExpiresHeight > height {
		return TierPro
	}
	return TierFree
}

func mustIdentity(addr string) *Identity {
	id, ok := identities.Get(addr).(*Identity)
	if !ok || id == nil {
		panic("identity not registered for " + addr)
	}
	return id
}

func mustResolveIdentity(addrOrHandle string) *Identity {
	q := strings.TrimSpace(addrOrHandle)
	if id, ok := identities.Get(q).(*Identity); ok && id != nil {
		return id
	}
	clean := strings.ToLower(strings.TrimLeft(q, "@"))
	if targetAddr, ok := handles.Get(clean).(string); ok && targetAddr != "" {
		return mustIdentity(targetAddr)
	}
	panic("recipient not found: " + addrOrHandle)
}

func mustEscrow(id uint64) *pw.EscrowRecord {
	if id == 0 || id > escrowCount {
		panic("escrow not found: " + strconv.FormatUint(id, 10))
	}
	return escrows.Get(seqKey(id)).(*pw.EscrowRecord)
}

// recordMessage stores a sent envelope under its id and in the sender's and recipient's own lists.
func recordMessage(env *pw.SealedEnvelope, sender, recipient *Identity) {
	messages.Set(seqKey(env.ID), env)
	messageCount = env.ID
	recipient.InboxCount++
	recipient.Inbox.Set(seqKey(recipient.InboxCount), env.ID)
	sender.SentCount++
	sender.Sent.Set(seqKey(sender.SentCount), env.ID)
}

// seqKey is a sequence number in fixed-width decimal, so a tree's key order is sequence order.
func seqKey(n uint64) string {
	s := strconv.FormatUint(n, 10)
	return strings.Repeat("0", 20-len(s)) + s
}

func checkCanSend(sender, recipient *Identity) {
	if recipient.AllowListOnly && sender.Address != recipient.Address {
		if !recipient.Allowed.Has(sender.Address.String()) {
			panic("recipient only accepts messages from allowlisted senders")
		}
	}
}

func validateEnvelopeFields(ephemeralPubHex, nonceHex, ciphertextB64, commitmentHex string) {
	if err := pw.ValidateKeyHex(ephemeralPubHex); err != nil {
		panic("ephemeralPubHex: " + err.Error())
	}
	if err := pw.ValidateNonceHex(nonceHex); err != nil {
		panic("nonceHex: " + err.Error())
	}
	if err := pw.ValidateCiphertextB64(ciphertextB64); err != nil {
		panic("ciphertextB64: " + err.Error())
	}
	if _, err := assurance.ParseDigest(commitmentHex); err != nil {
		panic("commitmentHex: " + err.Error())
	}
}

func sentUgnot() int64 {
	var total int64
	for _, c := range unsafe.OriginSend() {
		if c.Amount == 0 {
			continue
		}
		if c.Denom != denom || c.Amount < 0 {
			panic("only " + denom + " is accepted")
		}
		total += c.Amount
	}
	return total
}
