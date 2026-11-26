package tavernboard

import (
	"chain"
	"chain/banker"
	"chain/runtime/unsafe"
	"strconv"
)

// escrowSubpath returns the canonical sub-realm path for a bounty's isolated
// escrow vault (e.g. "escrow/42"). Matches Gno v1.8 cur.Sub subpath grammar.
func escrowSubpath(bountyID uint64) string {
	return "escrow/" + strconv.FormatUint(bountyID, 10)
}

// stakeSubpath returns the canonical sub-realm path for a bounty's isolated
// reviewer stake vault (e.g. "stake/42").
func stakeSubpath(bountyID uint64) string {
	return "stake/" + strconv.FormatUint(bountyID, 10)
}

// DeriveEscrowAddress returns the deterministic bech32 address of the isolated
// sub-realm escrow vault for bountyID. Any external user, DAO, or realm can
// send ugnot directly to this address and call SyncBountyVault to co-fund it.
func DeriveEscrowAddress(bountyID uint64) address {
	if bountyID == 0 {
		panic("invalid bounty ID")
	}
	return chain.DerivePkgSubAddr(realmPkgPath, escrowSubpath(bountyID))
}

// DeriveStakeAddress returns the deterministic bech32 address of the isolated
// sub-realm reviewer stake vault for bountyID.
func DeriveStakeAddress(bountyID uint64) address {
	if bountyID == 0 {
		panic("invalid bounty ID")
	}
	return chain.DerivePkgSubAddr(realmPkgPath, stakeSubpath(bountyID))
}

// sweepOriginSendToSub validates an inbound direct EOA ugnot transfer and
// immediately moves the exact sent ugnot from this realm's address into the
// target sub-realm vault using BankerTypeOriginSend.
//
// Security invariant:
//   - Requires cur.Previous().IsUserCall() (blocks MsgRun ephemeral realms &
//     intermediate code realms from spoofing OriginSend).
//   - Uses BankerTypeOriginSend so at most this message's exact send-envelope
//     can ever be swept; host-realm balances cannot be touched.
//   - Rejects unexpected coin denominations so users never strand non-ugnot
//     tokens inside the realm.
func sweepOriginSendToSub(_ int, rlm realm, subpath string, minUgnot int64) (address, int64) {
	requireDirectUserCall(0, rlm)

	sent := unsafe.OriginSend()
	if len(sent) != 1 || sent[0].Denom != nativeDenom {
		panic("attach native ugnot only (e.g. -send 1000000ugnot)")
	}
	amount := sent[0].Amount
	if amount < minUgnot {
		panic("insufficient ugnot sent: minimum is " + strconv.FormatInt(minUgnot, 10) + nativeDenom)
	}

	sub := rlm.Sub(subpath)
	origBanker := banker.NewBanker(banker.BankerTypeOriginSend, rlm)
	origBanker.SendCoins(rlm.Address(), sub.Address(), chain.NewCoins(chain.NewCoin(nativeDenom, amount)))
	return sub.Address(), amount
}

// sendFromSubVault transfers ugnot out of an isolated sub-realm vault using a
// RealmSend banker scoped exclusively to that sub-realm token.
//
// Security invariant: the GnoVM banker strictly checks sub.Address() == from,
// making cross-bounty vault drains structurally impossible at the VM layer.
func sendFromSubVault(_ int, rlm realm, subpath string, to address, amount int64) {
	if amount <= 0 {
		return
	}
	sub := rlm.Sub(subpath)
	subBanker := banker.NewBanker(banker.BankerTypeRealmSend, sub)
	subBanker.SendCoins(sub.Address(), to, chain.NewCoins(chain.NewCoin(nativeDenom, amount)))
}

// liveVaultUgnot reads the live native ugnot balance of a vault using a
// single-denom GetCoin lookup (O(1) store read; immune to unsolicited-denom
// gas-griefing attacks).
func liveVaultUgnot(vaultAddr address) int64 {
	return banker.NewReadonlyBanker().GetCoin(vaultAddr, nativeDenom)
}
