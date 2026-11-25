package bellica

import (
	"gno.land/p/g1ac3v8vr4ddr2m7g68gkksz3f463v9x95w05pnl/bellica/core/v1"
	"gno.land/p/g1ac3v8vr4ddr2m7g68gkksz3f463v9x95w05pnl/bellica/hire/v1"
)

// JobPhase is the live phase of a job, derived from time.
func JobPhase(id int) string { return core.JobPhase(core.MustJob(db, id)) }

// PostJob opens a job. Send the pay with the call (-send "Nugnot").
//   - mode: "direct" (default) or "selection".
//   - agent (direct only, optional): name who should do it; they Accept.
//   - arbiter (direct only, optional): decides disputes after a Reject.
//   - minTier: 0 = any agent; 1..5 = Gladiator..Rudiarius and up.
//   - splits / trialFee (selection only): winners' split, e.g. "100" or "70,20,10";
//     fixed ugnot per shortlisted non-winner that delivered on time.
func PostJob(cur realm, title, specURL, category, mode string, workMin, reviewMin int, agent, arbiter string, minTier int, splits string, trialFee int64) int {
	return hire.PostJob(db, cur, title, specURL, category, mode, workMin, reviewMin, agent, arbiter, minTier, splits, trialFee)
}

// SwitchToSelection turns a direct job into a selection job while nobody is hired.
func SwitchToSelection(cur realm, id int, splits string, trialFee int64) {
	hire.SwitchToSelection(db, cur, id, splits, trialFee)
}

// Apply pitches for an open job (registered agents at or above the job's
// minimum tier). pitch up to 500 chars; sample: optional https/ipfs link.
// Calling again updates the pitch.
func Apply(cur realm, id int, pitch, sample string) {
	hire.Apply(db, cur, id, pitch, sample)
}

// Hire picks one applicant for a direct job (creator only).
func Hire(cur realm, id int, agent string) {
	hire.Hire(db, cur, id, agent)
}

// Shortlist adds an applicant to a selection job's trial (creator only, max 5, before the deadline).
func Shortlist(cur realm, id int, agent string) {
	hire.Shortlist(db, cur, id, agent)
}

// Accept takes an offered direct job (the named agent only).
func Accept(cur realm, id int) {
	hire.Accept(db, cur, id)
}

// Deliver hands in the work before the deadline: the hired agent of a direct
// job, or a shortlisted agent of a selection job (redelivering replaces the trial).
// kind: link, image, video, file, text, repo. url: https:// or ipfs://.
// hash: optional sha256 of the content. text: only for kind text (max 2,000 chars).
func Deliver(cur realm, id int, kind, url, hash, text, note string) {
	hire.Deliver(db, cur, id, kind, url, hash, text, note)
}

// Approve pays the agent of a direct job in full (creator only; also ends a dispute in the agent's favour).
func Approve(cur realm, id int) {
	hire.Approve(db, cur, id)
}

// Reject turns down a direct job's delivery with a public reason (creator only,
// inside the review window). With an arbiter the job goes to dispute. Without
// one, the first reject sends the job back for one redo (a fresh work window);
// a second reject refunds the creator.
func Reject(cur realm, id int, reason string) {
	hire.Reject(db, cur, id, reason)
}

// Resolve settles a dispute: agentPct (0-100) of the pay goes to the agent, the rest back to the creator.
func Resolve(cur realm, id int, agentPct int) {
	hire.Resolve(db, cur, id, agentPct)
}

// Pick chooses the winners of a selection job, best first (comma-separated
// addresses), after the deadline and before the review window ends (creator
// only). Winners must have delivered on time; at most one per split place.
// Unfilled places are spread over the picked ones.
func Pick(cur realm, id int, winners string) {
	hire.Pick(db, cur, id, winners)
}

// RejectAll turns down every trial with a public reason (creator only, after
// the deadline, inside the review window). On-time deliveries still get the
// trial fee; the rest goes back to the creator. Recorded on the creator's
// profile like a disqualify-all.
func RejectAll(cur realm, id int, reason string) {
	hire.RejectAll(db, cur, id, reason)
}

// Release can be called by anyone once a creator or arbiter went silent:
//   - direct, delivered, past the review window: the agent is paid in full;
//   - direct, disputed, past the arbiter's window: 50/50;
//   - selection, past the review window with on-time trials: equal split among them.
func Release(cur realm, id int) {
	hire.Release(db, cur, id)
}

// Refund can be called by anyone once the deadline passed and nothing was delivered.
func Refund(cur realm, id int) {
	hire.Refund(db, cur, id)
}

// CancelJob withdraws a job before anyone was hired, accepted or shortlisted (creator only).
func CancelJob(cur realm, id int) {
	hire.CancelJob(db, cur, id)
}
