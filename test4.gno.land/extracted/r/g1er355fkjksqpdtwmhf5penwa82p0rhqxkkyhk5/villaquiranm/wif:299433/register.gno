package token_register

import (
	token "gno.land/r/villaquiranm/wif"

	pusers "gno.land/p/demo/users"

	pl "gno.land/r/gnoswap/pool"
	rr "gno.land/r/gnoswap/router"
	sr "gno.land/r/gnoswap/staker"
	pf "gno.land/r/gnoswap/protocol_fee"
	cp "gno.land/r/gnoswap/community_pool"
)

type NewToken struct{}

func (NewToken) Transfer() func(to pusers.AddressOrName, amount uint64) {
	return token.Transfer
}

func (NewToken) TransferFrom() func(from, to pusers.AddressOrName, amount uint64) {
	return token.TransferFrom
}

func (NewToken) BalanceOf() func(owner pusers.AddressOrName) uint64 {
	return token.BalanceOf
}

func (NewToken) Approve() func(spender pusers.AddressOrName, amount uint64) {
	return token.Approve
}

func init() {
	pl.RegisterGRC20Interface("gno.land/r/villaquiranm/wif", NewToken{})
	rr.RegisterGRC20Interface("gno.land/r/villaquiranm/wif", NewToken{})
	sr.RegisterGRC20Interface("gno.land/r/villaquiranm/wif", NewToken{})
	pf.RegisterGRC20Interface("gno.land/r/villaquiranm/wif", NewToken{})
	cp.RegisterGRC20Interface("gno.land/r/villaquiranm/wif", NewToken{})
}
