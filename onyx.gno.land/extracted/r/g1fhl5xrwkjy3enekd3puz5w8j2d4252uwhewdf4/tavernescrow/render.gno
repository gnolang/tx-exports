package tavernescrow

import (
	"chain/runtime"
	"strconv"
	"strings"

	"gno.land/p/nt/ufmt/v0"
)

// Render serves deterministic gnoweb markdown views for:
//   - "" or "/"           : TavernEscrow board & TVL dashboard
//   - "bounty/<id>"       : Individual bounty milestones & deliverables
//   - "audit"             : Tamper-evident SHA-256 chained audit ledger
//   - "safety"            : Realm security invariants & threat-class matrix
func Render(path string) string {
	clean := strings.Trim(strings.TrimSpace(path), "/")
	if clean == "" {
		return renderHome()
	}

	parts := strings.Split(clean, "/")
	switch {
	case len(parts) == 2 && parts[0] == "bounty":
		id, err := strconv.ParseUint(parts[1], 10, 64)
		if err != nil || id == 0 {
			return "# 404 — Invalid Bounty ID\n\nExpected `/r/g1fhl5xrwkjy3enekd3puz5w8j2d4252uwhewdf4/tavernescrow:bounty/<id>`."
		}
		return renderBounty(id)
	case len(parts) == 1 && parts[0] == "audit":
		return renderAudit()
	case len(parts) == 1 && parts[0] == "safety":
		return renderSafety()
	default:
		return "# 404 — Route Not Found\n\nAvailable routes: `/`, `bounty/<id>`, `audit`, `safety`."
	}
}

func renderHome() string {
	var sb strings.Builder
	sb.WriteString("# TavernEscrow — Milestone Bounty & Dispute Realm\n\n")
	sb.WriteString("Deterministic multi-milestone `ugnot` escrow on Gno.land with checks-effects-interactions accounting, neutral arbiter dispute settlement, expiry reclaim, and a chained SHA-256 audit log.\n\n")

	sb.WriteString("| Metric | Value |\n")
	sb.WriteString("|---|---|\n")
	sb.WriteString(ufmt.Sprintf("| Chain / Height | `%s` @ `#%d` |\n", runtime.ChainID(), runtime.ChainHeight()))
	sb.WriteString(ufmt.Sprintf("| Active & Historical Bounties | `%d` |\n", bountiesByID.Size()))
	sb.WriteString(ufmt.Sprintf("| Total Funded | `%d ugnot` |\n", totalFundedUgnot))
	sb.WriteString(ufmt.Sprintf("| Currently Locked TVL | `%d ugnot` |\n", totalLockedUgnot))
	sb.WriteString(ufmt.Sprintf("| Released to Builders | `%d ugnot` |\n", totalReleasedUgnot))
	sb.WriteString(ufmt.Sprintf("| Refunded to Sponsors | `%d ugnot` |\n", totalRefundedUgnot))
	sb.WriteString(ufmt.Sprintf("| Audit Chain Head | `%s` |\n\n", shortDigest(latestAuditDigest)))

	sb.WriteString("## Navigation\n\n")
	sb.WriteString("- [Audit Ledger (:audit)](/r/g1fhl5xrwkjy3enekd3puz5w8j2d4252uwhewdf4/tavernescrow:audit)\n")
	sb.WriteString("- [Security Invariants (:safety)](/r/g1fhl5xrwkjy3enekd3puz5w8j2d4252uwhewdf4/tavernescrow:safety)\n\n")

	sb.WriteString("## Bounties Board\n\n")
	if bountiesByID.Size() == 0 {
		sb.WriteString("_No bounties funded yet. Call `CreateBounty` with `-send <sum>ugnot` to open the first milestone escrow._\n")
		return sb.String()
	}

	sb.WriteString("| ID | Title | Status | Funded | Locked | Expiry | Detail |\n")
	sb.WriteString("|---|---|---|---|---|---|---|\n")
	bountiesByID.ReverseIterate("", "", func(_ string, val any) bool {
		b := val.(*Bounty)
		sb.WriteString(ufmt.Sprintf(
			"| #%d | %s | `%s` | %d | %d | #%d | [View](:bounty/%d) |\n",
			b.ID,
			b.Title,
			string(b.Status),
			b.TotalFunded,
			b.lockedRemaining(),
			b.ExpiryHeight,
			b.ID,
		))
		return false
	})

	sb.WriteString("\n## Recent Audit Trail\n\n")
	sb.WriteString(renderAuditTable(5))
	return sb.String()
}

