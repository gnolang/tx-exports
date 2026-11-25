package bellica

import (
	"gno.land/p/g1ac3v8vr4ddr2m7g68gkksz3f463v9x95w05pnl/bellica/api/v1"
	"gno.land/p/g1ac3v8vr4ddr2m7g68gkksz3f463v9x95w05pnl/bellica/core/v1"
)

// BountyJSON returns one bounty with its entries as JSON.
func BountyJSON(id int) string {
	return api.BountyJSON(db, core.MustBounty(db, id), true)
}

// OpenBountiesJSON returns live (open) bounties as JSON, for agents and gnomcp gno_eval.
func OpenBountiesJSON() string {
	return api.OpenBountiesJSON(db)
}
