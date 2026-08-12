package ucs03_zkgm

import (
	types "gno.land/p/onbloc/ibc/union/types"

	"gno.land/p/nt/bptree/v0"
	z "gno.land/p/onbloc/ibc/union/zkgm"
	tb "gno.land/p/onbloc/ibc/union/zkgm/tokenbucket"
	u256 "gno.land/p/onbloc/math/uint256"
)

var (
	// store is the proxy-owned singleton holding all persistent domain state. It is
	// the dependency injected into the implementation realm: the impl receives this
	// pointer and mutates state through the SetXXX(_ int, rlm realm, ...) methods,
	// whose trailing realm token carries the caller frame so the write satisfies the
	// interrealm borrow rule. Reads use plain getters (no mutation, no realm token).
	//
	// Mapping to the reference CosmWasm contract (state.rs):
	//
	//	tokenOrigin        <- TOKEN_ORIGIN          Map<denom, U256>
	//	channelBalanceV2   <- CHANNEL_BALANCE_V2    Map<(channel,path,base,quote), U256>
	//	metadataImageOf    <- METADATA_IMAGE_OF     Map<denom, H256>
	//	hashToForeignToken <- HASH_TO_FOREIGN_TOKEN Map<denom, Bytes>
	//	inFlightPacket     <- IN_FLIGHT_PACKET      Map<packetHash, Packet>
	//	tokenBucket        <- TOKEN_BUCKET          Map<denom, TokenBucket>
	//	rateLimitDisabled  <- CONFIG.rate_limit_disabled
	//
	// CONFIG.{admin,ibc_host} are not duplicated here: they are sourced from core.
	// The CosmWasm code_id fields (token_minter/dummy/cw_account) and the
	// transaction-scratch items (EXECUTING_PACKET, EXECUTION_ACK, MARKET_MAKER, ...)
	// are intentionally omitted: gno calls are synchronous, so that data is carried
	// as parameters/locals instead of persisted across submessage hops.
	store *Store

	// paused is a proxy-level gate checked by the App receivers before delegating to
	// the impl. It is governance state, not impl-visible state, so it lives on the
	// proxy package rather than inside the injected Store.
	paused bool

	// upgrade.gno is the single admin-gated swap point for the zkgm app logic. The
	// proxy keeps the Store, identity, and escrow funds stable across upgrades; only
	// the installed impl changes.
	//
	// The swap is two-phase, mirroring core's host upgrade model: an impl realm
	// registers its constructor under its own package path via RegisterImpl (from its
	// init), and the admin later activates a registered path via UpdateImpl. The
	// proxy injects its own Store into the constructor, so the store needs no public
	// getter — the only way to obtain it is through this gated install.
	proxyPkgPath     string  = ""
	proxyAddress     address = ""
	currentImplPath  string
	currentImpl      IApp
	implConstructors map[string]func(store IStore) IApp
)

func init(cur realm) {
	store = NewStore()
	paused = false

	proxyPkgPath = cur.PkgPath()
	proxyAddress = cur.Address()
	currentImpl = nil
	currentImplPath = ""
	implConstructors = make(map[string]func(store IStore) IApp)
}

type Store struct {
	tokenOrigin        *bptree.BPTree // denom -> *u256.Uint  (mint path)
	channelBalanceV2   *bptree.BPTree // key   -> *u256.Uint  (escrow balance)
	metadataImageOf    *bptree.BPTree // denom -> [32]byte
	hashToForeignToken *bptree.BPTree // denom -> []byte
	inFlightPacket     *bptree.BPTree // packetHash -> types.Packet (parent)
	tokenBucket        *bptree.BPTree // denom -> *tb.TokenBucket
	vouchers           *bptree.BPTree // ibcDenom -> *Voucher
	// lockedTokenAmounts is managed alongside vouchers: both track non-escrow
	// custody of a base token (native or grc20) that zkgm cannot supply-burn,
	// as opposed to vouchers, which zkgm mints/burns directly.
	lockedTokenAmounts *bptree.BPTree // denom -> *u256.Uint (permanently locked base token)
	receivers          *bptree.BPTree // pkgPath -> z.Zkgmable
	rateLimitDisabled  bool
}

func NewStore() *Store {
	return &Store{
		tokenOrigin:        bptree.NewBPTree32(),
		channelBalanceV2:   bptree.NewBPTree32(),
		metadataImageOf:    bptree.NewBPTree32(),
		hashToForeignToken: bptree.NewBPTree32(),
		inFlightPacket:     bptree.NewBPTree32(),
		tokenBucket:        bptree.NewBPTree32(),
		vouchers:           bptree.NewBPTree32(),
		lockedTokenAmounts: bptree.NewBPTree32(),
		receivers:          bptree.NewBPTree32(),
		// Rate limiting is opt-in: enabled per-denom by an admin who first
		// configures a token bucket (see SetBucketConfig). With it enabled, a denom
		// without a bucket is rejected (union TokenBucketIsAbsent), so it must stay
		// disabled by default to avoid bricking every unconfigured denom.
		rateLimitDisabled: true,
	}
}

