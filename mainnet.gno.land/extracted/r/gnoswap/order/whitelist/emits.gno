package whitelist

import (
	"chain"

	"gno.land/p/gnoswap/utils/v1"
)

func emitPoolUpdated(_ int, prev realm, target, poolPath string, whitelisted bool) {
	chain.Emit(
		"OrderWhitelistedPoolUpdated",
		"prevAddr", prev.Address().String(),
		"prevRealm", prev.PkgPath(),
		"target", target,
		"poolPath", poolPath,
		"whitelisted", utils.FormatBool(whitelisted),
	)
}
