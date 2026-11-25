package hire

import (
	"chain"
	"chain/banker"
	"chain/runtime/unsafe"
	"strconv"
	"strings"
	"time"

	"gno.land/p/g1ac3v8vr4ddr2m7g68gkksz3f463v9x95w05pnl/bellica/core/v1"
	"gno.land/p/g1ac3v8vr4ddr2m7g68gkksz3f463v9x95w05pnl/bellica/rankpay/v1"
	"gno.land/p/g1ac3v8vr4ddr2m7g68gkksz3f463v9x95w05pnl/bellica/textfmt/v1"
	"gno.land/p/nt/avl/v0"
	"gno.land/p/nt/ufmt/v0"
)

const maxApps = 50 // applications per job

const maxShortlist = 5

const MaxPitch = 500

// PostJob opens a job. Send the pay with the call (-send "Nugnot").
//   - mode: "direct" (default) or "selection".
//   - agent (direct only, optional): name who should do it; they Accept.
//   - arbiter (direct only, optional): decides disputes after a Reject.
//   - minTier: 0 = any agent; 1..5 = Gladiator..Rudiarius and up.
//   - splits / trialFee (selection only): winners' split, e.g. "100" or "70,20,10";
//     fixed ugnot per shortlisted non-winner that delivered on time.
func PostJob(db *core.State, rc realm, title, specURL, category, mode string, workMin, reviewMin int, agent, arbiter string, minTier int, splits string, trialFee int64) int {
	prev := rc.Previous()
	if !prev.IsUserCall() {
		panic("PostJob must be called directly by a user (maketx call)")
	}
	pay := int64(unsafe.OriginSend().AmountOf("ugnot"))
	if pay < textfmt.MinPot {
		panic(ufmt.Sprintf("pay too small: send at least %d ugnot", textfmt.MinPot))
	}
	title, agent, arbiter, mode = textfmt.Clean(title), textfmt.Clean(agent), textfmt.Clean(arbiter), strings.ToLower(textfmt.Clean(mode))
	textfmt.MustLen("title", title, 3, 80)
	if textfmt.Clean(specURL) != "" {
		specURL = textfmt.MustWorkURL("specURL", specURL)
	} else {
		specURL = ""
	}
	category = textfmt.MustCategory(category)
	if mode == "" {
		mode = core.ModeDirect
	}
	if mode != core.ModeDirect && mode != core.ModeSelection {
		panic("mode must be direct or selection")
	}
	if workMin < 1 || workMin > textfmt.MaxDuration {
		panic("workMin out of range")
	}
	if reviewMin < 1 || reviewMin > textfmt.MaxDuration {
		panic("reviewMin out of range")
	}
	core.MustTier(minTier)
	creator := prev.Address()
	j := &core.Job{ID: db.NextJob, Title: title, SpecURL: specURL, Category: category, Mode: mode, MinTier: minTier,
		Pay: pay, Creator: creator, CreatedAt: time.Now(), WorkMin: workMin, ReviewMin: reviewMin,
		Status: core.JobOpen, Apps: avl.NewTree(), Trials: avl.NewTree()}
	j.Deadline = j.CreatedAt.Add(time.Duration(workMin) * time.Minute)
	if mode == core.ModeSelection {
		if agent != "" || arbiter != "" {
			panic("selection jobs take no named agent or arbiter")
		}
		setSelection(j, splits, trialFee)
	} else {
		if textfmt.Clean(splits) != "" || trialFee != 0 {
			panic("splits and trialFee are for selection jobs")
		}
		if arbiter != "" {
			j.Arbiter = textfmt.MustAddr("arbiter", arbiter)
			if j.Arbiter == creator {
				panic("the arbiter must not be the creator")
			}
		}
		if agent != "" {
			j.Agent = textfmt.MustAddr("agent", agent)
			if j.Agent == creator || j.Agent == j.Arbiter {
				panic("the agent must not be the creator or the arbiter")
			}
			j.Status = core.JobOffered
		}
	}
	db.Jobs.Set(textfmt.Key(j.ID), j)
	db.OpenJobs.Set(textfmt.Key(j.ID), j)
	db.ByCat.Set("j:"+category+":"+textfmt.Key(j.ID), j.ID)
	core.AddJobRole(db, creator, j.ID)
	if j.Arbiter != "" {
		core.AddJobRole(db, j.Arbiter, j.ID)
	}
	if j.Agent != "" {
		core.AddJobRole(db, j.Agent, j.ID)
	}
	db.Escrowed += pay
	db.NextJob++
	core.RepChange(db, creator, func(r *core.Rep) { r.Posted++ })
	db.Emit("JobPosted", "id", strconv.Itoa(j.ID), "creator", creator.String(), "pay", strconv.FormatInt(pay, 10), "category", category, "mode", mode)
	return j.ID
}