// SetTokenOrigin records the mint path for a wrapped denom.
func (s *Store) SetTokenOrigin(_ int, rlm realm, denom string, path *u256.Uint) {
	assertIsRlmCurrent(0, rlm)

	pathClone := u256.Zero().Set(path).Clone()

	s.tokenOrigin.Set(denom, pathClone)
}

// GetTokenOrigin returns the recorded mint path for a denom.
func (s *Store) GetTokenOrigin(denom string) (*u256.Uint, bool) {
	v := s.tokenOrigin.Get(denom)
	if v == nil {
		return nil, false
	}

	return v.(*u256.Uint), true
}

// SetChannelBalanceV2 stores the escrow balance for a channel-balance key.
func (s *Store) SetChannelBalanceV2(_ int, rlm realm, key string, amount *u256.Uint) {
	assertIsRlmCurrent(0, rlm)

	calculatedAmount := u256.Zero().Set(amount).Clone()

	s.channelBalanceV2.Set(key, calculatedAmount)
}

// RemoveChannelBalanceV2 clears a drained channel-balance entry.
func (s *Store) RemoveChannelBalanceV2(_ int, rlm realm, key string) {
	assertIsRlmCurrent(0, rlm)

	s.channelBalanceV2.Remove(key)
}

// GetChannelBalanceV2 returns the escrow balance for a key.
func (s *Store) GetChannelBalanceV2(key string) (*u256.Uint, bool) {
	v := s.channelBalanceV2.Get(key)
	if v == nil {
		return nil, false
	}

	return v.(*u256.Uint), true
}

// SetMetadataImageOf records a wrapped denom's metadata image.
func (s *Store) SetMetadataImageOf(_ int, rlm realm, denom string, image [32]byte) {
	assertIsRlmCurrent(0, rlm)

	s.metadataImageOf.Set(denom, image)
}

// GetMetadataImageOf returns a wrapped denom's metadata image.
func (s *Store) GetMetadataImageOf(denom string) ([32]byte, bool) {
	v := s.metadataImageOf.Get(denom)
	if v == nil {
		return [32]byte{}, false
	}

	return v.([32]byte), true
}

// SetForeignToken records the origin token bytes for a wrapped denom.
func (s *Store) SetForeignToken(_ int, rlm realm, denom string, token []byte) {
	assertIsRlmCurrent(0, rlm)

	s.hashToForeignToken.Set(denom, token)
}

// GetForeignToken returns the origin token bytes for a wrapped denom.
func (s *Store) GetForeignToken(denom string) ([]byte, bool) {
	v := s.hashToForeignToken.Get(denom)
	if v == nil {
		return nil, false
	}

	return v.([]byte), true
}

// SetInFlightPacket records the parent packet awaiting a forwarded child.
func (s *Store) SetInFlightPacket(_ int, rlm realm, packetHash string, parent types.Packet) {
	assertIsRlmCurrent(0, rlm)

	s.inFlightPacket.Set(packetHash, parent)
}

// GetInFlightPacket returns the parent packet for a forwarded-child hash.
func (s *Store) GetInFlightPacket(packetHash string) (types.Packet, bool) {
	v := s.inFlightPacket.Get(packetHash)
	if v == nil {
		return types.Packet{}, false
	}

	return v.(types.Packet), true
}

// RemoveInFlightPacket clears a resolved forwarded-child entry.
func (s *Store) RemoveInFlightPacket(_ int, rlm realm, packetHash string) {
	assertIsRlmCurrent(0, rlm)

	s.inFlightPacket.Remove(packetHash)
}

// SetTokenBucket stores the rate-limit bucket for a denom.
func (s *Store) SetTokenBucket(_ int, rlm realm, denom string, bucket *tb.TokenBucket) {
	assertIsRlmCurrent(0, rlm)

	s.tokenBucket.Set(denom, bucket)
}

// GetTokenBucket returns the rate-limit bucket for a denom.
func (s *Store) GetTokenBucket(denom string) (*tb.TokenBucket, bool) {
	v := s.tokenBucket.Get(denom)
	if v == nil {
		return nil, false
	}

	return v.(*tb.TokenBucket), true
}

