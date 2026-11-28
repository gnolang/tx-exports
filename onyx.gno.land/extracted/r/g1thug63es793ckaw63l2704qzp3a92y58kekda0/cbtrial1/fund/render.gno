package fund

import (
	"strconv"
	"strings"

	"gno.land/p/nt/markdown/sanitize/v0"
	"gno.land/p/nt/ufmt/v0"

	"gno.land/r/g1thug63es793ckaw63l2704qzp3a92y58kekda0/cbtrial1/tusd"
)

const (
	trailPageSize   = 20
	historyPageSize = 12
)

const banner = "> **Test deployment on the Onyx testnet.** Fictional fund and parties, test tokens without value. Not operated by any regulated firm. Unaudited code. Not an offer.\n\n"

// Render is the fund's portal. No page shows an investor address or a
// wallet's compliance detail.
func Render(path string) string {
	parts := strings.Split(path, "/")
	if parts[0] == "note" || parts[0] == "notes" || parts[0] == "statement" {
		return renderNotePage(parts)
	}
	page := 1
	if len(parts) == 2 {
		n, err := strconv.Atoi(parts[1])
		if err != nil || n < 1 {
			return "invalid page"
		}
		page = n
	} else if len(parts) > 2 {
		return "404"
	}
	switch parts[0] {
	case "":
		return renderHome()
	case "terms":
		return renderTerms()
	case "memorandum":
		return renderMemo()
	case "desk":
		return renderDesk()
	case "trail":
		return renderTrail(page)
	case "history":
		return renderHistory(page)
	case "lists":
		return renderLists(page)
	}
	return "404"
}

func nav() string {
	h := home()
	return "[Factsheet](" + h + ") · [Terms](" + h + ":terms) · [Memorandum](" + h + ":memorandum) · [Desk](" + h + ":desk) · [NAV history](" + h + ":history) · [Sanctions lists](" + h + ":lists) · [Trail](" + h + ":trail)\n\n"
}

func home() string { return strings.TrimPrefix(selfPath, "gno.land") }

// link builds a gnoweb transaction link (GnoConnect). Arguments are digits,
// hex or bech32 only, so they need no URL encoding.
func link(fn string, kv ...string) string {
	s := home() + "$help&func=" + fn
	for i := 0; i+1 < len(kv); i += 2 {
		s += "&" + kv[i] + "=" + kv[i+1]
	}
	return s
}

func cell(s string) string { return sanitize.TableCell(s) }

