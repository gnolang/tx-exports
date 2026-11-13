package whitelist

import (
	pwhitelist "gno.land/p/gnoswap/order/whitelist/v0"
)

var (
	dcaState   pwhitelist.State
	limitState pwhitelist.State
)

func init() {
	resetState()
}

func resetState() {
	dcaState = pwhitelist.NewState()
	limitState = pwhitelist.NewState()
}

func getState(target string) *pwhitelist.State {
	assertIsValidTarget(target)

	if target == TargetDCA {
		return &dcaState
	}

	return &limitState
}
