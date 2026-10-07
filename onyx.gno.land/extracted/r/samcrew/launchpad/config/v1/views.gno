package config

import (
	"strconv"

	"gno.land/p/samcrew/launchpad/meta/v1"
)

// ActionStatusJSON reports only the current config gate for a new action.
// Other realm, custody and publication requirements are separate.
func ActionStatusJSON(lane, currency string) string {
	if !validLane(lane) || currency == "" || len(currency) > 200 {
		panic("launchpad/config: invalid action status query")
	}
	blocked := IsPaused(lane)
	allowlisted := IsCurrencyAllowed(currency)
	ready := IsLaneReady(lane, currency)
	return "{" +
		`"schema":"launchpad-config-action-v1"` +
		`,"lane":` + meta.JSONString(lane) +
		`,"currency":` + meta.JSONString(currency) +
		`,"version":` + meta.JSONString(strconv.FormatInt(GetCurrentVersion(), 10)) +
		`,"paused":` + strconv.FormatBool(blocked) +
		`,"allowlisted":` + strconv.FormatBool(allowlisted) +
		`,"laneReady":` + strconv.FormatBool(ready) +
		`,"configGateOpen":` + strconv.FormatBool(!blocked && allowlisted && ready) + "}"
}
