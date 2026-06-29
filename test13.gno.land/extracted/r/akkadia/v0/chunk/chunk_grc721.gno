package chunk

import "gno.land/p/akkadia/v0/grc721"

type ChunkGRC721Token interface {
	grc721.IGRC721Reader
	Approve(caller, to address, tokenID grc721.TokenID) error
	SetApprovalForAll(caller, operator address, approved bool) error
	TransferFrom(caller, from, to address, tokenID grc721.TokenID) error
	Mint(to address, tokenID grc721.TokenID) error
	SafeMint(to address, tokenID grc721.TokenID) error
	Burn(tokenID grc721.TokenID) error
}
