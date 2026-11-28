package verdict

import (
	"chain/banker"
	"chain/runtime"
	"math/overflow"
	"strconv"
	"strings"

	verdict "gno.land/p/g1pymrz428hx9fwat04ahwxe9y9hlvetjw7y0p2t/verdict"
	counter "gno.land/r/g1pymrz428hx9fwat04ahwxe9y9hlvetjw7y0p2t/verdict_counter"
)

func readConfiguredState(config ResolverConfig) int64 {
	switch config.Kind {
	case ResolverBalance:
		return banker.NewReadonlyBanker().GetCoin(address(config.Target), "ugnot")
	case ResolverCounter:
		return counter.Count()
	default:
		panic("unsupported resolver")
	}
}

func resolveOutcome(market Market) verdict.Outcome {
	if runtime.ChainHeight() < market.CloseHeight {
		panic("settlement not ready")
	}

	actual := readConfiguredState(market.Resolver)
	outcome := verdict.OutcomeNo
	if actual >= market.Resolver.TargetAmount {
		outcome = verdict.OutcomeYes
	}
	if outcome == verdict.OutcomeYes && market.YesPool == 0 {
		outcome = verdict.OutcomeInvalid
	}
	if outcome == verdict.OutcomeNo && market.NoPool == 0 {
		outcome = verdict.OutcomeInvalid
	}
	return outcome
}

func resolverDescription(market Market) string {
	var b strings.Builder
	b.WriteString("At settlement on or after block ")
	b.WriteString(strconv.FormatInt(market.CloseHeight, 10))
	if market.Resolver.Kind == ResolverBalance {
		b.WriteString(", resolves YES when ")
		b.WriteString(market.Resolver.Target)
		b.WriteString(" holds at least ")
		b.WriteString(strconv.FormatInt(market.Resolver.TargetAmount, 10))
		b.WriteString(" ugnot.")
	} else {
		b.WriteString(", resolves YES when the Verdict reference counter is at least ")
		b.WriteString(strconv.FormatInt(market.Resolver.TargetAmount, 10))
		b.WriteString(".")
	}
	return b.String()
}

func totalPool(market Market) int64 {
	total, ok := overflow.Add64(market.YesPool, market.NoPool)
	if !ok {
		panic("pool overflow")
	}
	return total
}

func winningPoolFor(market Market, outcome verdict.Outcome) int64 {
	switch outcome {
	case verdict.OutcomeYes:
		return market.YesPool
	case verdict.OutcomeNo:
		return market.NoPool
	default:
		return 0
	}
}
