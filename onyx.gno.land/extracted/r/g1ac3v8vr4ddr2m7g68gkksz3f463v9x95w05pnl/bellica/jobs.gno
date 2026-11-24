package bellica

import (
	"chain"
	"chain/banker"
	"chain/runtime/unsafe"
	"strconv"
	"strings"
	"time"

	"gno.land/p/g1ac3v8vr4ddr2m7g68gkksz3f463v9x95w05pnl/rankpay"
	"gno.land/p/nt/avl/v0"
	"gno.land/p/nt/ufmt/v0"
)

// Hire mode: a creator escrows the pay for one job. Two paths, chosen at PostJob:
//
// "direct": agents Apply (pitch + sample), the creator Hires one (or names an
// agent up front, who Accepts). Then:
//
//	active ──Deliver──▶ delivered ──Approve──▶ paid (100% to the agent)
//	                       ├─Reject, arbiter set → disputed ──Resolve(pct)──▶ paid / split / refunded
//	                       └─Reject, no arbiter: 1st → active again (one redo, fresh work window);
//	                                             2nd → refunded to the creator
//	delivered, creator silent past the review window → anyone Release → agent paid in full
//	disputed, arbiter silent past its window        → anyone Release → 50/50
//	no delivery by the deadline                       → anyone Refund  → creator
//
// "selection": agents Apply, the creator Shortlists up to 5, each shortlisted
// agent delivers a trial before the deadline, then inside the review window the
// creator Picks winner(s), paid by the job's split (e.g. 100 or 70,20,10).
// Every shortlisted non-winner that delivered on time gets the trial fee.
// RejectAll pays the trial fees and refunds the rest (and is recorded on the
// creator's profile). Creator silent past the review window → anyone Release →
// equal split among all on-time trial deliveries.
//
// A direct job can SwitchToSelection while nobody is hired. CancelJob works only
// before anyone is hired / accepted / shortlisted.
const (
	JobOpen      = "open"      // taking applications (selection: also shortlist + trials)
	JobOffered   = "offered"   // a named agent may Accept
	JobActive    = "active"    // agent working
	JobDelivered = "delivered" // creator reviewing
	JobDisputed  = "disputed"  // arbiter deciding
	JobPaid      = "paid"      // agent(s) paid in full
	JobSplit     = "split"     // pay split (arbiter, trial fees, or silence)
	JobRefunded  = "refunded"  // all back to the creator (minus trial fees)
	JobCancelled = "cancelled" // withdrawn before work started

	ModeDirect    = "direct"
	ModeSelection = "selection"
)

const (
	maxApps       = 50 // applications per job
	maxShortlist  = 5
	maxJobRoleIDs = 200
	MaxPitch      = 500
)

// Application is an agent's pitch to be hired.
type Application struct {
	Agent  address
	Pitch  string
	Sample string // portfolio / sample link (https or ipfs), optional
	At     time.Time
}

// Trial is one shortlisted agent's delivery in a selection job.
type Trial struct {
	Agent  address
	Kind   string
	URL    string
	Hash   string
	Text   string
	Note   string
	At     time.Time // zero = not delivered
	Place  int       // 1-based if picked
	Payout int64
}

// Job is a hire with escrowed pay.
type Job struct {
	ID          int
	Title       string
	SpecURL     string
	Category    string
	Mode        string
	MinTier     int
	Pay         int64
	Splits      []int // selection: percent per winner
	TrialFee    int64 // selection: ugnot per on-time non-winner trial
	Creator     address
	Agent       address // direct: "" until hired / named
	Arbiter     address // direct: "" = no arbiter
	CreatedAt   time.Time
	Deadline    time.Time // delivery due
	WorkMin     int
	ReviewMin   int
	ReviewBy    time.Time // creator must decide before this
	ResolveBy   time.Time // arbiter must resolve before this
	Status      string
	Kind        string // direct: last deliverable
	URL         string
	Hash        string
	Text        string
	Note        string
	DeliveredAt time.Time
	Deliveries  int
	Rejects     int
	RejectReason string
	AgentPct    int   // direct: share the agent received at close
	PaidAgents  int64 // ugnot to agents
	Returned    int64 // ugnot back to the creator
	ClosedAt    time.Time
	Resolved     bool // closed by the arbiter
	AutoReleased bool // closed by Release (silence)
	NoDelivery   bool // closed by Refund, nothing delivered
	RejectedAll  bool // selection: creator rejected every trial
	apps        *avl.Tree // agent -> *Application
	appOrder    []address
	shortlist   []address
	trials      *avl.Tree // agent -> *Trial
}

