package token_register

import (
	token "gno.land/r/g1pgcgqvm5ta3rfw7t67yp9faj94ynmxn5ygx2cd/gnome"

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
	pl.RegisterGRC20Interface("gno.land/r/g1pgcgqvm5ta3rfw7t67yp9faj94ynmxn5ygx2cd/gnome", NewToken{})
	rr.RegisterGRC20Interface("gno.land/r/g1pgcgqvm5ta3rfw7t67yp9faj94ynmxn5ygx2cd/gnome", NewToken{})
	sr.RegisterGRC20Interface("gno.land/r/g1pgcgqvm5ta3rfw7t67yp9faj94ynmxn5ygx2cd/gnome", NewToken{})
	pf.RegisterGRC20Interface("gno.land/r/g1pgcgqvm5ta3rfw7t67yp9faj94ynmxn5ygx2cd/gnome", NewToken{})
	cp.RegisterGRC20Interface("gno.land/r/g1pgcgqvm5ta3rfw7t67yp9faj94ynmxn5ygx2cd/gnome", NewToken{})
}