func renderHome() string {
	var b strings.Builder
	b.WriteString("# " + FundName + "\n\n" + banner + nav())
	b.WriteString("A demonstration fund whose dealing terms are enforced by code. Investors subscribe and redeem in Test Dollar at a NAV that two parties have signed. ")
	b.WriteString("A screening agent checks every investor against the public sanctions lists and may recommend, but never decide. ")
	b.WriteString("Investors hold shares directly, or through the nominee, which keeps investor wallets out of the register.\n\n")
	b.WriteString("## Now\n\n")
	b.WriteString(ufmt.Sprintf("- Dealing period: **%d**, %s\n", cur0.n, stateNames[cur0.state]))
	if lastNAVps > 0 {
		b.WriteString("- Last approved NAV per share: **" + fmtAmt(lastNAVps) + " tUSD**\n")
	}
	b.WriteString("- NAV after the last settlement: " + fmtAmt(lastNAV) + " tUSD\n")
	b.WriteString("- Shares in issue: " + fmtAmt(sharesInIssue) + ufmt.Sprintf(" (nominee: %d sub-accounts, %s shares)\n", nomineeAccounts, fmtAmt(nomineeShares)))
	b.WriteString("- Cash (recorded): " + fmtAmt(bookCash) + " tUSD · in escrow: " + fmtAmt(escrowBook) + " tUSD\n")
	if totalOwed > 0 {
		b.WriteString("- Fees and expenses owed: " + fmtAmt(totalOwed) + " tUSD\n")
	}
	if totalHeld > 0 {
		b.WriteString("- Wind-down payments held for restricted holders (out of NAV): " + fmtAmt(totalHeld) + " tUSD\n")
	}
	if cur0.state == stateClosed {
		b.WriteString("- **The fund is closed.** This page shows its final record.\n")
	}
	if windingDown {
		b.WriteString("- **In wind-down** (" + windDownReason + "): no new subscriptions or investments; each period all available cash is paid out pro rata. Instruments still to sell: " + fmtAmt(instrumentsTotal()) + " tUSD at book value.\n")
	} else if windDownApproved {
		b.WriteString("- **Wind-down approved:** it starts at this period's cut-off.\n")
	}
	if isSuspended() {
		b.WriteString(ufmt.Sprintf("- **Dealing suspended** until unix time %d; orders wait for the first NAV after the suspension.\n", suspendedUntil))
	}
	if subscriptionsClosed {
		b.WriteString("- Closed to new subscriptions; redemptions continue.\n")
	}
	if stalled() {
		b.WriteString("- **This period has stalled for more than 7 days: subscribers may take their money back out of escrow.**\n")
	}
	b.WriteString("\n## Holdings\n\n| Instrument | Description | Book value (tUSD) |\n|---|---|---:|\n")
	for _, n := range instrOrder {
		in := getInstrument(n)
		b.WriteString("| " + in.name + " | " + cell(in.label) + " | " + fmtAmt(in.book) + " |\n")
	}
	b.WriteString("| Cash | Test Dollar | " + fmtAmt(bookCash) + " |\n")
	b.WriteString("\n## Recent NAVs\n\n")
	writeHistory(&b, 0, historyPageSize)
	b.WriteString("\n[Full NAV history](" + home() + ":history)\n\n## Oracles\n\n")
	b.WriteString("- Compliance officer: " + addrOr(officer) + "\n- Screening agent session: " + addrOr(agentSession) + "\n")
	b.WriteString("- Administrator: " + addrOr(administrator) + " · Independent valuation reviewer: " + addrOr(reviewer) + "\n- Manager: " + addrOr(manager) + "\n")
	if nomineePath != "" {
		b.WriteString("- Nominee: [" + strings.TrimPrefix(nomineePath, "gno.land") + "](" + strings.TrimPrefix(nomineePath, "gno.land") + ")\n")
	}
	b.WriteString(ufmt.Sprintf("- Direct-route compliance decisions with an agent screening on file: %d · without: %d (totals only)\n", decisionsScreened, decisionsUnscreened))
	b.WriteString(ufmt.Sprintf("- Sanctions-list snapshots recorded: %d ([lists](%s:lists))\n", listSeq, home()))
	b.WriteString("- Auditor: " + addrOr(auditor) + "\n")
	if st := auditStatus(); len(st) > 0 {
		b.WriteString("\n## Audited annual reports\n\n| Year | Status | SHA-256 |\n|---:|---|---|\n")
		for _, line := range st {
			b.WriteString(line + "\n")
		}
	}
	b.WriteString("\n## Invest directly\n\n")
	b.WriteString("1. Ask the compliance officer to find your wallet eligible.\n")
	b.WriteString("2. On [Test Dollar](" + strings.TrimPrefix(tusd.Path(), "gno.land") + "), call `Approve` for this fund's address `" + fundAddr().String() + "` and the amount.\n")
	b.WriteString("3. [Subscribe one lot](" + link("Subscribe", "amount", strconv.FormatInt(Lot, 10)) + ") · [Redeem one lot](" + link("RequestRedemption", "lots", "1") + ") · [Redeem everything](" + link("RequestRedemption", "lots", "0") + ")\n\n")
	b.WriteString("Memorandum v" + MemoVersion + ", SHA-256 `" + memorandumHash() + "`. Fund accounts: cash `" + cashAddr().String() + "`, escrow `" + escrowAddr().String() + "`.\n")
	return b.String()
}