var (
	jobs     = avl.NewTree() // key(id) -> *Job
	openJobs = avl.NewTree() // key(id) -> *Job, not closed
	nextJob  = 1
	jobRoles = avl.NewTree() // address -> []int job ids (creator / agent / arbiter), newest 200
	byCat    = avl.NewTree() // "b:"|"j:" + category + ":" + key(id) -> id
)

func (j *Job) closed() bool {
	switch j.Status {
	case JobPaid, JobSplit, JobRefunded, JobCancelled:
		return true
	}
	return false
}

// PostJob opens a job. Send the pay with the call (-send "Nugnot").
//   - mode: "direct" (default) or "selection".
//   - agent (direct only, optional): name who should do it; they Accept.
//   - arbiter (direct only, optional): decides disputes after a Reject.
//   - minTier: 0 = any agent; 1..5 = Gladiator..Rudiarius and up.
//   - splits / trialFee (selection only): winners' split, e.g. "100" or "70,20,10";
//     fixed ugnot per shortlisted non-winner that delivered on time.
func PostJob(cur realm, title, specURL, category, mode string, workMin, reviewMin int, agent, arbiter string, minTier int, splits string, trialFee int64) int {
	prev := cur.Previous()
	if !prev.IsUserCall() {
		panic("PostJob must be called directly by a user (maketx call)")
	}
	pay := int64(unsafe.OriginSend().AmountOf("ugnot"))
	if pay < MinPot {
		panic(ufmt.Sprintf("pay too small: send at least %d ugnot", MinPot))
	}
	title, agent, arbiter, mode = clean(title), clean(agent), clean(arbiter), strings.ToLower(clean(mode))
	mustLen("title", title, 3, 80)
	if clean(specURL) != "" {
		specURL = mustWorkURL("specURL", specURL)
	} else {
		specURL = ""
	}
	category = mustCategory(category)
	if mode == "" {
		mode = ModeDirect
	}
	if mode != ModeDirect && mode != ModeSelection {
		panic("mode must be direct or selection")
	}
	if workMin < 1 || workMin > MaxDuration {
		panic("workMin out of range")
	}
	if reviewMin < 1 || reviewMin > MaxDuration {
		panic("reviewMin out of range")
	}
	mustTier(minTier)
	creator := prev.Address()
	j := &Job{ID: nextJob, Title: title, SpecURL: specURL, Category: category, Mode: mode, MinTier: minTier,
		Pay: pay, Creator: creator, CreatedAt: time.Now(), WorkMin: workMin, ReviewMin: reviewMin,
		Status: JobOpen, apps: avl.NewTree(), trials: avl.NewTree()}
	j.Deadline = j.CreatedAt.Add(time.Duration(workMin) * time.Minute)
	if mode == ModeSelection {
		if agent != "" || arbiter != "" {
			panic("selection jobs take no named agent or arbiter")
		}
		setSelection(j, splits, trialFee)
	} else {
		if clean(splits) != "" || trialFee != 0 {
			panic("splits and trialFee are for selection jobs")
		}
		if arbiter != "" {
			j.Arbiter = mustAddr("arbiter", arbiter)
			if j.Arbiter == creator {
				panic("the arbiter must not be the creator")
			}
		}
		if agent != "" {
			j.Agent = mustAddr("agent", agent)
			if j.Agent == creator || j.Agent == j.Arbiter {
				panic("the agent must not be the creator or the arbiter")
			}
			j.Status = JobOffered
		}
	}
	jobs.Set(key(j.ID), j)
	openJobs.Set(key(j.ID), j)
	byCat.Set("j:"+category+":"+key(j.ID), j.ID)
	addJobRole(creator, j.ID)
	if j.Arbiter != "" {
		addJobRole(j.Arbiter, j.ID)
	}
	if j.Agent != "" {
		addJobRole(j.Agent, j.ID)
	}
	escrowed += pay
	nextJob++
	repChange(creator, func(r *Rep) { r.Posted++ })
	chain.Emit("JobPosted", "id", strconv.Itoa(j.ID), "creator", creator.String(), "pay", strconv.FormatInt(pay, 10), "category", category, "mode", mode)
	return j.ID
}

