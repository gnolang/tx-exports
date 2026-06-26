package block

import (
	"chain"
	"chain/banker"
	"strconv"

	"gno.land/p/g1nqnrt3aldzhu6zzeg75yw97wvavqy7wr77g56q/deploy-test/v0/v0/grc1155"
)

func copyStringMap(source map[string]string) map[string]string {
	result := map[string]string{}
	for k, v := range source {
		result[k] = v
	}
	return result
}

func blockIDToString(blockID uint32) string {
	return strconv.FormatUint(uint64(blockID), 10)
}

func stringToBlockID(blockIDStr string) uint32 {
	value, err := strconv.ParseUint(blockIDStr, 10, 32)
	if err != nil {
		panic("invalid blockID: " + err.Error())
	}
	return uint32(value)
}

func parseBlockID(blockIDStr string) (uint32, bool) {
	value, err := strconv.ParseUint(blockIDStr, 10, 32)
	if err != nil {
		return 0, false
	}
	return uint32(value), true
}

func blockIDToTokenID(blockID uint32) grc1155.TokenID {
	return grc1155.TokenID(blockIDToString(blockID))
}

func tokenIDToBlockID(tokenID grc1155.TokenID) uint32 {
	return stringToBlockID(string(tokenID))
}

func tokenIDsToBlockIDs(tokenIDs []grc1155.TokenID) []uint32 {
	blockIDs := make([]uint32, len(tokenIDs))
	for i, tokenID := range tokenIDs {
		blockIDs[i] = tokenIDToBlockID(tokenID)
	}
	return blockIDs
}

func calculateBPSShares(amount int64, bps int) (int64, int64) {
	if amount <= 0 {
		return 0, 0
	}
	if bps <= 0 {
		return 0, amount
	}
	if bps >= 10000 {
		return amount, 0
	}

	bps64 := int64(bps)
	first := (amount/10000)*bps64 + (amount%10000)*bps64/10000
	return first, amount - first
}

func distributeShares(cur realm, recipientStr string, feeCollector address, cost int64, bps int) (int64, int64) {
	if cost <= 0 {
		return 0, 0
	}

	recipientShare, feeCollectorShare := calculateBPSShares(cost, bps)
	if recipientShare > 0 {
		recipient := mustParseAddress(recipientStr)
		send(cur, recipient, recipientShare)
	}
	if feeCollectorShare > 0 {
		if !feeCollector.IsValid() {
			panic("fee collector is invalid: " + feeCollector.String())
		}
		send(cur, feeCollector, feeCollectorShare)
	}
	return recipientShare, feeCollectorShare
}

func send(cur realm, to address, amount int64) {
	if amount <= 0 {
		panic("amount must be greater than 0")
	}
	bnk := banker.NewBanker(banker.BankerTypeRealmSend, cur)
	realmAddr := cur.Address()
	coins := chain.Coins{chain.Coin{"ugnot", amount}}
	bnk.SendCoins(realmAddr, to, coins)
}
