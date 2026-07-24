// Package bountyboard is a GnoForge starter kit for posting and settling bounties.
// Uses escrow state machine types; coin movement is declarative in v0 (metadata).
// Wire real ugnot transfers when mainnet transfers / Banker patterns are stable.
package bountyboard

import (
	"strconv"
	"strings"

	"gno.land/p/g16p08xxtyt320hjju7769lzguxlvzszwpg8duwl/escrow/v0"
	"gno.land/p/g16p08xxtyt320hjju7769lzguxlvzszwpg8duwl/roles/v0"
)

var (
	roleSet  *roles.RoleSet
	deals    map[string]escrow.Deal
	order    []string
	nextID   int
	title    string
	inited   bool
)

func ensure() {
	if roleSet == nil {
		roleSet = roles.NewRoleSet()
	}
	if deals == nil {
		deals = map[string]escrow.Deal{}
	}
}

// InitBoard creates the board; caller is admin.
func InitBoard(cur realm, boardTitle string) string {
	ensure()
	if inited {
		panic("bountyboard: already initialized")
	}
	caller := cur.Previous().Address().String()
	title = boardTitle
	roleSet.Grant(caller, "admin")
	inited = true
	return "ok"
}

// PostBounty opens a deal (client = caller).
func PostBounty(cur realm, worker string, amountUgnot int64, bountyTitle string) string {
	ensure()
	if !inited {
		panic("bountyboard: not initialized")
	}
	caller := cur.Previous().Address().String()
	if worker == "" || amountUgnot <= 0 {
		panic("bountyboard: invalid worker or amount")
	}
	nextID++
	id := strconv.Itoa(nextID)
	d := escrow.NewDeal(id, caller, worker, amountUgnot, bountyTitle, 0)
	deals[id] = d
	order = append(order, id)
	return "bounty#" + id
}

// FundBounty marks deal funded (client). Attach real payment in a later version.
func FundBounty(cur realm, id string) string {
	ensure()
	caller := cur.Previous().Address().String()
	d, ok := deals[id]
	if !ok {
		panic("bountyboard: unknown bounty")
	}
	escrow.MarkFunded(&d, caller, 0)
	deals[id] = d
	return "funded"
}

// ReleaseBounty pays worker conceptually (client).
func ReleaseBounty(cur realm, id string) string {
	ensure()
	caller := cur.Previous().Address().String()
	d, ok := deals[id]
	if !ok {
		panic("bountyboard: unknown bounty")
	}
	escrow.Release(&d, caller, 0)
	deals[id] = d
	return "released"
}

// RefundBounty refunds client conceptually.
func RefundBounty(cur realm, id string) string {
	ensure()
	caller := cur.Previous().Address().String()
	d, ok := deals[id]
	if !ok {
		panic("bountyboard: unknown bounty")
	}
	escrow.Refund(&d, caller, 0)
	deals[id] = d
	return "refunded"
}

// CancelBounty cancels an open bounty.
func CancelBounty(cur realm, id string) string {
	ensure()
	caller := cur.Previous().Address().String()
	d, ok := deals[id]
	if !ok {
		panic("bountyboard: unknown bounty")
	}
	escrow.Cancel(&d, caller, 0)
	deals[id] = d
	return "cancelled"
}

// DisputeBounty flags a funded bounty.
func DisputeBounty(cur realm, id string) string {
	ensure()
	caller := cur.Previous().Address().String()
	d, ok := deals[id]
	if !ok {
		panic("bountyboard: unknown bounty")
	}
	escrow.Dispute(&d, caller, 0)
	deals[id] = d
	return "disputed"
}

// Render board listing.
func Render(_ string) string {
	ensure()
	if !inited {
		return "# Bounty Board Kit\n\nNot initialized. Call `InitBoard`.\n\n*GnoForge starter kit*"
	}
	var b strings.Builder
	b.WriteString("# " + title + "\n\n")
	b.WriteString("Bounties: **" + strconv.Itoa(len(order)) + "**\n\n")
	if len(order) == 0 {
		b.WriteString("_No bounties yet._\n")
	}
	for i := len(order) - 1; i >= 0; i-- {
		id := order[i]
		d := deals[id]
		b.WriteString("### #" + d.ID + " â€” " + d.Title + "\n\n")
		b.WriteString("- State: `" + escrow.StateString(d.State) + "`\n")
		b.WriteString("- Client: `" + d.Client + "`\n")
		b.WriteString("- Worker: `" + d.Worker + "`\n")
		b.WriteString("- Amount: `" + strconv.FormatInt(d.AmountUgnot, 10) + " ugnot` (metadata)\n\n")
	}
	b.WriteString("---\n*Powered by GnoForge `bountyboard` kit â€” wire real transfers before production use*\n")
	return b.String()
}