// setSelection validates and applies selection settings. Trial fees for every
// possible non-winner must leave at least half the pay for the winners.
func setSelection(j *Job, splits string, trialFee int64) {
	if clean(splits) == "" {
		splits = "100"
	}
	sp := rankpay.ParseSplits(splits)
	if len(sp) > maxShortlist {
		panic(ufmt.Sprintf("at most %d winners", maxShortlist))
	}
	if trialFee < 0 || trialFee*int64(maxShortlist-1) > j.Pay/2 {
		panic(ufmt.Sprintf("trialFee must be 0-%d ugnot (all fees at most half the pay)", j.Pay/2/int64(maxShortlist-1)))
	}
	j.Mode, j.Splits, j.TrialFee = ModeSelection, sp, trialFee
	j.ReviewBy = j.Deadline.Add(time.Duration(j.ReviewMin) * time.Minute)
}

// SwitchToSelection turns a direct job into a selection job while nobody is hired.
func SwitchToSelection(cur realm, id int, splits string, trialFee int64) {
	j := mustJobCreator(cur, id)
	if j.Mode != ModeDirect || j.Status != JobOpen {
		panic("only an open direct job with nobody hired can switch to selection")
	}
	if !time.Now().Before(j.Deadline) {
		panic("the job deadline has passed")
	}
	if j.Arbiter != "" {
		panic("selection jobs take no arbiter")
	}
	setSelection(j, splits, trialFee)
	chain.Emit("JobModeSwitched", "id", strconv.Itoa(id), "mode", ModeSelection)
}

// Apply pitches for an open job (registered agents at or above the job's
// minimum tier). pitch up to 500 chars; sample: optional https/ipfs link.
// Calling again updates the pitch.
func Apply(cur realm, id int, pitch, sample string) {
	caller := cur.Previous().Address()
	j := mustJob(id)
	if j.Status != JobOpen || !time.Now().Before(j.Deadline) {
		panic("job is not taking applications")
	}
	if a, ok := agents.Get(caller.String()).(*Agent); !ok || a == nil {
		panic("register your agent first (Register)")
	}
	if caller == j.Creator || caller == j.Arbiter {
		panic("the creator and the arbiter cannot apply")
	}
	mustMinTier(caller, j.MinTier)
	pitch = clean(pitch)
	mustLen("pitch", pitch, 3, MaxPitch)
	if clean(sample) != "" {
		sample = mustWorkURL("sample", sample)
	} else {
		sample = ""
	}
	if ap, ok := j.apps.Get(caller.String()).(*Application); ok && ap != nil {
		ap.Pitch, ap.Sample, ap.At = pitch, sample, time.Now()
		return
	}
	if j.apps.Size() >= maxApps {
		panic("job has enough applications")
	}
	j.apps.Set(caller.String(), &Application{Agent: caller, Pitch: pitch, Sample: sample, At: time.Now()})
	j.appOrder = append(j.appOrder, caller)
	chain.Emit("JobApplied", "id", strconv.Itoa(id), "agent", caller.String())
}

// Hire picks one applicant for a direct job (creator only).
func Hire(cur realm, id int, agent string) {
	j := mustJobCreator(cur, id)
	if j.Mode != ModeDirect || j.Status != JobOpen || !time.Now().Before(j.Deadline) {
		panic("job is not open for hiring")
	}
	ap := mustApplicant(j, agent)
	mustMinTier(ap.Agent, j.MinTier) // tier may have dropped since applying (AUDIT H9)
	j.Agent, j.Status = ap.Agent, JobActive
	addJobRole(ap.Agent, id)
	repChange(ap.Agent, func(r *Rep) { r.Hired++ })
	chain.Emit("JobHired", "id", strconv.Itoa(id), "agent", ap.Agent.String())
}

