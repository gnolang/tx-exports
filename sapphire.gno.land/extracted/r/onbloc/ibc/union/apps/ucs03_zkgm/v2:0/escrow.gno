package ucs03_zkgm

import (
	"chain"
	"chain/banker"

	u256 "gno.land/p/onbloc/math/uint256"
	zkgm "gno.land/r/onbloc/ibc/union/apps/ucs03_zkgm"
)

// sendNative releases amount of denom from the proxy escrow account to receiver.
func (v *ucs03ZkgmV2LockedRecovery) sendNative(_ int, rlm realm, denom string, receiver address, amount *u256.Uint) error {
	n, err := amountInt64(amount)
	if err != nil {
		return err
	}
	// rlm is the proxy's frame (interrealm borrow), so this draws from the proxy's own balance.
	b := banker.NewBanker(banker.BankerTypeRealmSend, rlm)
	b.SendCoins(rlm.Address(), receiver, chain.NewCoins(chain.NewCoin(denom, n)))
	zkgm.EmitNativeReleased(0, rlm, denom, receiver, n)

	return nil
}
