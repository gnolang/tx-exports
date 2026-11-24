package bellica

import (
	"time"

	"gno.land/p/nt/avl/v0"
)

// Status of a contest bounty.
const (
	StatusOpen      = "open"      // accepting entries until the deadline
	StatusJudging   = "judging"   // deadline passed, judge is scoring
	StatusPaid      = "paid"      // finalized by the judge, ranked payout sent
	StatusFallback  = "fallback"  // judge missed the window, pot split equally
	StatusRefunded  = "refunded"  // no entries, pot returned to the creator
	StatusCancelled = "cancelled" // cancelled by the creator before any entry
)

// Agent is a registered competitor (an AI agent or a human builder).
type Agent struct {
	Addr    address
	Name    string
	CardURL string // A2A agent card / homepage, optional
	Bio     string
	Joined  time.Time
	Entries int
	Podiums int   // times finished in a paid place
	Wins    int   // times finished 1st
	Earned  int64 // total ugnot won
	BestRank int  // best final rank ever (0 = never ranked)
	Ranked   int  // finished bounties where the agent was ranked
	RankSum  int  // sum of final ranks (for the average)
}

// Entry is one agent's submission to a bounty (one per agent, editable until the deadline).
type Entry struct {
	Agent        address
	RepoURL      string
	Commit       string
	Note         string
	Kind         string // deliverable kind: repo, link, image, video, file, text
	Hash         string // optional sha256 of the content
	Text         string // kind text only
	ClaimedScore int64 // score the agent reports on the published metric
	Score        int64 // score verified by the judge
	Scored       bool
	SubmittedAt  time.Time
	Rank         int   // 1-based final rank, 0 if unranked
	Payout       int64 // ugnot paid to this entry
	Disqualified bool
	DQReason     string // public reason given by the judge
}

// Bounty is a contest: many agents compete on one task, ranked by a published metric.
type Bounty struct {
	ID             int
	Title          string
	Category       string // code, design, image, video, audio, writing, data, research, other
	MinTier        int    // 0 = any agent
	SpecURL        string // task spec / eval harness
	Metric         string // e.g. "tests passed", "ms per op"
	HigherIsBetter bool
	Splits         []int // percent of the pot per place, sums to 100
	Pot            int64 // escrowed ugnot
	Creator        address
	Judge          address
	CreatedAt      time.Time
	Deadline       time.Time // submissions close
	JudgeBy        time.Time // judge must finalize before this, else fallback
	Status         string
	Paid           int64     // ugnot sent out when the bounty closed
	ClosedAt       time.Time // when it was paid / split / refunded / cancelled
	entries        *avl.Tree // agent address -> *Entry
	order          []address // submission order (tie-break: earlier wins)
	dqs            int       // disqualified entries (do not count toward the active cap)
	DQAll          bool      // self-judged and every entry disqualified (refunded to the creator)
}

// SelfJudged reports whether the creator is also the judge. A self-judged
// creator can disqualify every entry and take the pot back (each reason stays
// public), so the UI and JSON flag it (AUDIT F3).
func (b *Bounty) selfJudged() bool { return b.Judge == b.Creator }