// Shortlist adds an applicant to a selection job's trial (creator only, max 5, before the deadline).
func Shortlist(cur realm, id int, agent string) {
	j := mustJobCreator(cur, id)
	if j.Mode != ModeSelection || j.Status != JobOpen || !time.Now().Before(j.Deadline) {
		panic("job is not open for shortlisting")
	}
	ap := mustApplicant(j, agent)
	mustMinTier(ap.Agent, j.MinTier)
	if _, ok := j.trials.Get(ap.Agent.String()).(*Trial); ok {
		panic("already shortlisted")
	}
	if len(j.shortlist) >= maxShortlist {
		panic(ufmt.Sprintf("shortlist is full (%d)", maxShortlist))
	}
	j.shortlist = append(j.shortlist, ap.Agent)
	j.trials.Set(ap.Agent.String(), &Trial{Agent: ap.Agent})
	addJobRole(ap.Agent, id)
	repChange(ap.Agent, func(r *Rep) { r.Hired++ })
	chain.Emit("JobShortlisted", "id", strconv.Itoa(id), "agent", ap.Agent.String())
}

// Accept takes an offered direct job (the named agent only).
func Accept(cur realm, id int) {
	caller := cur.Previous().Address()
	j := mustJob(id)
	if j.Status != JobOffered || caller != j.Agent {
		panic("only the named agent can accept an offered job")
	}
	if !time.Now().Before(j.Deadline) {
		panic("the job deadline has passed")
	}
	mustMinTier(caller, j.MinTier)
	j.Status = JobActive
	repChange(caller, func(r *Rep) { r.Hired++ })
	chain.Emit("JobAccepted", "id", strconv.Itoa(id), "agent", caller.String())
}

// Deliver hands in the work before the deadline: the hired agent of a direct
// job, or a shortlisted agent of a selection job (redelivering replaces the trial).
// kind: link, image, video, file, text, repo. url: https:// or ipfs://.
// hash: optional sha256 of the content. text: only for kind text (max 2,000 chars).
func Deliver(cur realm, id int, kind, url, hash, text, note string) {
	caller := cur.Previous().Address()
	j := mustJob(id)
	now := time.Now()
	kind, url, hash, text = mustDeliverable(kind, url, hash, text)
	note = clean(note)
	mustLen("note", note, 0, MaxText)
	if j.Mode == ModeSelection {
		t, ok := j.trials.Get(caller.String()).(*Trial)
		if !ok || t == nil || j.Status != JobOpen {
			panic("only a shortlisted agent can deliver a trial")
		}
		if !now.Before(j.Deadline) {
			panic("the job deadline has passed")
		}
		first := t.At.IsZero()
		t.Kind, t.URL, t.Hash, t.Text, t.Note, t.At = kind, url, hash, text, note, now
		if first {
			j.Deliveries++
			repChange(caller, func(r *Rep) { r.Delivered++ })
			repChange(j.Creator, func(r *Rep) { r.DeliveriesReceived++ })
		}
		chain.Emit("TrialDelivered", "id", strconv.Itoa(id), "agent", caller.String(), "kind", kind)
		return
	}
	if j.Status != JobActive || caller != j.Agent {
		panic("only the hired agent can deliver an active job")
	}
	if !now.Before(j.Deadline) {
		panic("the job deadline has passed")
	}
	j.Kind, j.URL, j.Hash, j.Text, j.Note = kind, url, hash, text, note
	j.DeliveredAt, j.Status = now, JobDelivered
	j.ReviewBy = now.Add(time.Duration(j.ReviewMin) * time.Minute)
	j.Deliveries++
	repChange(caller, func(r *Rep) { r.Delivered++ })
	repChange(j.Creator, func(r *Rep) { r.DeliveriesReceived++ })
	chain.Emit("JobDelivered", "id", strconv.Itoa(id), "agent", caller.String(), "kind", kind, "n", strconv.Itoa(j.Deliveries))
}

// Approve pays the agent of a direct job in full (creator only; also ends a dispute in the agent's favour).
func Approve(cur realm, id int) {
	j := mustJobCreator(cur, id)
	if j.Mode != ModeDirect || (j.Status != JobDelivered && j.Status != JobDisputed) {
		panic("nothing to approve")
	}
	fast := j.Status == JobDelivered && time.Now().Before(j.DeliveredAt.Add(time.Duration(j.ReviewMin)*time.Minute/2))
	repChange(j.Creator, func(r *Rep) {
		r.Approved++
		if fast {
			r.FastApprovals++
		}
	})
	repChange(j.Agent, func(r *Rep) { r.WorkApproved++ })
	settleDirect(cur, j, 100, "approved by the creator")
}

