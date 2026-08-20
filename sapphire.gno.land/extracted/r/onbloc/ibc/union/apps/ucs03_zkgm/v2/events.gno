package ucs03_zkgm

import (
	"chain"
	"strconv"

	types "gno.land/p/onbloc/ibc/union/types"
	u256 "gno.land/p/onbloc/math/uint256"
)

// AdminRecoveredLockedTokenEvent is this impl's own event (chain.Emit needs no
// proxy-side registration), recorded under this realm's pkgpath — distinct
// from the ZkgmNativeReleasedEvent/grc20 Transfer events releaseLockedToken also emits.
// origin_amount and ledger_amount are both emitted since Send's input unit
// (origin precision) differs from what actually moves (ledger precision) for
// scaled ibc vouchers — see adminRecoverLockedToken/ledgerAmountOf.
const AdminRecoveredLockedTokenEvent = "AdminRecoveredLockedToken"

func emitAdminRecoveredLockedTokenEvent(admin address, channelId types.ChannelId, denom string, recipient address, originAmount *u256.Uint, ledgerAmount int64) {
	chain.Emit(
		AdminRecoveredLockedTokenEvent,
		"admin", admin.String(),
		"channel_id", channelId.String(),
		"denom", denom,
		"recipient", recipient.String(),
		"origin_amount", originAmount.ToString(),
		"ledger_amount", strconv.FormatInt(ledgerAmount, 10),
	)
}