func renderTerms() string {
	var b strings.Builder
	b.WriteString("# Terms\n\n" + banner + nav())
	b.WriteString("The figures below are formatted from the constants the code enforces.\n\n| Term | Value |\n|---|---|\n")
	rows := [][2]string{
		{"Dealing currency", "Test Dollar (tUSD), registry key " + cell(tusd.TokenKey())},
		{"Dealing", ufmt.Sprintf("monthly: subscriptions and redemptions in the same period, at its NAV; cut off by the administrator, or by anyone after %d days", PeriodSeconds/86400)},
		{"Lot (subscriptions and partial redemptions)", fmtAmt(Lot) + " tUSD"},
		{"Minimum holding", fmtAmt(MinHolding) + " tUSD (a redemption leaving less redeems everything)"},
		{"Price of the first issue", fmtAmt(Par) + " tUSD per share"},
		{"Lock-up", "none: shares exist only after settlement, and a holder cannot subscribe and redeem at once"},
		{"Orders", "irrevocable once placed (a subscription once accepted); the investor may ask on-chain for one to be withdrawn, and the administrator may then withdraw it in that period"},
		{"Redemption gate", pct(GateBps) + " of NAV per period, never less than one lot, and no more than the cash available; deferred requests are served before new ones"},
		{"Last-exit rule", "the rest of a whole-holding redemption below " + fmtAmt(Lot+MinHolding) + " tUSD is paid above the gate when it is the only request left"},
		{"Management fee", pct(FeeBps) + ufmt.Sprintf(" a year of gross assets, accrued on the time between valuations (at most %d days)", PeriodSeconds/86400)},
		{"Administration fee", pct(AdminFeeBps) + " a year of gross assets, to the listed administrator"},
		{"Deposit bank fee", pct(BankFeeBps) + " a year of gross assets, to the listed bank"},
		{"Set-up costs", fmtAmt(OrgCostTotal) + ufmt.Sprintf(" tUSD advanced by the manager, repaid over %d months, accrued on time like the fees", OrgCostPeriods)},
		{"Performance fee", pct(PerfFeeBps) + ufmt.Sprintf(" of each investor's gain above their own high-water mark; charged on redemption, and crystallised after at least %d periods and at least %d days since the last crystallisation", CrystalliseEvery, crystalliseMinDays)},
		{"Other expenses", "proposed by the administrator, approved by the reviewer, paid only to listed service providers"},
		{"NAV tolerance", "a move of more than " + pct(NAVToleranceBps) + " needs the reviewer's acknowledgement"},
		{"Dealing suspended", ufmt.Sprintf("for the period, at a NAV per share below %s tUSD or a NAV of zero or less; or by manager and reviewer for up to %d days at a time", fmtAmt(MinNAVps), MaxSuspensionDays)},
		{"Compulsory redemption", ufmt.Sprintf("by the compliance officer (not eligible, breach of law, information not provided; the reason stays off-chain); or by manager and reviewer for a holding below the minimum after %d days' notice; paid ahead of the gate, whole or in lots", MinHoldingNoticeDays)},
		{"Closing", "the manager may close the fund to new subscriptions; manager and reviewer may wind it down; the last investor asking for everything winds it down; after the last distribution the fund stays in liquidation until manager and reviewer approve its closure"},
		{"Contract notes", "for every issue and cancellation of shares, with cost at average cost and the realised gain or loss; an annual statement per holder: " + home() + ":notes/<wallet>"},
		{"Investment payments", "listed instruments only; countersigned; at most " + pct(OutflowCapBps) + " of the last NAV per period in total"},
		{"Concentration", "at most " + pct(ConcentrationBps) + " of the last NAV in one instrument"},
		{"Compliance timeout", ufmt.Sprintf("an undecided direct subscription is refundable after %d periods", ComplianceTimeoutPeriods)},
		{"Stalled period", ufmt.Sprintf("after %d days in cut-off or awaiting the NAV, subscribers may take their money back", StallSeconds/86400)},
		{"Eligibility", ufmt.Sprintf("up to %d days per decision", EligibilityMaxDays)},
		{"Screening agent session", ufmt.Sprintf("limited to this fund's realms, expiry within %d days, recommendations only", AgentSessionMaxDays)},
		{"Annual audit", ufmt.Sprintf("the auditor records the audited report's SHA-256; due within %d days of the year end, flagged overdue after that", AuditDueDays)},
		{"The manager", "never moves money or assets on his signature alone"},
		{"Proposals", "a proposal needing two keys is valid only in the period it is made"},
		{"Open orders", ufmt.Sprintf("at most %d subscriptions and %d redemption requests at a time, held orders included", MaxOpenSubscriptions, MaxOpenRequests)},
	}
	for _, r := range rows {
		b.WriteString("| " + r[0] + " | " + r[1] + " |\n")
	}
	b.WriteString("\n## Listed instruments\n\n| Name | Description | Payment address |\n|---|---|---|\n")
	for _, n := range instrOrder {
		in := getInstrument(n)
		b.WriteString("| " + in.name + " | " + cell(in.label) + " | " + in.payTo.String() + " |\n")
	}
	b.WriteString("\n## Listed service providers\n\n| Name | Payment address |\n|---|---|\n")
	for _, n := range providerOrd {
		b.WriteString("| " + n + " | " + getProvider(n).String() + " |\n")
	}
	return b.String()
}

func renderMemo() string {
	var b strings.Builder
	b.WriteString("# Investment memorandum v" + MemoVersion + "\n\n" + banner + nav())
	for _, s := range memorandum {
		b.WriteString("## " + s.Title + "\n\n" + s.Body + "\n\n")
	}
	b.WriteString("SHA-256 of this memorandum: `" + memorandumHash() + "`\n")
	return b.String()
}

