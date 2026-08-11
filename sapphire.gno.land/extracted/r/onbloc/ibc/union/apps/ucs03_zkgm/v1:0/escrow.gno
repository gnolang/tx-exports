package ucs03_zkgm

import (
	"chain"
	"chain/banker"

	u256 "gno.land/p/onbloc/math/uint256"
	zkgm "gno.land/r/onbloc/ibc/union/apps/ucs03_zkgm"
)

// sendNative releases `amount` of denom from the proxy escrow account to
// receiver. Escrowed native funds sit at the proxy realm address; under the
// interrealm borrow rule this banker send executes in the proxy's ownership
// context even though it is invoked from the impl call frame, so the funds leave
// the proxy escrow rather than the impl realm.
func (v *ucs03ZkgmV1) sendNative(_ int, rlm realm, denom string, receiver address, amount *u256.Uint) error {
	n, err := amountInt64(amount)
	if err != nil {
		return err
	}
	// rlm.Address() is the proxy escrow account: under the interrealm borrow rule
	// the impl operates in the proxy's ownership context, so the realm-send banker
	// draws from the proxy balance where the user's -send funds landed.
	b := banker.NewBanker(banker.BankerTypeRealmSend, rlm)
	b.SendCoins(rlm.Address(), receiver, chain.NewCoins(chain.NewCoin(denom, n)))
	zkgm.EmitNativeReleased(0, rlm, denom, receiver, n)

	return nil
}
