package token_register

import (
	token "gno.land/r/g13f63ua8uhmuf9mgc0x8zfz04yrsaqh7j78vcgq/monkey"

	pusers "gno.land/p/demo/users"

	pl "gno.land/r/gnoswap/v2/pool"
	rr "gno.land/r/gnoswap/v2/router"
	sr "gno.land/r/gnoswap/v2/staker"
	pf "gno.land/r/gnoswap/v2/protocol_fee"
	cp "gno.land/r/gnoswap/v2/community_pool"
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
	pl.RegisterGRC20Interface("gno.land/r/g13f63ua8uhmuf9mgc0x8zfz04yrsaqh7j78vcgq/monkey", NewToken{})
	rr.RegisterGRC20Interface("gno.land/r/g13f63ua8uhmuf9mgc0x8zfz04yrsaqh7j78vcgq/monkey", NewToken{})
	sr.RegisterGRC20Interface("gno.land/r/g13f63ua8uhmuf9mgc0x8zfz04yrsaqh7j78vcgq/monkey", NewToken{})
	pf.RegisterGRC20Interface("gno.land/r/g13f63ua8uhmuf9mgc0x8zfz04yrsaqh7j78vcgq/monkey", NewToken{})
	cp.RegisterGRC20Interface("gno.land/r/g13f63ua8uhmuf9mgc0x8zfz04yrsaqh7j78vcgq/monkey", NewToken{})
}