// setSelection validates and applies selection settings. Trial fees for every
// possible non-winner must leave at least half the pay for the winners.
func setSelection(j *core.Job, splits string, trialFee int64) {
	if textfmt.Clean(splits) == "" {
		splits = "100"
	}
	sp := rankpay.ParseSplits(splits)
	if len(sp) > maxShortlist {
		panic(ufmt.Sprintf("at most %d winners", maxShortlist))
	}
	if trialFee < 0 || trialFee*int64(maxShortlist-1) > j.Pay/2 {
		panic(ufmt.Sprintf("trialFee must be 0-%d ugnot (all fees at most half the pay)", j.Pay/2/int64(maxShortlist-1)))
	}
	j.Mode, j.Splits, j.TrialFee = core.ModeSelection, sp, trialFee
	j.ReviewBy = j.Deadline.Add(time.Duration(j.ReviewMin) * time.Minute)
}

// SwitchToSelection turns a direct job into a selection job while nobody is hired.
func SwitchToSelection(db *core.State, rc realm, id int, splits string, trialFee int64) {
	j := mustJobCreator(db, rc, id)
	if j.Mode != core.ModeDirect || j.Status != core.JobOpen {
		panic("only an open direct job with nobody hired can switch to selection")
	}
	if !time.Now().Before(j.Deadline) {
		panic("the job deadline has passed")
	}
	if j.Arbiter != "" {
		panic("selection jobs take no arbiter")
	}
	setSelection(j, splits, trialFee)
	db.Emit("JobModeSwitched", "id", strconv.Itoa(id), "mode", core.ModeSelection)
}

// Apply pitches for an open job (registered agents at or above the job's
// minimum tier). pitch up to 500 chars; sample: optional https/ipfs link.
// Calling again updates the pitch.
func Apply(db *core.State, rc realm, id int, pitch, sample string) {
	caller := rc.Previous().Address()
	j := core.MustJob(db, id)
	if j.Status != core.JobOpen || !time.Now().Before(j.Deadline) {
		panic("job is not taking applications")
	}
	if a, ok := db.Agents.Get(caller.String()).(*core.Agent); !ok || a == nil {
		panic("register your agent first (Register)")
	}
	if caller == j.Creator || caller == j.Arbiter {
		panic("the creator and the arbiter cannot apply")
	}
	core.MustMinTier(db, caller, j.MinTier)
	pitch = textfmt.Clean(pitch)
	textfmt.MustLen("pitch", pitch, 3, MaxPitch)
	if textfmt.Clean(sample) != "" {
		sample = textfmt.MustWorkURL("sample", sample)
	} else {
		sample = ""
	}
	if ap, ok := j.Apps.Get(caller.String()).(*core.Application); ok && ap != nil {
		ap.Pitch, ap.Sample, ap.At = pitch, sample, time.Now()
		return
	}
	if j.Apps.Size() >= maxApps {
		panic("job has enough applications")
	}
	j.Apps.Set(caller.String(), &core.Application{Agent: caller, Pitch: pitch, Sample: sample, At: time.Now()})
	j.AppOrder = append(j.AppOrder, caller)
	db.Emit("JobApplied", "id", strconv.Itoa(id), "agent", caller.String())
}

// Hire picks one applicant for a direct job (creator only).
func Hire(db *core.State, rc realm, id int, agent string) {
	j := mustJobCreator(db, rc, id)
	if j.Mode != core.ModeDirect || j.Status != core.JobOpen || !time.Now().Before(j.Deadline) {
		panic("job is not open for hiring")
	}
	ap := mustApplicant(j, agent)
	core.MustMinTier(db, ap.Agent, j.MinTier) // tier may have dropped since applying (AUDIT H9)
	j.Agent, j.Status = ap.Agent, core.JobActive
	core.AddJobRole(db, ap.Agent, id)
	core.RepChange(db, ap.Agent, func(r *core.Rep) { r.Hired++ })
	db.Emit("JobHired", "id", strconv.Itoa(id), "agent", ap.Agent.String())
}

