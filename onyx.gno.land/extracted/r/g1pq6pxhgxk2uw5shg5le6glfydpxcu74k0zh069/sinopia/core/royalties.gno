package core

import (
	"chain"
	"chain/banker"

	"gno.land/p/g1pq6pxhgxk2uw5shg5le6glfydpxcu74k0zh069/sinopia/safe/v1"
)

// Each collection's royalty receiver is its own sub-treasury
// DerivePkgSubAddr(core, "roy/<cid>"), written into the official royalty
// extension at creation. Any market can pay it through RoyaltyInfo; the
// creator can re-split it later (SetPayees) without touching the receiver.
// Only core can spend it: a banker for a sub-address needs core's live
// cur.Sub (interrealm v2 §5.5).

func royaltyAddress(cid string) address {
	return chain.DerivePkgSubAddr(selfPath, "roy/"+cid)
}

// RoyaltyAddress is the collection's royalty sub-treasury.
func RoyaltyAddress(cid string) address {
	mustCollection(cid)
	return royaltyAddress(cid)
}

// DistributeRoyalties pushes the whole sub-treasury balance to the royalty
// payees. Permissionless and never paused (I-2); market/v1 calls it after
// every sale. Returns the amount distributed. The sub-realm banker spend
// is verified by spike/subtoken, core and market tests on gno v1.7.0.
func DistributeRoyalties(cur realm, cid string) int64 {
	assertNoDeposit(cur)
	return distribute(cur, mustCollection(cid))
}

func distribute(cur realm, c *collection) int64 {
	cid := c.id
	sub := cur.Sub("roy/" + cid)
	bal := banker.NewReadonlyBanker().GetCoin(sub.Address(), "ugnot")
	if bal <= 0 {
		return 0
	}
	shares := safe.SplitByBps(bal, c.royaltyPayees)
	bk := banker.NewBanker(banker.BankerTypeRealmSend, sub)
	for i, p := range c.royaltyPayees {
		if shares[i] > 0 {
			bk.SendCoins(sub.Address(), p.Addr, chain.NewCoins(chain.NewCoin("ugnot", shares[i])))
		}
	}
	chain.Emit("RoyaltiesDistributed", "cid", cid, "amount", itoa(bal))
	return bal
}
