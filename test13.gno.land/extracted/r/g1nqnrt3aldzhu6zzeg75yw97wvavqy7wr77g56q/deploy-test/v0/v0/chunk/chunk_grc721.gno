package chunk

import "gno.land/p/g1nqnrt3aldzhu6zzeg75yw97wvavqy7wr77g56q/deploy-test/v0/v0/grc721"

type ChunkGRC721Token interface {
	grc721.IGRC721Reader
	Approve(caller, to address, tokenID grc721.TokenID) error
	SetApprovalForAll(caller, operator address, approved bool) error
	TransferFrom(caller, from, to address, tokenID grc721.TokenID) error
	Mint(to address, tokenID grc721.TokenID) error
	SafeMint(to address, tokenID grc721.TokenID) error
	Burn(tokenID grc721.TokenID) error
}