func renderDesk() string {
	var b strings.Builder
	b.WriteString("# Desk\n\n" + banner + nav())
	b.WriteString(ufmt.Sprintf("Period **%d**: %s.\n\n", cur0.n, stateNames[cur0.state]))
	switch cur0.state {
	case stateOpen:
		b.WriteString("Administrator: [cut off the period](" + link("CutOff") + ").\n\n")
	case stateCutOff:
		b.WriteString("Administrator: [propose the NAV](" + link("ProposeNAV") + ") (marks for " + strings.Join(instrOrder, ", ") + ").\n\n")
	case stateProposed:
		b.WriteString(ufmt.Sprintf("## NAV proposal %d\n\n- Gross: %s\n- Fee: %s\n- NAV: %s\n- NAV per share: %s\n- Price sources (SHA-256): `%s`\n",
			cur0.proposalNo, fmtAmt(cur0.gross), fmtAmt(cur0.fee), fmtAmt(cur0.nav), fmtAmt(cur0.navps), cur0.sourceRef))
		for _, m := range cur0.marks {
			b.WriteString("- Mark " + m.name + ": " + fmtAmt(m.value) + "\n")
		}
		ack := "false"
		if cur0.needsAck {
			ack = "true"
			b.WriteString("\n**The move is beyond the tolerance and needs acknowledgement.**\n")
		}
		p := strconv.FormatInt(cur0.proposalNo, 10)
		b.WriteString("\nReviewer: [approve](" + link("ApproveNAV", "proposal", p, "acknowledgeMove", ack) + ") · [reject](" + link("RejectNAV", "proposal", p) + ")\n\n")
	case stateSettling:
		b.WriteString("Anyone: [settle the next batch](" + link("Settle", "max", "50") + ").\n\n")
	}
	if pendingSusp != nil && pendingSusp.period == cur0.n {
		if pendingSusp.lift {
			b.WriteString("Reviewer: the manager proposes to lift the suspension: [approve](" + link("ApproveSuspension") + ").\n\n")
		} else {
			b.WriteString(ufmt.Sprintf("Reviewer: the manager proposes to suspend dealing for %d days (%s): [approve](%s).\n\n", pendingSusp.days, pendingSusp.reason, link("ApproveSuspension")))
		}
	}
	if windDownProposed && !windDownApproved && windDownPeriod == cur0.n {
		b.WriteString("Reviewer: the manager proposes to wind the fund down (" + windDownReason + "): [approve](" + link("ApproveWindDown") + ").\n\n")
	}
	b.WriteString("## Subscriptions in escrow\n\n| # | Amount | Placed in period | Route | Status |\n|---:|---:|---:|---|---|\n")
	activeSubs.Iterate("", "", func(k string, _ any) bool {
		s := subs.Get(k).(*subscription)
		route := "direct"
		if s.viaNominee {
			route = "nominee"
		}
		b.WriteString(ufmt.Sprintf("| %d | %s | %d | %s | %s |\n", s.id, fmtAmt(s.amount), s.placedPeriod, route, subStatusNames[s.status]))
		return false
	})
	b.WriteString("\n## Open redemption requests\n\n| # | Request | Route | Dealt from period |\n|---:|---|---|---:|\n")
	openReds.Iterate("", "", func(k string, _ any) bool {
		r := reds.Get(k).(*redemption)
		what := "whole holding"
		if !r.full {
			what = ufmt.Sprintf("%d lot(s)", r.lots)
		}
		route := "direct"
		if r.viaNominee {
			route = "nominee"
		}
		b.WriteString(ufmt.Sprintf("| %d | %s | %s | %d |\n", r.id, what, route, r.dealPeriod))
		return false
	})
	b.WriteString("\n## Open investment payments and receipts\n\n| Kind | # | Instrument | Amount | Period |\n|---|---:|---|---:|---:|\n")
	outflows.ReverseIterate("", "", func(_ string, v any) bool {
		o := v.(*outflow)
		if o.period < cur0.n {
			return true // older ones are closed or stale
		}
		if !o.paid && !o.cancelled {
			b.WriteString(ufmt.Sprintf("| payment | %d | %s | %s | %d |\n", o.id, o.instrument, fmtAmt(o.amount), o.period))
		}
		return false
	})
	expenses.ReverseIterate("", "", func(_ string, v any) bool {
		e := v.(*expense)
		if e.period < cur0.n {
			return true
		}
		if !e.paid && !e.cancelled {
			b.WriteString(ufmt.Sprintf("| expense | %d | %s | %s | %d |\n", e.id, e.provider, fmtAmt(e.amount), e.period))
		}
		return false
	})
	receipts.ReverseIterate("", "", func(_ string, v any) bool {
		r := v.(*receipt)
		if r.period < cur0.n {
			return true
		}
		if !r.recorded && !r.cancelled {
			b.WriteString(ufmt.Sprintf("| receipt | %d | %s | %s | %d |\n", r.id, r.source, fmtAmt(r.amount), r.period))
		}
		return false
	})
	return b.String()
}

