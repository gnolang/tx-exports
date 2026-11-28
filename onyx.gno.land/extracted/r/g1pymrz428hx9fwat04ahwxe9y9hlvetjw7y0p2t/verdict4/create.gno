package verdict4

import (
	"chain/runtime"
	"crypto/bech32"
	"strings"
	"unicode/utf8"

	verdict "gno.land/p/g1pymrz428hx9fwat04ahwxe9y9hlvetjw7y0p2t/verdict"
)

// The leading sentinel keeps this a non-crossing helper, allowing the live
// realm guard to be exercised with a synthetic realm in same-package tests.
func requireDirectUserCall(_ int, rlm realm) {
	if !rlm.IsCurrent() || !rlm.Previous().IsUserCall() {
		panic("direct user call required")
	}
}

func CreateMarket(cur realm, question string, closeHeight int64, resolverKind string, target string, targetAmount int64) uint64 {
	requireDirectUserCall(0, cur)

	question = strings.TrimSpace(question)
	questionLength := utf8.RuneCountInString(question)
	if questionLength < 8 || questionLength > 160 {
		panic("invalid question")
	}
	if closeHeight <= runtime.ChainHeight() {
		panic("close height must be in the future")
	}

	var resolver ResolverConfig
	switch resolverKind {
	case "balance":
		if len(target) != 40 {
			panic("invalid resolver target")
		}
		targetAddress := address(target)
		if !targetAddress.IsValid() || strings.ToLower(target) != target {
			panic("invalid resolver target")
		}
		hrp, data, version, err := bech32.DecodeGeneric(target)
		if err != nil || hrp != "g" || version != bech32.Version0 {
			panic("invalid resolver target")
		}
		canonical, err := bech32.Encode(hrp, data)
		if err != nil || canonical != target {
			panic("invalid resolver target")
		}
		resolver = ResolverConfig{
			Kind:         ResolverBalance,
			Target:       targetAddress.String(),
			TargetAmount: targetAmount,
		}
	case "counter":
		if target != "" {
			panic("invalid resolver target")
		}
		resolver = ResolverConfig{
			Kind:         ResolverCounter,
			Target:       "",
			TargetAmount: targetAmount,
		}
	default:
		panic("invalid resolver")
	}
	if targetAmount <= 0 {
		panic("invalid resolver threshold")
	}

	if nextMarketID == ^uint64(0) {
		panic("market ID overflow")
	}
	nextMarketID++
	id := nextMarketID
	market := Market{
		ID:          id,
		Question:    question,
		Creator:     cur.Previous().Address(),
		CloseHeight: closeHeight,
		Status:      MarketOpen,
		Outcome:     verdict.OutcomeUnresolved,
		Resolver:    resolver,
	}
	markets.Set(marketKey(id), market)
	return id
}
