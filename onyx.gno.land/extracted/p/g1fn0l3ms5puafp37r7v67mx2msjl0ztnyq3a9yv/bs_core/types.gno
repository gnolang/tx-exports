// Package bs_core provides pure, stateless constants, enums, integer-exact
// economic calculations, and input validation/escaping helpers for BountySiege.
// It holds no mutable state and never touches coins directly.
package bs_core

// Native coin denomination accepted by BountySiege.
const DenomUgnot = "ugnot"

// Economic bounds in ugnot (1 GNOT = 1_000_000 ugnot).
const (
	UgnotPerGnot      int64 = 1_000_000
	MinRewardUgnot    int64 = 1_000_000 // 1 GNOT per Quest / Contest / Raid Slot
	MinRewardForXP    int64 = 5_000_000 // 5 GNOT threshold for XP & Badges
	MinStakePct       int64 = 5         // 5% of reward
	MaxStakePct       int64 = 15        // 15% of reward
	DisputeFeePct     int64 = 5         // 5% of reward
	ProtocolFeePct    int64 = 2         // 2% floor on builder/submitter payouts
	MinContestSlotPct int   = 5         // minimum 5% share per contest winner slot
	MaxContestSlots   int   = 10        // max winner positions in a contest
	MinRaidSlots      int   = 2         // min independent slots in a Co-op Raid
	MaxRaidSlots      int   = 4         // max independent slots in a Co-op Raid
)

// Duration bounds in seconds.
const (
	HourSec                  int64 = 3600
	DaySec                   int64 = 86400
	MinOpenDurationSec       int64 = 24 * HourSec
	MaxOpenDurationSec       int64 = 90 * DaySec
	MinWorkDurationSec       int64 = 24 * HourSec
	MaxWorkDurationSec       int64 = 30 * DaySec
	MinReviewDurationSec     int64 = 24 * HourSec
	MaxReviewDurationSec     int64 = 7 * DaySec
	RevisionDurationSec      int64 = 24 * HourSec
	MaxRevisions             int   = 2
	DisputeWindowSec         int64 = 48 * HourSec
	ArbiterTimeoutSec        int64 = 7 * DaySec
	ArbiterTimelockSec       int64 = 48 * HourSec
	MinJudgingDurationSec    int64 = 24 * HourSec
	MaxJudgingDurationSec    int64 = 14 * DaySec
	PullPaymentClaimExpiry   int64 = 30 * DaySec
	PairXPCooldownSec        int64 = 7 * DaySec
)

// Text length & anti-bloat caps (in bytes / counts).
const (
	MaxTitleBytes            = 120
	MaxDescBytes             = 2000
	MaxCriteriaBytes         = 2000
	MaxURLBytes              = 256
	MaxNoteBytes             = 500
	MaxGuildNameBytes        = 64
	MaxGuildBioBytes         = 300
	MaxCommentsPerMission    = 100
	MaxCommentsPerAddr       = 10
	MaxContestSubmissions    = 200
	DefaultPageLimit         = 20
	MaxPageLimit             = 50
)

// QuestStatus represents the fixed-size uint8 state machine enum for
// Single-Claim Quests and independent Co-op Raid slots.
type QuestStatus uint8

const (
	QuestOpen QuestStatus = iota
	QuestInProgress
	QuestUnderReview
	QuestRevisionRequested
	QuestRejected
	QuestDisputed
	QuestCompleted
	QuestCancelled
	QuestResolvedTimeout
)

func (s QuestStatus) String() string {
	switch s {
	case QuestOpen:
		return "open"
	case QuestInProgress:
		return "in_progress"
	case QuestUnderReview:
		return "under_review"
	case QuestRevisionRequested:
		return "revision_requested"
	case QuestRejected:
		return "rejected"
	case QuestDisputed:
		return "disputed"
	case QuestCompleted:
		return "completed"
	case QuestCancelled:
		return "cancelled"
	case QuestResolvedTimeout:
		return "resolved_timeout"
	default:
		return "unknown"
	}
}

func (s QuestStatus) IsTerminal() bool {
	return s == QuestCompleted || s == QuestCancelled || s == QuestResolvedTimeout
}

// AttemptOutcome records the outcome of an append-only claim attempt.
type AttemptOutcome uint8

const (
	AttemptActive AttemptOutcome = iota
	AttemptNoShow
	AttemptApproved
	AttemptTimeoutClaimed
	AttemptRejectedFinal
	AttemptRevisionExpired
	AttemptDisputeWon
	AttemptDisputeLost
	AttemptDisputeTimeout
)

// ContestStatus represents the fixed-size uint8 state machine enum for Open Contests.
type ContestStatus uint8

const (
	ContestOpen ContestStatus = iota
	ContestJudging
	ContestDisputed
	ContestCompleted
	ContestCancelled
	ContestResolvedTimeout
)

func (s ContestStatus) String() string {
	switch s {
	case ContestOpen:
		return "open"
	case ContestJudging:
		return "judging"
	case ContestDisputed:
		return "disputed"
	case ContestCompleted:
		return "completed"
	case ContestCancelled:
		return "cancelled"
	case ContestResolvedTimeout:
		return "resolved_timeout"
	default:
		return "unknown"
	}
}

func (s ContestStatus) IsTerminal() bool {
	return s == ContestCompleted || s == ContestCancelled || s == ContestResolvedTimeout
}

// MissionType distinguishes comment & timeline namespaces.
type MissionType uint8

const (
	MissionQuest   MissionType = 1
	MissionContest MissionType = 2
	MissionRaid    MissionType = 3
)

func (m MissionType) String() string {
	switch m {
	case MissionQuest:
		return "quest"
	case MissionContest:
		return "contest"
	case MissionRaid:
		return "raid"
	default:
		return "unknown"
	}
}

// Category is the fixed-size allowlisted skill category enum.
type Category uint8

const (
	CatContract Category = iota
	CatFrontend
	CatDesign
	CatDocs
	CatSecurity
	CatAI
	CatCount // sentinel: total number of valid categories
)

func (c Category) IsValid() bool {
	return c < CatCount
}

func (c Category) String() string {
	switch c {
	case CatContract:
		return "contract"
	case CatFrontend:
		return "frontend"
	case CatDesign:
		return "design"
	case CatDocs:
		return "docs"
	case CatSecurity:
		return "security"
	case CatAI:
		return "ai"
	default:
		return "unknown"
	}
}

func ParseCategory(s string) (Category, bool) {
	switch s {
	case "contract":
		return CatContract, true
	case "frontend":
		return CatFrontend, true
	case "design":
		return CatDesign, true
	case "docs":
		return CatDocs, true
	case "security":
		return CatSecurity, true
	case "ai":
		return CatAI, true
	default:
		return CatCount, false
	}
}