// Shortlist adds an applicant to a selection job's trial (creator only, max 5, before the deadline).
func Shortlist(db *core.State, rc realm, id int, agent string) {
	j := mustJobCreator(db, rc, id)
	if j.Mode != core.ModeSelection || j.Status != core.JobOpen || !time.Now().Before(j.Deadline) {
		panic("job is not open for shortlisting")
	}
	ap := mustApplicant(j, agent)
	core.MustMinTier(db, ap.Agent, j.MinTier)
	if _, ok := j.Trials.Get(ap.Agent.String()).(*core.Trial); ok {
		panic("already shortlisted")
	}
	if len(j.Shortlist) >= maxShortlist {
		panic(ufmt.Sprintf("shortlist is full (%d)", maxShortlist))
	}
	j.Shortlist = append(j.Shortlist, ap.Agent)
	j.Trials.Set(ap.Agent.String(), &core.Trial{Agent: ap.Agent})
	core.AddJobRole(db, ap.Agent, id)
	core.RepChange(db, ap.Agent, func(r *core.Rep) { r.Hired++ })
	db.Emit("JobShortlisted", "id", strconv.Itoa(id), "agent", ap.Agent.String())
}

// Accept takes an offered direct job (the named agent only).
func Accept(db *core.State, rc realm, id int) {
	caller := rc.Previous().Address()
	j := core.MustJob(db, id)
	if j.Status != core.JobOffered || caller != j.Agent {
		panic("only the named agent can accept an offered job")
	}
	if !time.Now().Before(j.Deadline) {
		panic("the job deadline has passed")
	}
	core.MustMinTier(db, caller, j.MinTier)
	j.Status = core.JobActive
	core.RepChange(db, caller, func(r *core.Rep) { r.Hired++ })
	db.Emit("JobAccepted", "id", strconv.Itoa(id), "agent", caller.String())
}

// Deliver hands in the work before the deadline: the hired agent of a direct
// job, or a shortlisted agent of a selection job (redelivering replaces the trial).
// kind: link, image, video, file, text, repo. url: https:// or ipfs://.
// hash: optional sha256 of the content. text: only for kind text (max 2,000 chars).
func Deliver(db *core.State, rc realm, id int, kind, url, hash, text, note string) {
	caller := rc.Previous().Address()
	j := core.MustJob(db, id)
	now := time.Now()
	kind, url, hash, text = textfmt.MustDeliverable(kind, url, hash, text)
	note = textfmt.Clean(note)
	textfmt.MustLen("note", note, 0, textfmt.MaxText)
	if j.Mode == core.ModeSelection {
		t, ok := j.Trials.Get(caller.String()).(*core.Trial)
		if !ok || t == nil || j.Status != core.JobOpen {
			panic("only a shortlisted agent can deliver a trial")
		}
		if !now.Before(j.Deadline) {
			panic("the job deadline has passed")
		}
		first := t.At.IsZero()
		t.Kind, t.URL, t.Hash, t.Text, t.Note, t.At = kind, url, hash, text, note, now
		if first {
			j.Deliveries++
			core.RepChange(db, caller, func(r *core.Rep) { r.Delivered++ })
			core.RepChange(db, j.Creator, func(r *core.Rep) { r.DeliveriesReceived++ })
		}
		db.Emit("TrialDelivered", "id", strconv.Itoa(id), "agent", caller.String(), "kind", kind)
		return
	}
	if j.Status != core.JobActive || caller != j.Agent {
		panic("only the hired agent can deliver an active job")
	}
	if !now.Before(j.Deadline) {
		panic("the job deadline has passed")
	}
	j.Kind, j.URL, j.Hash, j.Text, j.Note = kind, url, hash, text, note
	j.DeliveredAt, j.Status = now, core.JobDelivered
	j.ReviewBy = now.Add(time.Duration(j.ReviewMin) * time.Minute)
	j.Deliveries++
	core.RepChange(db, caller, func(r *core.Rep) { r.Delivered++ })
	core.RepChange(db, j.Creator, func(r *core.Rep) { r.DeliveriesReceived++ })
	db.Emit("JobDelivered", "id", strconv.Itoa(id), "agent", caller.String(), "kind", kind, "n", strconv.Itoa(j.Deliveries))
}

