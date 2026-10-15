package guardians

import (
	"strconv"
	"time"
	"chain/runtime"
	"gno.land/p/nt/ufmt/v0"
)

func LaunchVersion() string { return "GUARDIANS_MAINNET_V1" }

// One read produces a consistent supply/reserve/timing snapshot and avoids
// issuing thousands of owner queries as the collection approaches 3,333.
func SaleSnapshot() string {
	return ufmt.Sprintf(`{"version":%s,"network":%s,"collectionId":%s,"admin":%s,"treasury":%s,"maxSupply":%d,"supply":%d,"configured":%t,"paused":%t,"phase":%s,"startsAt":%d,"endsAt":%d,"allowlistStartsAt":%d,"allowlistEndsAt":%d,"priceUgnot":%d,"freePriceUgnot":%d,"publicLimit":%d,"freeLimit":%d,"root":%s,"reserveCapacity":%d,"freeMintedSupply":%d,"reserveReleased":%t,"protectedRemaining":%d,"publicAvailable":%d,"revealState":%s,"revealProcessed":%d,"revealTarget":%d,"veiledURI":%s,"finalBaseURI":%s,"provenance":%s,"serverTime":%d}`,
		strconv.Quote(LaunchVersion()),strconv.Quote(runtime.ChainID()),strconv.Quote(CollectionID()),strconv.Quote(Admin().String()),strconv.Quote(SaleTreasury().String()),MaxSupply(),TotalSupply(),SaleConfigured(),SalePaused(),strconv.Quote(SalePhase()),PublicStart(),PublicEnd(),AllowlistStart(),AllowlistEnd(),PublicPrice(),AllowlistPrice(),PublicWalletLimit(),AllowlistWalletLimit(),strconv.Quote(AllowlistRoot()),AllowlistReservedSupply(),AllowlistMintedSupply(),AllowlistReserveReleased(),AllowlistReserveRemaining(),PublicMintableSupply(),strconv.Quote(RevealState()),RevealProcessed(),RevealTarget(),strconv.Quote(VeiledURI()),strconv.Quote(FinalBaseURI()),strconv.Quote(ProvenanceRoot()),time.Now().Unix())
}

func WalletSnapshot(owner address) string {
	return ufmt.Sprintf(`{"freeMinted":%d,"paidMinted":%d,"balance":%d}`,AllowlistMinted(owner),PublicMinted(owner),BalanceOf(owner))
}
