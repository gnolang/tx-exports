package bountyforge

import (
	"chain/runtime"
	"strconv"
	"strings"

	"gno.land/p/g10yuqyktt4777jn8rt3nmuhw4suz9mvypaec7ac/escrowmath"
	"gno.land/p/nt/avl/pager/v0"
	"gno.land/p/nt/avl/rotree/v0"
	"gno.land/p/nt/avl/v0"
	"gno.land/p/nt/seqid/v0"
)

// ---------------------------------------------------------------------------
// Read-Only View Functions (ABCI vm/qeval friendly for MCP & Adena Web dApp)
// ---------------------------------------------------------------------------

// TotalEscrowed returns the total ugnot currently locked across active bounties.
func TotalEscrowed() int64 {
	return totalEscrowed
}

// TotalPaidOut returns cumulative ugnot paid to builders across all settled bounties.
func TotalPaidOut() int64 {
	return totalPaidOut
}

// BountyCount returns total number of bounties created.
func BountyCount() int {
	return bounties.Size()
}

// BuilderXP returns the accumulated reputation XP for a builder address.
func BuilderXP(addr address) int64 {
	raw := builders.Get(addr.String())
	if raw == nil {
		return 0
	}
	return raw.(*BuilderProfile).XP
}

// ProtocolJSON returns deterministic JSON protocol metrics for MCP & web clients.
func ProtocolJSON() string {
	var b strings.Builder
	b.WriteString(`{"total_bounties":`)
	b.WriteString(strconv.Itoa(bounties.Size()))
	b.WriteString(`,"open":`)
	b.WriteString(strconv.Itoa(openCount))
	b.WriteString(`,"paid":`)
	b.WriteString(strconv.Itoa(paidCount))
	b.WriteString(`,"disputed":`)
	b.WriteString(strconv.Itoa(disputedCount))
	b.WriteString(`,"cancelled":`)
	b.WriteString(strconv.Itoa(cancelledCnt))
	b.WriteString(`,"total_escrowed_ugnot":`)
	b.WriteString(strconv.FormatInt(totalEscrowed, 10))
	b.WriteString(`,"total_paid_ugnot":`)
	b.WriteString(strconv.FormatInt(totalPaidOut, 10))
	b.WriteString(`,"builders":`)
	b.WriteString(strconv.Itoa(builders.Size()))
	b.WriteString(`,"block_height":`)
	b.WriteString(strconv.FormatInt(runtime.ChainHeight(), 10))
	b.WriteString(`,"review_grace_blocks":`)
	b.WriteString(strconv.FormatInt(ReviewGraceBlocks, 10))
	b.WriteString(`,"dispute_timeout_blocks":`)
	b.WriteString(strconv.FormatInt(DisputeTimeoutBlocks, 10))
	b.WriteByte('}')
	return b.String()
}

// BountyJSON returns deterministic JSON detail for a single bounty ID, or "{}" if not found.
func BountyJSON(id uint64) string {
	if id == 0 {
		return "{}"
	}
	raw := bounties.Get(seqid.ID(id).String())
	if raw == nil {
		return "{}"
	}
	return encodeBountyJSON(raw.(*Bounty), true)
}

// ListBountiesJSON returns a bounded paginated JSON payload of bounties (newest first).
// status may be "", "OPEN", "PAID", "DISPUTED", or "CANCELLED".
func ListBountiesJSON(status string, pageNum, pageSize int) string {
	filter := strings.ToUpper(strings.TrimSpace(status))
	tree := bounties
	if filter != "" {
		tree = statusTree(filter)
		if tree == nil {
			return `{"page":1,"total_pages":0,"total_items":0,"items":[]}`
		}
	}
	pageNum, pageSize = clampPaging(pageNum, pageSize)
	p := pager.NewPager(rotree.Wrap(tree, nil), pageSize, true)
	pg := p.GetPage(pageNum)

	var b strings.Builder
	b.WriteString(`{"page":`)
	b.WriteString(strconv.Itoa(pg.PageNumber))
	b.WriteString(`,"total_pages":`)
	b.WriteString(strconv.Itoa(pg.TotalPages))
	b.WriteString(`,"total_items":`)
	b.WriteString(strconv.Itoa(pg.TotalItems))
	b.WriteString(`,"items":[`)
	for i, item := range pg.Items {
		if i > 0 {
			b.WriteByte(',')
		}
		b.WriteString(encodeBountyJSON(item.Value.(*Bounty), false))
	}
	b.WriteString(`]}`)
	return b.String()
}

