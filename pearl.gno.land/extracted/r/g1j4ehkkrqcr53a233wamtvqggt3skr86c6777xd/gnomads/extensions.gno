package gnomads

import (
	"gno.land/p/g1j4ehkkrqcr53a233wamtvqggt3skr86c6777xd/gnomads/grc721/enumerable/v0"
	"gno.land/p/g1j4ehkkrqcr53a233wamtvqggt3skr86c6777xd/gnomads/grc721/metadata/v0"
	"gno.land/p/g1j4ehkkrqcr53a233wamtvqggt3skr86c6777xd/gnomads/grc721/royalty/v0"
	"gno.land/p/g1j4ehkkrqcr53a233wamtvqggt3skr86c6777xd/gnomads/grc721/v0"
)

const (
	defaultRoyaltyBps = int64(500)  // 5%, matching the selected OpenSea-style policy.
	royaltyMaxBps     = int64(1000) // Permanent collection cap: 10%.
)

// Replace this value through SetVeiledURI before the first public mint.
// The explicit placeholder prevents an unfinished CID from looking production-ready.
var veiledURI = "ipfs://REPLACE_WITH_VEILED_METADATA_CID/metadata.json"

var (
	metadataView     *metadata.Metadata
	metadataLedger   *metadata.Ledger
	enumerableView   *enumerable.Enumerable
	enumerableLedger *enumerable.Ledger
	royaltyView      *royalty.Royalty
	royaltyLedger    *royalty.Ledger
)

// attachExtensions must run before the first mint so the enumerable index and
// metadata hooks observe every token from genesis.
func attachExtensions(coreLedger *grc721.PrivateLedger) {
	metadataView, metadataLedger = metadata.NewMetadata(coreLedger)
	enumerableView, enumerableLedger = enumerable.NewEnumerable(coreLedger)
	royaltyView, royaltyLedger = royalty.NewRoyalty(coreLedger, royaltyMaxBps)

	if err := royaltyLedger.SetDefaultRoyalty(localAdmin, defaultRoyaltyBps); err != nil {
		panic(err)
	}
}

// Metadata / veil facade.

func VeiledURI() string { return veiledURI }

func TokenURI(tokenID string) string {
	uri, err := metadataView.TokenURI(grc721.TokenID(tokenID))
	if err != nil {
		panic(err)
	}
	return uri
}

// SetVeiledURI allows the final placeholder CID to be configured once before
// minting begins. Existing token URIs are never silently rewritten.
func SetVeiledURI(cur realm, uri string) {
	assertAdmin(cur.Previous().Address())
	supply := token.TotalSupply()
	if !canConfigureVeiledURI(uri, supply) {
		if supply != 0 {
			panic("gnomads: veiled uri is locked after the first mint")
		}
		panic("gnomads: veiled uri cannot be empty")
	}
	veiledURI = uri
}

func validVeiledURI(uri string) bool { return uri != "" }

func canConfigureVeiledURI(uri string, supply int64) bool {
	return supply == 0 && validVeiledURI(uri)
}

func setInitialTokenURI(tokenID grc721.TokenID) {
	if err := metadataLedger.SetTokenURI(tokenID, veiledURI); err != nil {
		panic(err)
	}
}

// Enumerable facade.

func EnumerableSupply() int64 { return enumerableView.TotalSupply() }

func TokenByIndex(index int64) string {
	tokenID, err := enumerableView.TokenByIndex(index)
	if err != nil {
		panic(err)
	}
	return tokenID.String()
}

func TokenOfOwnerByIndex(owner address, index int64) string {
	tokenID, err := enumerableView.TokenOfOwnerByIndex(owner, index)
	if err != nil {
		panic(err)
	}
	return tokenID.String()
}

// Royalty facade. This is EIP-2981-style royalty information. Actual payment
// enforcement belongs in the project marketplace settlement realm.

func RoyaltyMaxBps() int64 { return royaltyView.MaxBps() }

func DefaultRoyalty() (address, int64) {
	info, ok := royaltyView.DefaultRoyalty()
	if !ok {
		return address(""), 0
	}
	return info.Receiver, info.Bps
}

func RoyaltyInfo(tokenID string, salePrice int64) (address, int64) {
	receiver, amount, err := royaltyView.RoyaltyInfo(grc721.TokenID(tokenID), salePrice)
	if err != nil {
		panic(err)
	}
	return receiver, amount
}

func SetDefaultRoyalty(cur realm, receiver address, bps int64) {
	assertAdmin(cur.Previous().Address())
	if !validRoyaltyBps(bps) {
		panic("gnomads: royalty bps out of range")
	}
	if err := royaltyLedger.SetDefaultRoyalty(receiver, bps); err != nil {
		panic(err)
	}
}

func validRoyaltyBps(bps int64) bool {
	return bps >= 0 && bps <= royaltyMaxBps
}
