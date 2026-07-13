// Package bountyboard is a GnoForge starter kit for posting and settling bounties.
//
// Coin flow (chain/banker — confirmed against local toolchain stdlibs):
//   FundBounty:    requires -send ugnot; OriginSend amount checked via escrow.MarkFunded
//   ReleaseBounty: realm sends FundedAmount ugnot to worker
//   RefundBounty / TimeoutRefundBounty: realm sends FundedAmount ugnot to client
//
// FLAG: Banker API uses chain/banker + chain/runtime/unsafe (not legacy std.*).
// If your toolchain still uses std.OriginSend / std.NewBanker, adjust imports.
package bountyboard

import (
	"chain"
	"chain/banker"
	"chain/runtime"
	"chain/runtime/unsafe"
	"strconv"
	"strings"
	"time"

	"gno.land/p/g16p08xxtyt320hjju7769lzguxlvzszwpg8duwl/escrow/v1"
	"gno.land/p/g16p08xxtyt320hjju7769lzguxlvzszwpg8duwl/roles/v0"
)

// DefaultTimeoutSecs: 7 days. 0 would disable timeout; kits should always set a
// positive timeout so funds cannot stick forever.
const DefaultTimeoutSecs int64 = 7 * 24 * 60 * 60

var (
	roleSet *roles.RoleSet
	deals   map[string]escrow.Deal
	order   []string
	nextID  int
	title   string
	inited  bool
	// boardTimeoutSecs applied to new bounties; admin can change.
	boardTimeoutSecs int64
)

func ensure() {
	if roleSet == nil {
		roleSet = roles.NewRoleSet()
	}
	if deals == nil {
		deals = map[string]escrow.Deal{}
	}
}

func nowUnix() int64 {
	return time.Now().Unix()
}

// InitBoard creates the board; caller is admin.
func InitBoard(cur realm, boardTitle string) string {
	ensure()
	if inited {
		panic("bountyboard: already initialized")
	}
	caller := cur.Previous().Address().String()
	title = boardTitle
	boardTimeoutSecs = DefaultTimeoutSecs
	roleSet.Grant(caller, "admin")
	inited = true
	return "ok"
}

// SetTimeoutSecs updates default timeout for new bounties (admin).
func SetTimeoutSecs(cur realm, secs int64) string {
	ensure()
	caller := cur.Previous().Address().String()
	roleSet.Require(caller, "admin")
	if secs < 0 {
		panic("bountyboard: timeout cannot be negative")
	}
	boardTimeoutSecs = secs
	return "ok"
}

// PostBounty opens a deal (client = caller). No coins yet.
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
	d := escrow.NewDeal(id, caller, worker, amountUgnot, bountyTitle, nowUnix(), boardTimeoutSecs)
	deals[id] = d
	order = append(order, id)
	return "bounty#" + id
}

// FundBounty locks OriginSend ugnot in this realm and marks the deal funded.
// Caller must be client and pass -send >= AmountUgnot.
func FundBounty(cur realm, id string) string {
	ensure()
	runtime.AssertOriginCall()
	caller := cur.Previous().Address().String()
	d, ok := deals[id]
	if !ok {
		panic("bountyboard: unknown bounty")
	}
	sent := unsafe.OriginSend()
	ugnot := sent.AmountOf("ugnot")
	// State machine validates party + underfunding; coins already sit on realm via -send.
	escrow.MarkFunded(&d, caller, ugnot, nowUnix())
	deals[id] = d
	return "funded"
}

// ReleaseBounty pays worker FundedAmount ugnot from realm balance.
func ReleaseBounty(cur realm, id string) string {
	ensure()
	runtime.AssertOriginCall()
	caller := cur.Previous().Address().String()
	d, ok := deals[id]
	if !ok {
		panic("bountyboard: unknown bounty")
	}
	escrow.Release(&d, caller, nowUnix())
	pay := escrow.PayoutAmount(&d)
	bk := banker.NewBanker(banker.BankerTypeRealmSend, cur)
	bk.SendCoins(cur.Address(), address(d.Worker), chain.Coins{{"ugnot", pay}})
	deals[id] = d
	return "released"
}

// RefundBounty returns FundedAmount ugnot to client.
func RefundBounty(cur realm, id string) string {
	ensure()
	runtime.AssertOriginCall()
	caller := cur.Previous().Address().String()
	d, ok := deals[id]
	if !ok {
		panic("bountyboard: unknown bounty")
	}
	escrow.Refund(&d, caller, nowUnix())
	pay := escrow.PayoutAmount(&d)
	bk := banker.NewBanker(banker.BankerTypeRealmSend, cur)
	bk.SendCoins(cur.Address(), address(d.Client), chain.Coins{{"ugnot", pay}})
	deals[id] = d
	return "refunded"
}

// TimeoutRefundBounty is permissionless after Deadline: refunds client.
func TimeoutRefundBounty(cur realm, id string) string {
	ensure()
	d, ok := deals[id]
	if !ok {
		panic("bountyboard: unknown bounty")
	}
	escrow.TimeoutRefund(&d, nowUnix())
	pay := escrow.PayoutAmount(&d)
	bk := banker.NewBanker(banker.BankerTypeRealmSend, cur)
	bk.SendCoins(cur.Address(), address(d.Client), chain.Coins{{"ugnot", pay}})
	deals[id] = d
	return "timeout-refunded"
}

// CancelBounty cancels an open bounty (no coins locked).
func CancelBounty(cur realm, id string) string {
	ensure()
	caller := cur.Previous().Address().String()
	d, ok := deals[id]
	if !ok {
		panic("bountyboard: unknown bounty")
	}
	escrow.Cancel(&d, caller, nowUnix())
	deals[id] = d
	return "cancelled"
}

// DisputeBounty flags a funded bounty; coins remain locked until admin policy (v0 holds funds).
func DisputeBounty(cur realm, id string) string {
	ensure()
	caller := cur.Previous().Address().String()
	d, ok := deals[id]
	if !ok {
		panic("bountyboard: unknown bounty")
	}
	escrow.Dispute(&d, caller, nowUnix())
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
	b.WriteString("Default timeout: **" + strconv.FormatInt(boardTimeoutSecs, 10) + "s**\n\n")
	b.WriteString("Bounties: **" + strconv.Itoa(len(order)) + "**\n\n")
	if len(order) == 0 {
		b.WriteString("_No bounties yet._\n")
	}
	for i := len(order) - 1; i >= 0; i-- {
		id := order[i]
		d := deals[id]
		b.WriteString("### #" + d.ID + " — " + d.Title + "\n\n")
		b.WriteString("- State: `" + escrow.StateString(d.State) + "`\n")
		b.WriteString("- Client: `" + d.Client + "`\n")
		b.WriteString("- Worker: `" + d.Worker + "`\n")
		b.WriteString("- Amount: `" + strconv.FormatInt(d.AmountUgnot, 10) + " ugnot`")
		if d.FundedAmount > 0 {
			b.WriteString(" (funded `" + strconv.FormatInt(d.FundedAmount, 10) + "`)")
		}
		b.WriteString("\n")
		if d.Deadline > 0 {
			b.WriteString("- Deadline: `" + strconv.FormatInt(d.Deadline, 10) + "`\n")
		}
		if d.Note != "" {
			b.WriteString("- Note: " + d.Note + "\n")
		}
		b.WriteString("\n")
	}
	b.WriteString("---\n*Powered by GnoForge `bountyboard` — real ugnot escrow via chain/banker*\n")
	return b.String()
}