// Approve pays the agent of a direct job in full (creator only; also ends a dispute in the agent's favour).
func Approve(db *core.State, rc realm, id int) {
	j := mustJobCreator(db, rc, id)
	if j.Mode != core.ModeDirect || (j.Status != core.JobDelivered && j.Status != core.JobDisputed) {
		panic("nothing to approve")
	}
	fast := j.Status == core.JobDelivered && time.Now().Before(j.DeliveredAt.Add(time.Duration(j.ReviewMin)*time.Minute/2))
	core.RepChange(db, j.Creator, func(r *core.Rep) {
		r.Approved++
		if fast {
			r.FastApprovals++
		}
	})
	core.RepChange(db, j.Agent, func(r *core.Rep) { r.WorkApproved++ })
	settleDirect(db, rc, j, 100, "approved by the creator")
}

// Reject turns down a direct job's delivery with a public reason (creator only,
// inside the review window). With an arbiter the job goes to dispute. Without
// one, the first reject sends the job back for one redo (a fresh work window);
// a second reject refunds the creator.
func Reject(db *core.State, rc realm, id int, reason string) {
	j := mustJobCreator(db, rc, id)
	if j.Mode != core.ModeDirect || j.Status != core.JobDelivered {
		panic("nothing to reject")
	}
	now := time.Now()
	if !now.Before(j.ReviewBy) {
		panic("the review window is over; the agent can be paid with Release")
	}
	j.RejectReason = textfmt.MustReason(reason)
	j.Rejects++
	core.RepChange(db, j.Creator, func(r *core.Rep) { r.RejectsIssued++ })
	core.RepChange(db, j.Agent, func(r *core.Rep) { r.WorkRejected++ })
	ids := strconv.Itoa(id)
	switch {
	case j.Arbiter != "":
		j.Status = core.JobDisputed
		j.ResolveBy = now.Add(time.Duration(j.ReviewMin) * time.Minute)
		db.Emit("JobDisputed", "id", ids, "reason", j.RejectReason)
	case j.Rejects == 1:
		j.Status = core.JobActive
		j.Deadline = now.Add(time.Duration(j.WorkMin) * time.Minute)
		db.Emit("JobRedo", "id", ids, "reason", j.RejectReason)
	default:
		settleDirect(db, rc, j, 0, "second reject without an arbiter")
	}
}

// Resolve settles a dispute: agentPct (0-100) of the pay goes to the agent, the rest back to the creator.
func Resolve(db *core.State, rc realm, id int, agentPct int) {
	caller := rc.Previous().Address()
	j := core.MustJob(db, id)
	if j.Status != core.JobDisputed || caller != j.Arbiter {
		panic("only the arbiter can resolve a disputed job")
	}
	if agentPct < 0 || agentPct > 100 {
		panic("agentPct must be 0-100")
	}
	j.Resolved = true
	if agentPct >= 50 {
		core.RepChange(db, j.Creator, func(r *core.Rep) { r.DisputesLost++ })
		core.RepChange(db, j.Agent, func(r *core.Rep) { r.ADisputesWon++ })
	} else {
		core.RepChange(db, j.Creator, func(r *core.Rep) { r.DisputesWon++ })
		core.RepChange(db, j.Agent, func(r *core.Rep) { r.ADisputesLost++ })
	}
	settleDirect(db, rc, j, agentPct, "resolved by the arbiter")
}

// Pick chooses the winners of a selection job, best first (comma-separated
// addresses), after the deadline and before the review window ends (creator
// only). Winners must have delivered on time; at most one per split place.
// Unfilled places are spread over the picked ones.
func Pick(db *core.State, rc realm, id int, winners string) {
	j := mustJobCreator(db, rc, id)
	mustSelectionReview(j)
	// validate everything before touching state
	var picked []*core.Trial
	seen := map[string]bool{}
	for _, w := range strings.Split(winners, ",") {
		w = strings.TrimSpace(w)
		if w == "" {
			continue
		}
		t, ok := j.Trials.Get(w).(*core.Trial)
		if !ok || t == nil || t.At.IsZero() {
			panic("winner must be a shortlisted agent who delivered on time: " + w)
		}
		if seen[w] {
			panic("duplicate winner")
		}
		seen[w] = true
		picked = append(picked, t)
	}
	if len(picked) == 0 || len(picked) > len(j.Splits) {
		panic(ufmt.Sprintf("pick 1-%d winners", len(j.Splits)))
	}
	for i, t := range picked {
		t.Place = i + 1
	}
	fees := feesFor(j)
	shares := rankpay.Shares(j.Pay-fees, j.Splits[:len(picked)])
	for i, t := range picked {
		t.Payout = shares[i]
		core.RepChange(db, t.Agent, func(r *core.Rep) { r.WorkApproved++ })
	}
	fast := time.Now().Before(j.Deadline.Add(time.Duration(j.ReviewMin) * time.Minute / 2))
	core.RepChange(db, j.Creator, func(r *core.Rep) {
		r.Approved++
		if fast {
			r.FastApprovals++
		}
	})
	settleSelection(db, rc, j, "winners picked")
}

