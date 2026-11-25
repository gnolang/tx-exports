package grantround

import "chain"

func chainCoin(denom string, n int64) chain.Coins { return chain.Coins{{denom, n}} }
