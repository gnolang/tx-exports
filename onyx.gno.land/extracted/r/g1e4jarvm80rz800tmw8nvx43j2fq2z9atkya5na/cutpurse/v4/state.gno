package cutpurse

const (
	Denom = "ugnot"

	// SPEC §4 domain constants.
	Seats            = 4
	Rounds           = 3
	MinFee           = 100000
	MaxFee           = 5000000
	JoinBlocks       = 600
	CommitBlocks     = 200
	RevealBlocks     = 150
	BustAlarm        = 3
	TreasuryBps      = 500
	LiveJobsMax      = 40
	LedgerMax        = 500
	TraitorBustShare = 60

	// MaxSecured is the best possible Secured for a job: 2 per carry, every
	// round, every seat. The treasury cut scales against it so the 5% lands on
	// the pot instead of rounding to zero ugnot.
	MaxSecured = 2 * Seats * Rounds

	// write-time bounds
	MaxNameRunes = 40
	MaxSaltLen   = 64
	MaxListLimit = 50
)

type Phase uint8

const (
	PhaseOpen Phase = iota
	PhaseCommit
	PhaseReveal
	PhaseSettled
	PhaseBusted
)

type Action uint8

const (
	ActNone Action = iota
	ActScout
	ActPick
	ActCarry
	ActWatch
)

// Seat is one player slot. Revealed is derived: Action != ActNone.
type Seat struct {
	Addr         address
	Committed    bool
	CommitHash   string
	Action       Action
	Auto         bool
	Contribution int64
}

type Job struct {
	ID        int64
	Name      string
	Creator   address
	Fee       int64
	Pot       int64
	Phase     Phase
	Round     uint8
	Deadline  int64
	Seats     [Seats]Seat
	NSeats    uint8
	Alarm     int64
	Loot      int64
	Secured   int64
	Seed      string
	Traitor   int8
	Revealed  bool
	OpenedAt  int64
	SettledAt int64
}

// Result is a permanent ledger ring entry.
type Result struct {
	JobID   int64
	Name    string
	Busted  bool
	Loot    int64
	Traitor address
	At      int64
	Payouts string
}

type Stats struct {
	Jobs    int64
	Escapes int64
	Busts   int64
	Loot    int64
}

var (
	jobs       map[int64]*Job
	nextID     int64
	liveCount  int64
	active     map[address]int64
	ledger     [LedgerMax]*Result
	ledgerLen  int
	ledgerHead int
	treasury   int64
	// hist is a per-wallet ring of the most recent archived results, newest
	// first, capped at HistMax. It exists because scanning the ledger ring to
	// answer "this wallet's history" cost ~660k gas per entry scanned and blew
	// a full-ring miss past 100M (§10 R10).
	hist map[address][]Result
	// stats is keyed by the bech32 address string so that profile views can
	// look a player up in O(1) without a string->address parser (SPEC §4 says
	// map[address]*Stats; the key type is the only deviation, logged in STATE).
	stats map[string]*Stats
)

func init() {
	jobs = make(map[int64]*Job)
	active = make(map[address]int64)
	stats = make(map[string]*Stats)
}