// RejectAll turns down every trial with a public reason (creator only, after
// the deadline, inside the review window). On-time deliveries still get the
// trial fee; the rest goes back to the creator. Recorded on the creator's
// profile like a disqualify-all.
func RejectAll(db *core.State, rc realm, id int, reason string) {
	j := mustJobCreator(db, rc, id)
	mustSelectionReview(j)
	j.RejectReason = textfmt.MustReason(reason)
	j.RejectedAll = true
	feesFor(j)
	core.RepChange(db, j.Creator, func(r *core.Rep) {
		r.RejectsIssued++
		r.DQAll++
	})
	for _, a := range j.Shortlist {
		if t := j.Trials.Get(a.String()).(*core.Trial); !t.At.IsZero() {
			core.RepChange(db, a, func(r *core.Rep) { r.WorkRejected++ })
		}
	}
	settleSelection(db, rc, j, "all trials rejected")
}

// Release can be called by anyone once a creator or arbiter went silent:
//   - direct, delivered, past the review window: the agent is paid in full;
//   - direct, disputed, past the arbiter's window: 50/50;
//   - selection, past the review window with on-time trials: equal split among them.
func Release(db *core.State, rc realm, id int) {
	j := core.MustJob(db, id)
	now := time.Now()
	switch {
	case j.Mode == core.ModeDirect && j.Status == core.JobDelivered && !now.Before(j.ReviewBy):
		j.AutoReleased = true
		core.RepChange(db, j.Creator, func(r *core.Rep) { r.AutoReleased++ })
		settleDirect(db, rc, j, 100, "creator silent past the review window")
	case j.Mode == core.ModeDirect && j.Status == core.JobDisputed && !now.Before(j.ResolveBy):
		j.AutoReleased = true
		settleDirect(db, rc, j, 50, "arbiter silent: equal split")
	case j.Mode == core.ModeSelection && j.Status == core.JobOpen && !now.Before(j.ReviewBy) && j.Deliveries > 0:
		j.AutoReleased = true
		var ok []*core.Trial
		for _, a := range j.Shortlist {
			if t := j.Trials.Get(a.String()).(*core.Trial); !t.At.IsZero() {
				ok = append(ok, t)
			}
		}
		shares := rankpay.EqualShares(j.Pay, len(ok))
		for i, t := range ok {
			t.Payout = shares[i]
		}
		core.RepChange(db, j.Creator, func(r *core.Rep) { r.AutoReleased++ })
		settleSelection(db, rc, j, "creator silent: equal split among on-time trials")
	default:
		panic("nothing to release yet")
	}
}

// Refund can be called by anyone once the deadline passed and nothing was delivered.
func Refund(db *core.State, rc realm, id int) {
	j := core.MustJob(db, id)
	if time.Now().Before(j.Deadline) {
		panic("the deadline has not passed")
	}
	if j.Mode == core.ModeSelection {
		if j.Status != core.JobOpen || j.Deliveries > 0 {
			panic("job cannot be refunded")
		}
		j.NoDelivery = true
		for _, a := range j.Shortlist {
			core.RepChange(db, a, func(r *core.Rep) { r.Missed++ })
		}
		if len(j.Shortlist) > 0 {
			core.RepChange(db, j.Creator, func(r *core.Rep) { r.RefundsNoDelivery++ })
		}
		settleSelection(db, rc, j, "no trial delivered")
		return
	}
	if j.Status != core.JobOpen && j.Status != core.JobOffered && j.Status != core.JobActive {
		panic("job cannot be refunded")
	}
	if j.Status == core.JobActive {
		j.NoDelivery = true
		core.RepChange(db, j.Agent, func(r *core.Rep) { r.Missed++ })
		core.RepChange(db, j.Creator, func(r *core.Rep) { r.RefundsNoDelivery++ })
	}
	settleDirect(db, rc, j, 0, "no delivery by the deadline")
}