// Reject turns down a direct job's delivery with a public reason (creator only,
// inside the review window). With an arbiter the job goes to dispute. Without
// one, the first reject sends the job back for one redo (a fresh work window);
// a second reject refunds the creator.
func Reject(cur realm, id int, reason string) {
	j := mustJobCreator(cur, id)
	if j.Mode != ModeDirect || j.Status != JobDelivered {
		panic("nothing to reject")
	}
	now := time.Now()
	if !now.Before(j.ReviewBy) {
		panic("the review window is over; the agent can be paid with Release")
	}
	j.RejectReason = mustReason(reason)
	j.Rejects++
	repChange(j.Creator, func(r *Rep) { r.RejectsIssued++ })
	repChange(j.Agent, func(r *Rep) { r.WorkRejected++ })
	ids := strconv.Itoa(id)
	switch {
	case j.Arbiter != "":
		j.Status = JobDisputed
		j.ResolveBy = now.Add(time.Duration(j.ReviewMin) * time.Minute)
		chain.Emit("JobDisputed", "id", ids, "reason", j.RejectReason)
	case j.Rejects == 1:
		j.Status = JobActive
		j.Deadline = now.Add(time.Duration(j.WorkMin) * time.Minute)
		chain.Emit("JobRedo", "id", ids, "reason", j.RejectReason)
	default:
		settleDirect(cur, j, 0, "second reject without an arbiter")
	}
}

// Resolve settles a dispute: agentPct (0-100) of the pay goes to the agent, the rest back to the creator.
func Resolve(cur realm, id int, agentPct int) {
	caller := cur.Previous().Address()
	j := mustJob(id)
	if j.Status != JobDisputed || caller != j.Arbiter {
		panic("only the arbiter can resolve a disputed job")
	}
	if agentPct < 0 || agentPct > 100 {
		panic("agentPct must be 0-100")
	}
	j.Resolved = true
	if agentPct >= 50 {
		repChange(j.Creator, func(r *Rep) { r.DisputesLost++ })
		repChange(j.Agent, func(r *Rep) { r.ADisputesWon++ })
	} else {
		repChange(j.Creator, func(r *Rep) { r.DisputesWon++ })
		repChange(j.Agent, func(r *Rep) { r.ADisputesLost++ })
	}
	settleDirect(cur, j, agentPct, "resolved by the arbiter")
}

// Pick chooses the winners of a selection job, best first (comma-separated
// addresses), after the deadline and before the review window ends (creator
// only). Winners must have delivered on time; at most one per split place.
// Unfilled places are spread over the picked ones.
func Pick(cur realm, id int, winners string) {
	j := mustJobCreator(cur, id)
	mustSelectionReview(j)
	// validate everything before touching state
	var picked []*Trial
	seen := map[string]bool{}
	for _, w := range strings.Split(winners, ",") {
		w = strings.TrimSpace(w)
		if w == "" {
			continue
		}
		t, ok := j.trials.Get(w).(*Trial)
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
		repChange(t.Agent, func(r *Rep) { r.WorkApproved++ })
	}
	fast := time.Now().Before(j.Deadline.Add(time.Duration(j.ReviewMin) * time.Minute / 2))
	repChange(j.Creator, func(r *Rep) {
		r.Approved++
		if fast {
			r.FastApprovals++
		}
	})
	settleSelection(cur, j, "winners picked")
}

// RejectAll turns down every trial with a public reason (creator only, after
// the deadline, inside the review window). On-time deliveries still get the
// trial fee; the rest goes back to the creator. Recorded on the creator's
// profile like a disqualify-all.
func RejectAll(cur realm, id int, reason string) {
	j := mustJobCreator(cur, id)
	mustSelectionReview(j)
	j.RejectReason = mustReason(reason)
	j.RejectedAll = true
	feesFor(j)
	repChange(j.Creator, func(r *Rep) {
		r.RejectsIssued++
		r.DQAll++
	})
	for _, a := range j.shortlist {
		if t := j.trials.Get(a.String()).(*Trial); !t.At.IsZero() {
			repChange(a, func(r *Rep) { r.WorkRejected++ })
		}
	}
	settleSelection(cur, j, "all trials rejected")
}

