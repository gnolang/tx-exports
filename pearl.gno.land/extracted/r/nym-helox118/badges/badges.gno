package badges

import (
	"gno.land/p/nt/seqid/v0"
	"gno.land/p/nym-helox118/grc721"
	"gno.land/r/nym-helox118/pearlpass"
)

var (
	token  *grc721.Token
	ledger *grc721.PrivateLedger
	issued = map[address]string{}
)

func CreateCollection(cur realm) {
	if !cur.IsCurrent() {
		panic("invalid realm")
	}

	if token != nil {
		panic("collection already created")
	}

	var collectionID seqid.ID

	token, ledger = grc721.NewToken(
		"Pearl Passport Badges",
		"PBADGE",
		collectionID,
		cur,
	)
}

func MintMyBadge(cur realm) {
	if !cur.IsCurrent() {
		panic("invalid realm")
	}

	if ledger == nil {
		panic("collection has not been created")
	}

	owner := cur.Previous().Address()

	if issued[owner] != "" {
		panic("badge already minted")
	}

	badge := pearlpass.GetBadge(owner)

	if badge == "No badge" {
		panic("complete a Pearl Passport quest first")
	}

	tokenID := owner.String()

	err := ledger.Mint(
		owner,
		grc721.TokenID(tokenID),
	)
	if err != nil {
		panic(err)
	}

	issued[owner] = badge
}

func GetMyBadge(owner address) string {
	return issued[owner]
}

func OwnerOf(tokenID string) address {
	if token == nil {
		panic("collection has not been created")
	}

	owner, err := token.OwnerOf(grc721.TokenID(tokenID))
	if err != nil {
		panic(err)
	}

	return owner
}

func TotalSupply() int64 {
	if token == nil {
		return 0
	}

	return token.TotalSupply()
}

func Render(_ string) string {
	if token == nil {
		return "Pearl Passport Badges belum dibuat."
	}

	return "Pearl Passport Badges\n" +
		"Symbol: PBADGE\n" +
		"Mint satu badge untuk setiap wallet."
}