func writeHistory(b *strings.Builder, offset, count int) {
	b.WriteString("NAV is gross less the period's scheduled fees and anything still owed (expenses are paid when approved, before the NAV). Performance fees are charged after it, by cancelling the shares of the holders concerned.\n\n")
	b.WriteString("| Period | Gross | Scheduled fees | NAV | NAV per share | Performance fees | Subscribed | Redeemed | Shares after |\n|---:|---:|---:|---:|---:|---:|---:|---:|---:|\n")
	history.ReverseIterateByOffset(offset, count, func(_ string, v any) bool {
		r := v.(*record)
		b.WriteString(ufmt.Sprintf("| %d | %s | %s | %s | %s | %s | %s | %s | %s |\n", r.n, fmtAmt(r.gross), fmtAmt(r.fee), fmtAmt(r.nav), fmtAmt(r.navps), fmtAmt(r.perfFee), fmtAmt(r.subsAmount), fmtAmt(r.redsPaid), fmtAmt(r.sharesAfter)))
		return false
	})
}

func pageCount(total, size int) int {
	p := (total + size - 1) / size
	if p == 0 {
		p = 1
	}
	return p
}

func pager(b *strings.Builder, page, pages int, name string) {
	if page > 1 {
		b.WriteString(ufmt.Sprintf("\n[Newer](%s:%s/%d)", home(), name, page-1))
	}
	if page < pages {
		b.WriteString(ufmt.Sprintf("\n[Older](%s:%s/%d)", home(), name, page+1))
	}
}

func renderHistory(page int) string {
	pages := pageCount(history.Size(), historyPageSize)
	if page > pages {
		return "invalid page"
	}
	var b strings.Builder
	b.WriteString("# NAV history\n\n" + banner + nav())
	b.WriteString(ufmt.Sprintf("Newest first. Page %d of %d.\n\n", page, pages))
	writeHistory(&b, (page-1)*historyPageSize, historyPageSize)
	pager(&b, page, pages, "history")
	return b.String()
}

func renderLists(page int) string {
	pages := pageCount(listLog.Size(), trailPageSize)
	if page > pages {
		return "invalid page"
	}
	var b strings.Builder
	b.WriteString("# Sanctions lists\n\n" + banner + nav())
	b.WriteString("The screening agent records each official list file it screens against. Download the file of that date from the official source and compare its SHA-256. No investor data is published here.\n\n")
	b.WriteString("## Latest\n\n| List | Published | SHA-256 | Recorded at height |\n|---|---|---|---:|\n")
	for _, l := range listCodes {
		v := lists.Get(l.Code)
		if v == nil {
			b.WriteString("| " + l.Name + " | not yet recorded | | |\n")
			continue
		}
		s := v.(*listSnapshot)
		b.WriteString(ufmt.Sprintf("| %s | %s | `%s` | %d |\n", l.Name, s.published, s.sha, s.height))
	}
	b.WriteString(ufmt.Sprintf("\n## All snapshots, newest first (page %d of %d)\n\n| List | Published | SHA-256 | Height |\n|---|---|---|---:|\n", page, pages))
	listLog.ReverseIterateByOffset((page-1)*trailPageSize, trailPageSize, func(_ string, v any) bool {
		s := v.(*listSnapshot)
		b.WriteString(ufmt.Sprintf("| %s | %s | `%s` | %d |\n", s.list, s.published, s.sha, s.height))
		return false
	})
	pager(&b, page, pages, "lists")
	return b.String()
}

func renderTrail(page int) string {
	pages := pageCount(int(trailSeq), trailPageSize)
	if page > pages {
		return "invalid page"
	}
	var b strings.Builder
	b.WriteString("# Trail\n\n" + banner + nav())
	b.WriteString(ufmt.Sprintf("Every decision and settlement step, newest first. Page %d of %d.\n\n| Height | Role | Event |\n|---:|---|---|\n", page, pages))
	trail.ReverseIterateByOffset((page-1)*trailPageSize, trailPageSize, func(_ string, v any) bool {
		e := v.(*entry)
		b.WriteString(ufmt.Sprintf("| %d | %s | %s |\n", e.height, cell(e.role), cell(e.text)))
		return false
	})
	pager(&b, page, pages, "trail")
	return b.String()
}

func addrOr(a address) string {
	if a == "" {
		return "not set"
	}
	return "`" + a.String() + "`"
}