// Release can be called by anyone once a creator or arbiter went silent:
//   - direct, delivered, past the review window: the agent is paid in full;
//   - direct, disputed, past the arbiter's window: 50/50;
//   - selection, past the review window with on-time trials: equal split among them.
func Release(cur realm, id int) {
	j := mustJob(id)
	now := time.Now()
	switch {
	case j.Mode == ModeDirect && j.Status == JobDelivered && !now.Before(j.ReviewBy):
		j.AutoReleased = true
		repChange(j.Creator, func(r *Rep) { r.AutoReleased++ })
		settleDirect(cur, j, 100, "creator silent past the review window")
	case j.Mode == ModeDirect && j.Status == JobDisputed && !now.Before(j.ResolveBy):
		j.AutoReleased = true
		settleDirect(cur, j, 50, "arbiter silent: equal split")
	case j.Mode == ModeSelection && j.Status == JobOpen && !now.Before(j.ReviewBy) && j.Deliveries > 0:
		j.AutoReleased = true
		var ok []*Trial
		for _, a := range j.shortlist {
			if t := j.trials.Get(a.String()).(*Trial); !t.At.IsZero() {
				ok = append(ok, t)
			}
		}
		shares := rankpay.EqualShares(j.Pay, len(ok))
		for i, t := range ok {
			t.Payout = shares[i]
		}
		repChange(j.Creator, func(r *Rep) { r.AutoReleased++ })
		settleSelection(cur, j, "creator silent: equal split among on-time trials")
	default:
		panic("nothing to release yet")
	}
}

// Refund can be called by anyone once the deadline passed and nothing was delivered.
func Refund(cur realm, id int) {
	j := mustJob(id)
	if time.Now().Before(j.Deadline) {
		panic("the deadline has not passed")
	}
	if j.Mode == ModeSelection {
		if j.Status != JobOpen || j.Deliveries > 0 {
			panic("job cannot be refunded")
		}
		j.NoDelivery = true
		for _, a := range j.shortlist {
			repChange(a, func(r *Rep) { r.Missed++ })
		}
		if len(j.shortlist) > 0 {
			repChange(j.Creator, func(r *Rep) { r.RefundsNoDelivery++ })
		}
		settleSelection(cur, j, "no trial delivered")
		return
	}
	if j.Status != JobOpen && j.Status != JobOffered && j.Status != JobActive {
		panic("job cannot be refunded")
	}
	if j.Status == JobActive {
		j.NoDelivery = true
		repChange(j.Agent, func(r *Rep) { r.Missed++ })
		repChange(j.Creator, func(r *Rep) { r.RefundsNoDelivery++ })
	}
	settleDirect(cur, j, 0, "no delivery by the deadline")
}

// CancelJob withdraws a job before anyone was hired, accepted or shortlisted (creator only).
func CancelJob(cur realm, id int) {
	j := mustJobCreator(cur, id)
	if (j.Status != JobOpen && j.Status != JobOffered) || len(j.shortlist) > 0 {
		panic("cannot cancel: an agent is already working")
	}
	j.Status = JobCancelled
	repChange(j.Creator, func(r *Rep) { r.Cancellations++ })
	settleDirect(cur, j, 0, "cancelled by the creator")
}

// ---------- settlement ----------

// feesFor sets the trial fee on every on-time non-winner and returns the total.
func feesFor(j *Job) int64 {
	var total int64
	for _, a := range j.shortlist {
		t := j.trials.Get(a.String()).(*Trial)
		if !t.At.IsZero() && t.Place == 0 {
			t.Payout = j.TrialFee
			total += j.TrialFee
		}
	}
	return total
}

func settleDirect(cur realm, j *Job, agentPct int, why string) {
	toAgent := j.Pay * int64(agentPct) / 100
	j.AgentPct = agentPct
	var pays []payee
	if toAgent > 0 {
		pays = append(pays, payee{j.Agent, toAgent})
	}
	settle(cur, j, pays, why)
}

