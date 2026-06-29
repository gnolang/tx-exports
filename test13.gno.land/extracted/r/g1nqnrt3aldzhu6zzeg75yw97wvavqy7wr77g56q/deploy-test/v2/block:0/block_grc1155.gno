package block

import "gno.land/p/g1nqnrt3aldzhu6zzeg75yw97wvavqy7wr77g56q/deploy-test/v2/grc1155"

type BlockGRC1155Token interface {
	grc1155.IGRC1155
	SafeMint(caller, to address, tokenID grc1155.TokenID, amount int64) error
	Burn(caller, from address, tokenID grc1155.TokenID, amount int64) error
	BatchBurn(caller, from address, batch []grc1155.TokenID, amounts []int64) error
}