// LeaderboardJSON returns a bounded paginated JSON leaderboard directly from the
// O(log N) sorted AVL leaderboard index (zero sorting on query).
func LeaderboardJSON(pageNum, pageSize int) string {
	pageNum, pageSize = clampPaging(pageNum, pageSize)
	p := pager.NewPager(rotree.Wrap(leaderboard, nil), pageSize, false)
	pg := p.GetPage(pageNum)

	var b strings.Builder
	b.WriteString(`{"page":`)
	b.WriteString(strconv.Itoa(pg.PageNumber))
	b.WriteString(`,"total_pages":`)
	b.WriteString(strconv.Itoa(pg.TotalPages))
	b.WriteString(`,"total_items":`)
	b.WriteString(strconv.Itoa(pg.TotalItems))
	b.WriteString(`,"items":[`)
	rankOffset := (pageNum - 1) * pageSize
	for i, item := range pg.Items {
		if i > 0 {
			b.WriteByte(',')
		}
		prof := item.Value.(*BuilderProfile)
		tier, badge := escrowmath.TierForXP(prof.XP)
		b.WriteString(`{"rank":`)
		b.WriteString(strconv.Itoa(rankOffset + i + 1))
		b.WriteString(`,"address":`)
		b.WriteString(jsonString(prof.Address.String()))
		b.WriteString(`,"tier":`)
		b.WriteString(jsonString(tier))
		b.WriteString(`,"badge":`)
		b.WriteString(jsonString(badge))
		b.WriteString(`,"color":`)
		b.WriteString(jsonString(escrowmath.TierColor(prof.XP)))
		b.WriteString(`,"xp":`)
		b.WriteString(strconv.FormatInt(prof.XP, 10))
		b.WriteString(`,"completed":`)
		b.WriteString(strconv.Itoa(prof.Completed))
		b.WriteString(`,"unique_creators":`)
		b.WriteString(strconv.Itoa(prof.UniqueCreators()))
		b.WriteString(`,"total_earned_ugnot":`)
		b.WriteString(strconv.FormatInt(prof.TotalEarned, 10))
		b.WriteString(`,"last_height":`)
		b.WriteString(strconv.FormatInt(prof.LastHeight, 10))
		b.WriteByte('}')
	}
	b.WriteString(`]}`)
	return b.String()
}

// BuilderJSON returns a single builder's JSON profile + tier metadata.
func BuilderJSON(addr address) string {
	if !addr.IsValid() {
		return "{}"
	}
	raw := builders.Get(addr.String())
	var prof *BuilderProfile
	if raw != nil {
		prof = raw.(*BuilderProfile)
	} else {
		prof = &BuilderProfile{Address: addr}
	}
	tier, badge := escrowmath.TierForXP(prof.XP)
	var b strings.Builder
	b.WriteString(`{"address":`)
	b.WriteString(jsonString(prof.Address.String()))
	b.WriteString(`,"tier":`)
	b.WriteString(jsonString(tier))
	b.WriteString(`,"badge":`)
	b.WriteString(jsonString(badge))
	b.WriteString(`,"color":`)
	b.WriteString(jsonString(escrowmath.TierColor(prof.XP)))
	b.WriteString(`,"xp":`)
	b.WriteString(strconv.FormatInt(prof.XP, 10))
	b.WriteString(`,"completed":`)
	b.WriteString(strconv.Itoa(prof.Completed))
	b.WriteString(`,"unique_creators":`)
	b.WriteString(strconv.Itoa(prof.UniqueCreators()))
	b.WriteString(`,"total_earned_ugnot":`)
	b.WriteString(strconv.FormatInt(prof.TotalEarned, 10))
	b.WriteString(`,"last_height":`)
	b.WriteString(strconv.FormatInt(prof.LastHeight, 10))
	b.WriteByte('}')
	return b.String()
}

func clampPaging(pageNum, pageSize int) (int, int) {
	if pageNum < 1 {
		pageNum = 1
	}
	if pageSize <= 0 {
		pageSize = DefaultPageSize
	}
	if pageSize > MaxPageSize {
		pageSize = MaxPageSize
	}
	return pageNum, pageSize
}