// RemoveTokenBucket clears a denom's rate-limit bucket.
func (s *Store) RemoveTokenBucket(_ int, rlm realm, denom string) {
	assertIsRlmCurrent(0, rlm)

	s.tokenBucket.Remove(denom)
}

// SetVoucher stores the wrapped voucher for an ibc denom.
func (s *Store) SetVoucher(_ int, rlm realm, ibcDenom string, v *Voucher) {
	assertIsRlmCurrent(0, rlm)

	s.vouchers.Set(ibcDenom, v)
}

// GetVoucher returns the wrapped voucher for an ibc denom.
func (s *Store) GetVoucher(ibcDenom string) (*Voucher, bool) {
	v := s.vouchers.Get(ibcDenom)
	if v == nil {
		return nil, false
	}

	return v.(*Voucher), true
}

// GetVoucherList returns a page of up to count vouchers starting at offset,
// ordered by denom. The vouchers tree only grows (there is no voucher
// deletion), so pagination keeps a single call's gas/response size bounded
// regardless of how many wrapped tokens have been registered over time.
func (s *Store) GetVoucherList(offset, count int) []VoucherInfo {
	voucherList := []VoucherInfo{}

	// The callback returns false to keep iterating (true stops early).
	s.vouchers.IterateByOffset(offset, count, func(key string, value any) bool {
		voucher, ok := value.(*Voucher)
		if !ok {
			panic(ErrInterfaceConversion)
		}

		voucherList = append(voucherList, NewVoucherInfo(
			key,
			voucher.token.GetName(),
			voucher.token.GetSymbol(),
			voucher.originDecimals,
			uint8(voucher.token.GetDecimals()),
			voucher.token.TotalSupply(),
		))

		return false // continue iteration
	})

	return voucherList
}

// GetVoucherSize returns the total number of registered vouchers, i.e. the
// key count callers need to drive GetVoucherList's offset/count pagination.
func (s *Store) GetVoucherSize() int {
	return s.vouchers.Size()
}

// HasVoucher reports whether a voucher exists for an ibc denom.
func (s *Store) HasVoucher(ibcDenom string) bool {
	return s.vouchers.Has(ibcDenom)
}

// AddLockedTokenAmount tracks base-token escrow locked after burn-address settlement
// (native or a registered grc20; a voucher is supply-burned instead via burnVoucher).
// Locked base remains in proxy escrow but is excluded from channel balances.
// Invariant: proxy balance == sum(channelBalanceV2) + sum(lockedTokenAmounts).
func (s *Store) AddLockedTokenAmount(_ int, rlm realm, denom string, amount *u256.Uint) {
	assertIsRlmCurrent(0, rlm)

	totalLockedAmount := u256.Zero()

	lockedTokenAmount, exists := s.GetLockedTokenAmount(denom)
	if exists && lockedTokenAmount != nil {
		totalLockedAmount = u256.Zero().Set(lockedTokenAmount)
	}

	// Reject a wraparound past 2^256-1 rather than silently storing a smaller
	// totalLockedAmount, which would break the proxy balance invariant.
	// Astronomically unreachable for real coin supplies, but guarded for safety.
	totalLockedAmount, overflow := u256.Zero().AddOverflow(totalLockedAmount, amount)
	if overflow {
		panic(ErrLockedTokenAmountOverflow)
	}

	s.lockedTokenAmounts.Set(denom, totalLockedAmount.Clone())
}

// GetLockedTokenAmount returns the total base-token amount permanently locked for a denom.
func (s *Store) GetLockedTokenAmount(denom string) (*u256.Uint, bool) {
	v := s.lockedTokenAmounts.Get(denom)
	if v == nil {
		return nil, false
	}

	lockedTokenAmount, ok := v.(*u256.Uint)
	if !ok {
		panic(ErrInterfaceConversion)
	}

	return lockedTokenAmount, true
}

// SetReceiver registers a Zkgmable callback target at a package path.
func (s *Store) SetReceiver(_ int, rlm realm, path string, receiver z.Zkgmable) {
	assertIsRlmCurrent(0, rlm)

	s.receivers.Set(path, receiver)
}

// GetReceiver returns the callback target registered at a package path.
func (s *Store) GetReceiver(path string) (z.Zkgmable, bool) {
	r := s.receivers.Get(path)
	if r == nil {
		return nil, false
	}

	return r.(z.Zkgmable), true
}

// SetRateLimitDisabled toggles the global rate-limit kill switch.
func (s *Store) SetRateLimitDisabled(_ int, rlm realm, disabled bool) {
	assertIsRlmCurrent(0, rlm)

	s.rateLimitDisabled = disabled
}

// RateLimitDisabled reports whether rate limiting is globally disabled.
func (s *Store) RateLimitDisabled() bool {
	return s.rateLimitDisabled
}
