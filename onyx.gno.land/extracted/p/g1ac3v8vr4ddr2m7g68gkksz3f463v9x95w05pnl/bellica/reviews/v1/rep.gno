package reviews

import (
	"strconv"
	"strings"
	"time"

	"gno.land/p/g1ac3v8vr4ddr2m7g68gkksz3f463v9x95w05pnl/bellica/core/v1"
	"gno.land/p/g1ac3v8vr4ddr2m7g68gkksz3f463v9x95w05pnl/bellica/textfmt/v1"
	"gno.land/p/nt/ufmt/v0"
)

// partySides reports whether addr is on the giver side and/or the worker side
// of a finished, escrowed item ("job" or "bounty").
func partySides(db *core.State, kind string, id int, addr address) (giver, worker bool) {
	switch kind {
	case "job":
		j := core.MustJob(db, id)
		if !j.Closed() || j.Status == core.JobCancelled {
			panic("only finished jobs can be rated or reported")
		}
		if addr == j.Creator {
			giver = true
		}
		if j.Mode == core.ModeSelection {
			if t, ok := j.Trials.Get(addr.String()).(*core.Trial); ok && t != nil && !t.At.IsZero() {
				worker = true
			}
		} else if addr == j.Agent && j.Agent != "" {
			if j.Status != core.JobCancelled {
				worker = true
			}
		}
	case "bounty":
		b := core.MustBounty(db, id)
		if b.Status == core.StatusOpen || b.Status == core.StatusCancelled {
			panic("only finished bounties can be rated or reported")
		}
		if addr == b.Creator || addr == b.Judge {
			giver = true
		}
		if e, ok := b.EntryTree.Get(addr.String()).(*core.Entry); ok && e != nil && (e.Payout > 0 || e.Disqualified) {
			worker = true
		}
	default:
		panic("kind must be job or bounty")
	}
	return
}

// mustCounterparties checks rater and target sit on opposite sides of the item.
// Returns true when the target is on the giver side.
func mustCounterparties(db *core.State, kind string, id int, rater, target address) bool {
	if rater == target {
		panic("you cannot rate or report yourself")
	}
	rg, rw := partySides(db, kind, id, rater)
	tg, tw := partySides(db, kind, id, target)
	switch {
	case rg && tw:
		return false
	case rw && tg:
		return true
	}
	panic("only counterparties of this item can rate or report each other")
}

// Rate scores a counterparty of a finished job or bounty from 1 to 5 with an
// optional comment (max 280 chars). One rating per rater, target and item.
func Rate(db *core.State, rc realm, kind string, id int, target string, score int, comment string) {
	rater := rc.Previous().Address()
	kind = strings.ToLower(textfmt.Clean(kind))
	t := textfmt.MustAddr("target", textfmt.Clean(target))
	asGiver := mustCounterparties(db, kind, id, rater, t)
	if score < 1 || score > 5 {
		panic("score must be 1-5")
	}
	comment = textfmt.Clean(comment)
	textfmt.MustLen("comment", comment, 0, textfmt.MaxText)
	k := kind + ":" + strconv.Itoa(id) + ":" + rater.String() + ":" + t.String()
	if db.Ratings.Has(k) {
		panic("you already rated this counterparty for this item")
	}
	rt := &core.Rating{Kind: kind, ItemID: id, Rater: rater, Target: t, Score: score, Comment: comment, AsGiver: asGiver, At: time.Now()}
	db.Ratings.Set(k, rt)
	list, _ := db.RatingsOf.Get(t.String()).([]*core.Rating)
	list = append(list, rt)
	if len(list) > core.MaxRatingsShown {
		list = list[len(list)-core.MaxRatingsShown:]
	}
	db.RatingsOf.Set(t.String(), list)
	core.RepChange(db, t, func(r *core.Rep) {
		if asGiver {
			r.GiverRatingSum += score
			r.GiverRatingN++
		} else {
			r.AgentRatingSum += score
			r.AgentRatingN++
		}
	})
	db.Emit("Rated", "kind", kind, "id", strconv.Itoa(id), "rater", rater.String(), "target", t.String(), "score", strconv.Itoa(score))
}

