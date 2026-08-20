package ucs03_zkgm

import (
	"gno.land/p/onbloc/access/manager"
	types "gno.land/p/onbloc/ibc/union/types"

	u256 "gno.land/p/onbloc/math/uint256"
	"gno.land/r/onbloc/ibc/union/access"
)

// selectorAdminRecoverLockedToken gates Send to admin. Defined here, not in the
// already-deployed access.gno — an unconfigured selector defaults to AdminRole
// (manager.GetTargetFunctionRole), so no proxy-side change is needed.
const selectorAdminRecoverLockedToken manager.Selector = "v2_locked_recovery/admin_recover_locked_token"

// adminRecoverLockedToken releases originAmount (origin-token precision, same
// units as an ordinary Send — see ledgerAmountOf) of the (channelId, path=0,
// baseToken, quoteToken) escrow to recipient. decreaseChannelBalanceV2 is the
// fund-safety check; failures here panic (not return) so the whole tx reverts
// atomically — no hand-written rollback. Native coin and ibc/ vouchers only;
// recipient must pass address.IsValid() so a malformed/non-Gno recipient
// can't receive funds nobody controls.
//
// Out of scope on purpose: store.lockedTokenAmounts (see burnEscrowedV2 in
// v1/token_order.gno). The deployed IStore only exposes an additive
// AddLockedTokenAmount, no decrement, so no impl can recover it without a
// proxy-side IStore change — moot anyway since no market maker is in use.
func (v *ucs03ZkgmV2LockedRecovery) adminRecoverLockedToken(_ int, rlm realm, channelId types.ChannelId, baseToken, quoteToken []byte, originAmount *u256.Uint, recipient address) {
	access.AssertCanCall(0, rlm, selectorAdminRecoverLockedToken)

	if originAmount.IsZero() {
		panic(makeError(errRecoveryZeroAmount))
	}

	if !recipient.IsValid() {
		panic(makeError(errInvalidRecipient))
	}

	if len(baseToken) == 0 {
		panic(makeError(errBaseTokenRequired))
	}

	if len(quoteToken) == 0 {
		panic(makeError(errQuoteTokenRequired))
	}

	path := u256.Zero()
	denom := string(baseToken)

	tokenType := getTokenType(denom)
	if tokenType != NATIVE_COIN && tokenType != IBC_TOKEN {
		panic(makeError(errRecoveryUnsupportedTokenType))
	}

	amount, err := v.ledgerAmountOf(denom, originAmount)
	if err != nil {
		panic(err)
	}

	if err := v.decreaseChannelBalanceV2(0, rlm, channelId, path, baseToken, quoteToken, amount); err != nil {
		panic(err)
	}

	if err := v.releaseLockedToken(0, rlm, tokenType, denom, recipient, amount); err != nil {
		panic(err)
	}

	emitAdminRecoveredLockedTokenEvent(rlm.Previous().Address(), channelId, denom, recipient, originAmount, amount)
}

// releaseLockedToken moves amount (channelBalanceV2/ledger precision) of denom
// to recipient. Uses the voucher's raw ledger balance directly rather than the
// *Scaled helpers, which expect origin precision and would downscale again
// (e.g. an 18-decimal origin token on a 6-decimal ledger).
func (v *ucs03ZkgmV2LockedRecovery) releaseLockedToken(_ int, rlm realm, tokenType int, denom string, recipient address, amount int64) error {
	if tokenType == IBC_TOKEN {
		vou, ok := v.store.GetVoucher(denom)
		if !ok {
			return makeError(errVoucherNotFound, denom)
		}

		return vou.Ledger().Transfer(rlm.Address(), recipient, amount)
	}

	return v.sendNative(0, rlm, denom, recipient, u256.NewUint(uint64(amount)))
}
