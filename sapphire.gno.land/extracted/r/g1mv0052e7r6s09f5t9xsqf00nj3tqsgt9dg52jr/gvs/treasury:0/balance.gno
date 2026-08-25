package treasury

import (
	"gno.land/p/g1mv0052e7r6s09f5t9xsqf00nj3tqsgt9dg52jr/gvs/poolkey"
	"gno.land/r/gnoswap/common"
)

func tokenBalance() int64 {
	return common.BalanceOf(poolkey.WugnotKey, self)
}

func pushToken(cur realm, to address, amount int64) {
	err := common.Transfer(cross(cur), poolkey.WugnotKey, to, amount)
	if err != nil {
		panic(err.Error())
	}
}