// Report files a public report against a counterparty of a finished job or
// bounty. reason: non_payment_attempt, unfair_reject, unfair_dq, spam,
// plagiarism or other. text: 30-500 chars explaining what happened. evidence:
// https/ipfs link, required for every reason except spam and other.
// No on-chain punishment: reports are shown on the item and the profile, and
// only upheld ones (evidence + confirming on-chain facts) count in badges/scores.
func Report(db *core.State, rc realm, kind string, id int, target, reason, text, evidence string) int {
	rep := rc.Previous().Address()
	kind = strings.ToLower(textfmt.Clean(kind))
	t := textfmt.MustAddr("target", textfmt.Clean(target))
	targetIsGiver := mustCounterparties(db, kind, id, rep, t)
	reason = strings.ToLower(textfmt.Clean(reason))
	if !textfmt.InList(reason, textfmt.ReportReasons) {
		panic("reason must be one of " + strings.Join(textfmt.ReportReasons, ", "))
	}
	text = textfmt.MustReportText(text)
	if textfmt.Clean(evidence) != "" {
		evidence = textfmt.MustWorkURL("evidence", evidence)
	} else {
		evidence = ""
	}
	if textfmt.EvidenceRequired(reason) && evidence == "" {
		panic("an evidence link (https or ipfs) is required for " + reason)
	}
	pk := kind + ":" + strconv.Itoa(id) + ":" + rep.String() + ":" + t.String()
	if db.ReportPair.Has(pk) {
		panic("you already reported this counterparty for this item")
	}
	r := &core.ReportRec{ID: db.NextReport, Kind: kind, ItemID: id, Reporter: rep, Target: t, Reason: reason, Text: text, Evidence: evidence, At: time.Now()}
	r.Facts = itemFacts(db, kind, id, rep, t)
	if evidence != "" {
		r.Upheld, r.Basis = upheld(db, kind, id, rep, t, targetIsGiver, reason)
	}
	db.Reports.Set(textfmt.Key(r.ID), r)
	db.ReportPair.Set(pk, r.ID)
	db.NextReport++
	ik := kind + ":" + strconv.Itoa(id)
	ids, _ := db.ReportsOn.Get(ik).([]int)
	if len(ids) < core.MaxReportsItem {
		db.ReportsOn.Set(ik, append(ids, r.ID))
	}
	aids, _ := db.ReportsAbout.Get(t.String()).([]int)
	aids = append(aids, r.ID)
	if len(aids) > core.MaxReportsAddr {
		aids = aids[len(aids)-core.MaxReportsAddr:]
	}
	db.ReportsAbout.Set(t.String(), aids)
	core.RepChange(db, t, func(x *core.Rep) {
		x.ReportsAgainst++
		if r.Upheld {
			x.UpheldAgainst++
		}
	})
	core.RepChange(db, rep, func(x *core.Rep) { x.ReportsFiled++ })
	db.Emit("Reported", "report", strconv.Itoa(r.ID), "kind", kind, "id", strconv.Itoa(id), "target", t.String(), "reason", reason, "upheld", strconv.FormatBool(r.Upheld))
	return r.ID
}

// Respond posts the reported party's single public answer to a report.
func Respond(db *core.State, rc realm, reportID int, text string) {
	caller := rc.Previous().Address()
	r, ok := db.Reports.Get(textfmt.Key(reportID)).(*core.ReportRec)
	if !ok || r == nil {
		panic("report not found")
	}
	if caller != r.Target {
		panic("only the reported party can respond")
	}
	if r.Response != "" {
		panic("already responded")
	}
	r.Response = textfmt.MustReportText(text)
	r.RespondedAt = time.Now()
	db.Emit("ReportAnswered", "report", strconv.Itoa(reportID))
}

// itemFacts snapshots the recorded on-chain facts relevant to a report.
func itemFacts(db *core.State, kind string, id int, reporter, target address) string {
	if kind == "job" {
		j := core.MustJob(db, id)
		s := ufmt.Sprintf("job #%d (%s) %s · pay %s · outcome %s", j.ID, j.Mode, j.Status, textfmt.Gnot(j.Pay), j.Status)
		if j.Mode == core.ModeDirect {
			if !j.DeliveredAt.IsZero() {
				s += " · delivered " + textfmt.When(j.DeliveredAt) + " (" + j.Kind + ")"
			} else {
				s += " · never delivered"
			}
			s += ufmt.Sprintf(" · %d reject(s)", j.Rejects)
			if j.RejectReason != "" {
				s += " · last reject reason: " + j.RejectReason
			}
			s += ufmt.Sprintf(" · agent got %d%%", j.AgentPct)
		} else {
			s += ufmt.Sprintf(" · %d trial(s) delivered of %d shortlisted", j.Deliveries, len(j.Shortlist))
			if j.RejectedAll {
				s += " · creator rejected all trials: " + j.RejectReason
			}
		}
		if j.Resolved {
			s += " · resolved by the arbiter"
		}
		if j.AutoReleased {
			s += " · paid by auto-release (silence)"
		}
		return s
	}
	b := core.MustBounty(db, id)
	s := ufmt.Sprintf("bounty #%d %s · pot %s · paid %s", b.ID, b.Status, textfmt.Gnot(b.Pot), textfmt.Gnot(b.Paid))
	if b.SelfJudged() {
		s += " · self-judged"
	}
	for _, a := range []address{reporter, target} {
		if e, ok := b.EntryTree.Get(a.String()).(*core.Entry); ok && e != nil {
			if e.Disqualified {
				s += " · " + a.String()[:10] + "… DQ'd: " + e.DQReason
			} else if e.Payout > 0 {
				s += " · " + a.String()[:10] + "… paid " + textfmt.Gnot(e.Payout)
			}
		}
	}
	return s
}

// upheld: does the item's recorded outcome confirm the report? Never decided
// by votes, only by escrow facts (arbiter ruling, silence, self-judged DQ-all).
func upheld(db *core.State, kind string, id int, reporter, target address, targetIsGiver bool, reason string) (bool, string) {
	if kind == "job" {
		j := core.MustJob(db, id)
		if j.Resolved {
			if targetIsGiver && j.AgentPct >= 50 {
				return true, "the arbiter ruled for the agent"
			}
			if !targetIsGiver && j.AgentPct < 50 {
				return true, "the arbiter ruled for the creator"
			}
		}
		if targetIsGiver && j.AutoReleased && j.Mode == core.ModeDirect && (reason == "unfair_reject" || reason == "non_payment_attempt") {
			return true, "the creator went silent and the pay was auto-released"
		}
		if !targetIsGiver && j.NoDelivery {
			return true, "the agent never delivered"
		}
		return false, ""
	}
	b := core.MustBounty(db, id)
	if targetIsGiver && reason == "unfair_dq" && b.DQAll {
		if e, ok := b.EntryTree.Get(reporter.String()).(*core.Entry); ok && e != nil && e.Disqualified {
			return true, "self-judged bounty disqualified every entry"
		}
	}
	return false, ""
}