func encodeBountyJSON(bty *Bounty, detailed bool) string {
	var b strings.Builder
	b.WriteString(`{"id":`)
	b.WriteString(strconv.FormatUint(bty.ID, 10))
	b.WriteString(`,"title":`)
	b.WriteString(jsonString(bty.Title))
	if detailed {
		b.WriteString(`,"summary":`)
		b.WriteString(jsonString(bty.Summary))
	}
	b.WriteString(`,"tags":`)
	b.WriteString(jsonString(bty.Tags))
	b.WriteString(`,"creator":`)
	b.WriteString(jsonString(bty.Creator.String()))
	b.WriteString(`,"arbiter":`)
	b.WriteString(jsonString(bty.Arbiter.String()))
	b.WriteString(`,"reward_ugnot":`)
	b.WriteString(strconv.FormatInt(bty.RewardUgnot, 10))
	b.WriteString(`,"status":`)
	b.WriteString(jsonString(bty.Status))
	b.WriteString(`,"created_height":`)
	b.WriteString(strconv.FormatInt(bty.CreatedHeight, 10))
	b.WriteString(`,"deadline_height":`)
	b.WriteString(strconv.FormatInt(bty.DeadlineH, 10))
	b.WriteString(`,"active_submissions":`)
	b.WriteString(strconv.Itoa(bty.activeSubmissionCount()))
	b.WriteString(`,"sponsor_count":`)
	b.WriteString(strconv.Itoa(len(bty.Contributions)))

	if detailed {
		b.WriteString(`,"dispute_reason":`)
		b.WriteString(jsonString(bty.DisputeReason))
		b.WriteString(`,"dispute_opened_height":`)
		b.WriteString(strconv.FormatInt(bty.DisputeOpenedH, 10))

		b.WriteString(`,"contributions":[`)
		for i, c := range bty.Contributions {
			if i > 0 {
				b.WriteByte(',')
			}
			b.WriteString(`{"sponsor":`)
			b.WriteString(jsonString(c.Sponsor.String()))
			b.WriteString(`,"amount_ugnot":`)
			b.WriteString(strconv.FormatInt(c.Amount, 10))
			b.WriteByte('}')
		}
		b.WriteString(`],"submissions":[`)
		for i, s := range bty.Submissions {
			if i > 0 {
				b.WriteByte(',')
			}
			b.WriteString(`{"index":`)
			b.WriteString(strconv.Itoa(s.Index))
			b.WriteString(`,"builder":`)
			b.WriteString(jsonString(s.Builder.String()))
			b.WriteString(`,"proof_url":`)
			b.WriteString(jsonString(s.ProofURL))
			b.WriteString(`,"notes":`)
			b.WriteString(jsonString(s.Notes))
			b.WriteString(`,"submitted_height":`)
			b.WriteString(strconv.FormatInt(s.SubmittedH, 10))
			b.WriteString(`,"via_session":`)
			b.WriteString(strconv.FormatBool(s.ViaSession))
			b.WriteString(`,"withdrawn":`)
			b.WriteString(strconv.FormatBool(s.Withdrawn))
			b.WriteByte('}')
		}
		b.WriteString(`],"payouts":[`)
		for i, p := range bty.Payouts {
			if i > 0 {
				b.WriteByte(',')
			}
			b.WriteString(`{"recipient":`)
			b.WriteString(jsonString(p.Recipient.String()))
			b.WriteString(`,"amount_ugnot":`)
			b.WriteString(strconv.FormatInt(p.Amount, 10))
			b.WriteString(`,"bps":`)
			b.WriteString(strconv.FormatInt(p.Bps, 10))
			b.WriteByte('}')
		}
		b.WriteString(`],"refunds":[`)
		for i, r := range bty.Refunds {
			if i > 0 {
				b.WriteByte(',')
			}
			b.WriteString(`{"sponsor":`)
			b.WriteString(jsonString(r.Sponsor.String()))
			b.WriteString(`,"amount_ugnot":`)
			b.WriteString(strconv.FormatInt(r.Amount, 10))
			b.WriteByte('}')
		}
		b.WriteByte(']')
	}
	b.WriteByte('}')
	return b.String()
}

func jsonString(s string) string {
	var b strings.Builder
	b.Grow(len(s) + 2)
	b.WriteByte('"')
	for i := 0; i < len(s); i++ {
		c := s[i]
		switch c {
		case '"':
			b.WriteString(`\"`)
		case '\\':
			b.WriteString(`\\`)
		case '\b':
			b.WriteString(`\b`)
		case '\f':
			b.WriteString(`\f`)
		case '\n':
			b.WriteString(`\n`)
		case '\r':
			b.WriteString(`\r`)
		case '\t':
			b.WriteString(`\t`)
		default:
			if c < 0x20 {
				b.WriteString(`\u00`)
				const hex = "0123456789abcdef"
				b.WriteByte(hex[c>>4])
				b.WriteByte(hex[c&0x0f])
			} else {
				b.WriteByte(c)
			}
		}
	}
	b.WriteByte('"')
	return b.String()
}

// Keep avl import referenced cleanly if needed.
var _ *avl.Tree