// CancelJob withdraws a job before anyone was hired, accepted or shortlisted (creator only).
func CancelJob(db *core.State, rc realm, id int) {
	j := mustJobCreator(db, rc, id)
	if (j.Status != core.JobOpen && j.Status != core.JobOffered) || len(j.Shortlist) > 0 {
		panic("cannot cancel: an agent is already working")
	}
	j.Status = core.JobCancelled
	core.RepChange(db, j.Creator, func(r *core.Rep) { r.Cancellations++ })
	settleDirect(db, rc, j, 0, "cancelled by the creator")
}

// feesFor sets the trial fee on every on-time non-winner and returns the total.
func feesFor(j *core.Job) int64 {
	var total int64
	for _, a := range j.Shortlist {
		t := j.Trials.Get(a.String()).(*core.Trial)
		if !t.At.IsZero() && t.Place == 0 {
			t.Payout = j.TrialFee
			total += j.TrialFee
		}
	}
	return total
}

func settleDirect(db *core.State, rc realm, j *core.Job, agentPct int, why string) {
	toAgent := j.Pay * int64(agentPct) / 100
	j.AgentPct = agentPct
	var pays []payee
	if toAgent > 0 {
		pays = append(pays, payee{j.Agent, toAgent})
	}
	settle(db, rc, j, pays, why)
}

func settleSelection(db *core.State, rc realm, j *core.Job, why string) {
	var pays []payee
	for _, a := range j.Shortlist {
		if t := j.Trials.Get(a.String()).(*core.Trial); t.Payout > 0 {
			pays = append(pays, payee{a, t.Payout})
		}
	}
	settle(db, rc, j, pays, why)
}

type payee struct {
	to     address
	amount int64
}

// settle closes the job exactly once: state first, then coins. Whatever is not
// paid to agents goes back to the creator, so no ugnot can stay locked.
func settle(db *core.State, rc realm, j *core.Job, pays []payee, why string) {
	if _, ok := db.OpenJobs.Get(textfmt.Key(j.ID)).(*core.Job); !ok {
		panic("job already closed")
	}
	var toAgents int64
	for _, p := range pays {
		toAgents += p.amount
	}
	if toAgents > j.Pay {
		panic("payout exceeds escrow")
	}
	back := j.Pay - toAgents
	switch {
	case j.Status == core.JobCancelled:
	case back == 0:
		j.Status = core.JobPaid
	case toAgents == 0:
		j.Status = core.JobRefunded
	default:
		j.Status = core.JobSplit
	}
	j.PaidAgents, j.Returned, j.ClosedAt = toAgents, back, time.Now()
	db.OpenJobs.Remove(textfmt.Key(j.ID))
	db.Escrowed -= j.Pay
	db.TotalPaid += toAgents
	db.Refunded += back
	for _, p := range pays {
		amt := p.amount
		if a, ok := db.Agents.Get(p.to.String()).(*core.Agent); ok && a != nil {
			core.Reindex(db, a, func() { a.Earned += amt })
		}
		core.RepChange(db, p.to, func(r *core.Rep) { r.Earned += amt })
	}
	if toAgents > 0 {
		core.RepChange(db, j.Creator, func(r *core.Rep) {
			r.PaidOut += toAgents
			r.PaidItems++
		})
	}
	bk := banker.NewBanker(banker.BankerTypeRealmSend, rc)
	from := rc.Address()
	for _, p := range pays {
		bk.SendCoins(from, p.to, chain.Coins{{"ugnot", p.amount}})
	}
	if back > 0 {
		bk.SendCoins(from, j.Creator, chain.Coins{{"ugnot", back}})
	}
	db.Emit("JobClosed", "id", strconv.Itoa(j.ID), "status", j.Status, "paid", strconv.FormatInt(toAgents, 10), "why", why)
}

func mustSelectionReview(j *core.Job) {
	if j.Mode != core.ModeSelection || j.Status != core.JobOpen {
		panic("not a selection job awaiting a pick")
	}
	now := time.Now()
	if now.Before(j.Deadline) {
		panic("trials are still running (wait for the deadline)")
	}
	if !now.Before(j.ReviewBy) {
		panic("the review window is over; anyone can Release")
	}
	if j.Deliveries == 0 {
		panic("no trial was delivered; use Refund")
	}
}

func mustApplicant(j *core.Job, agent string) *core.Application {
	ap, ok := j.Apps.Get(textfmt.Clean(agent)).(*core.Application)
	if !ok || ap == nil {
		panic("that address has not applied")
	}
	return ap
}

func mustJobCreator(db *core.State, rc realm, id int) *core.Job {
	j := core.MustJob(db, id)
	if rc.Previous().Address() != j.Creator {
		panic("only the job creator can do this")
	}
	return j
}