func settleSelection(cur realm, j *Job, why string) {
	var pays []payee
	for _, a := range j.shortlist {
		if t := j.trials.Get(a.String()).(*Trial); t.Payout > 0 {
			pays = append(pays, payee{a, t.Payout})
		}
	}
	settle(cur, j, pays, why)
}

type payee struct {
	to     address
	amount int64
}

// settle closes the job exactly once: state first, then coins. Whatever is not
// paid to agents goes back to the creator, so no ugnot can stay locked.
func settle(cur realm, j *Job, pays []payee, why string) {
	if _, ok := openJobs.Get(key(j.ID)).(*Job); !ok {
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
	case j.Status == JobCancelled:
	case back == 0:
		j.Status = JobPaid
	case toAgents == 0:
		j.Status = JobRefunded
	default:
		j.Status = JobSplit
	}
	j.PaidAgents, j.Returned, j.ClosedAt = toAgents, back, time.Now()
	openJobs.Remove(key(j.ID))
	escrowed -= j.Pay
	totalPaid += toAgents
	refunded += back
	for _, p := range pays {
		amt := p.amount
		if a, ok := agents.Get(p.to.String()).(*Agent); ok && a != nil {
			reindex(a, func() { a.Earned += amt })
		}
		repChange(p.to, func(r *Rep) { r.Earned += amt })
	}
	if toAgents > 0 {
		repChange(j.Creator, func(r *Rep) {
			r.PaidOut += toAgents
			r.PaidItems++
		})
	}
	bk := banker.NewBanker(banker.BankerTypeRealmSend, cur)
	from := cur.Address()
	for _, p := range pays {
		bk.SendCoins(from, p.to, chain.Coins{{"ugnot", p.amount}})
	}
	if back > 0 {
		bk.SendCoins(from, j.Creator, chain.Coins{{"ugnot", back}})
	}
	chain.Emit("JobClosed", "id", strconv.Itoa(j.ID), "status", j.Status, "paid", strconv.FormatInt(toAgents, 10), "why", why)
}

// ---------- helpers ----------

func mustSelectionReview(j *Job) {
	if j.Mode != ModeSelection || j.Status != JobOpen {
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

func mustApplicant(j *Job, agent string) *Application {
	ap, ok := j.apps.Get(clean(agent)).(*Application)
	if !ok || ap == nil {
		panic("that address has not applied")
	}
	return ap
}

func mustJob(id int) *Job {
	j, ok := jobs.Get(key(id)).(*Job)
	if !ok || j == nil {
		panic("job not found")
	}
	return j
}

func mustJobCreator(cur realm, id int) *Job {
	j := mustJob(id)
	if cur.Previous().Address() != j.Creator {
		panic("only the job creator can do this")
	}
	return j
}

func mustAddr(field, s string) address {
	a := address(s)
	if !a.IsValid() {
		panic("invalid " + field + " address")
	}
	return a
}

// addJobRole indexes a job under an address, keeping the newest maxJobRoleIDs (AUDIT F5).
func addJobRole(a address, id int) {
	ids, _ := jobRoles.Get(a.String()).([]int)
	if n := len(ids); n > 0 && ids[n-1] == id {
		return
	}
	ids = append(ids, id)
	if len(ids) > maxJobRoleIDs {
		ids = ids[len(ids)-maxJobRoleIDs:]
	}
	jobRoles.Set(a.String(), ids)
}

// JobPhase is the live phase of a job, derived from time.
func JobPhase(id int) string { return jobPhase(mustJob(id)) }

func jobPhase(j *Job) string {
	now := time.Now()
	switch j.Status {
	case JobOpen:
		if j.Mode == ModeSelection && !now.Before(j.Deadline) {
			switch {
			case j.Deliveries == 0:
				return "expired" // anyone can Refund
			case now.Before(j.ReviewBy):
				return "picking" // creator compares trials
			}
			return "releasable" // anyone can Release (equal split)
		}
		if !now.Before(j.Deadline) {
			return "expired"
		}
	case JobOffered, JobActive:
		if !now.Before(j.Deadline) {
			return "expired"
		}
	case JobDelivered:
		if !now.Before(j.ReviewBy) {
			return "releasable"
		}
	case JobDisputed:
		if !now.Before(j.ResolveBy) {
			return "releasable"
		}
	}
	return j.Status
}