func renderBounty(id uint64) string {
	b, ok := bountiesByID.Get(padUint64Key(id)).(*Bounty)
	if !ok || b == nil {
		return ufmt.Sprintf("# 404 — Bounty #%d Not Found\n\n[Back to TavernEscrow](:)", id)
	}

	var sb strings.Builder
	sb.WriteString(ufmt.Sprintf("# Bounty #%d — %s\n\n", b.ID, b.Title))
	sb.WriteString(b.Summary + "\n\n")

	workerStr := "_Open for claim_"
	if b.Worker != "" {
		workerStr = "`" + b.Worker.String() + "`"
	}
	arbiterStr := "_None configured_"
	if b.Arbiter != "" {
		arbiterStr = "`" + b.Arbiter.String() + "`"
	}

	sb.WriteString("| Field | Value |\n")
	sb.WriteString("|---|---|\n")
	sb.WriteString(ufmt.Sprintf("| Status | `%s` |\n", string(b.Status)))
	sb.WriteString(ufmt.Sprintf("| Sponsor | `%s` |\n", b.Sponsor.String()))
	sb.WriteString(ufmt.Sprintf("| Builder | %s |\n", workerStr))
	sb.WriteString(ufmt.Sprintf("| Arbiter | %s |\n", arbiterStr))
	sb.WriteString(ufmt.Sprintf("| Total Funded | `%d ugnot` |\n", b.TotalFunded))
	sb.WriteString(ufmt.Sprintf("| Released / Refunded | `%d / %d ugnot` |\n", b.ReleasedAmount, b.RefundedAmount))
	sb.WriteString(ufmt.Sprintf("| Remaining Locked | `%d ugnot` |\n", b.lockedRemaining()))
	sb.WriteString(ufmt.Sprintf("| Created / Expiry Block | `#%d -> #%d` |\n\n", b.CreatedAtBlk, b.ExpiryHeight))

	sb.WriteString("## Milestones\n\n")
	sb.WriteString("| # | Deliverable | Amount (ugnot) | Status | Proof URI | Digest / Note |\n")
	sb.WriteString("|---|---|---|---|---|---|\n")
	for _, m := range b.Milestones {
		proof := "-"
		if m.ProofURI != "" {
			proof = "`" + m.ProofURI + "`"
		}
		note := m.CommitDigest
		if m.FeedbackNote != "" {
			if note != "" {
				note += " · "
			}
			note += m.FeedbackNote
		}
		if note == "" {
			note = "-"
		}
		sb.WriteString(ufmt.Sprintf(
			"| %d | %s | %d | `%s` | %s | %s |\n",
			m.Index,
			m.Title,
			m.AmountUgnot,
			string(m.Status),
			proof,
			note,
		))
	}

	sb.WriteString("\n[Back to Board](:) · [Audit Ledger](:audit)\n")
	return sb.String()
}

func renderAudit() string {
	var sb strings.Builder
	sb.WriteString("# TavernEscrow — Tamper-Evident Audit Ledger\n\n")
	sb.WriteString(ufmt.Sprintf("Chain head digest: `%s`\n\n", latestAuditDigest))
	sb.WriteString(renderAuditTable(50))
	sb.WriteString("\n[Back to Board](:)\n")
	return sb.String()
}

func renderAuditTable(limit int) string {
	if auditsBySeq.Size() == 0 {
		return "_No audit entries recorded._\n"
	}
	var sb strings.Builder
	sb.WriteString("| Seq | Block | Action | Bounty | Actor | Amount | Digest |\n")
	sb.WriteString("|---|---|---|---|---|---|---|\n")
	count := 0
	auditsBySeq.ReverseIterate("", "", func(_ string, val any) bool {
		e := val.(*AuditEntry)
		sb.WriteString(ufmt.Sprintf(
			"| #%d | %d | `%s` | #%d | `%s` | %d | `%s` |\n",
			e.Seq,
			e.Height,
			e.Action,
			e.BountyID,
			shortAddr(e.Actor),
			e.AmountUgnot,
			shortDigest(e.Digest),
		))
		count++
		return count >= limit
	})
	return sb.String()
}

func renderSafety() string {
	var sb strings.Builder
	sb.WriteString("# TavernEscrow — Security Invariants\n\n")
	sb.WriteString("1. **EOA Payment Boundary (`IsUserCall()` + `OriginSend()`):** `CreateBounty` rejects intermediate code realms and `MsgRun` scripts so `-send` coins always land at the realm address.\n")
	sb.WriteString("2. **Checks-Effects-Interactions:** Milestone status, global TVL counters, and SHA-256 audit entries commit before `banker.SendCoins`.\n")
	sb.WriteString("3. **Overflow & Underflow Guards:** All `int64` `ugnot` additions and subtractions validate `0 <= amount <= MaxInt64`.\n")
	sb.WriteString("4. **Role Separation & Dispute Lock:** Sponsor, Worker, and Arbiter must be distinct addresses; `ReclaimExpired` cannot bypass an active `DISPUTED` bounty.\n")
	sb.WriteString("5. **No Mutable Pointer Leakage:** Public getters return value-copied snapshots (`BountyView`, `RealmStats`), never `*avl.Tree` or `*Bounty` pointers.\n\n")
	sb.WriteString("[Back to Board](:)\n")
	return sb.String()
}

func shortDigest(d string) string {
	if len(d) <= 16 {
		return d
	}
	return d[:10] + "..." + d[len(d)-6:]
}

func shortAddr(a address) string {
	s := a.String()
	if len(s) <= 14 {
		return s
	}
	return s[:8] + "..." + s[len(s)-4:]
}
