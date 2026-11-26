package milestonevault

import "strconv"

const (
	VaultStatusOpen      = "OPEN"
	VaultStatusActive    = "ACTIVE"
	VaultStatusDisputed  = "DISPUTED"
	VaultStatusCompleted = "COMPLETED"
	VaultStatusCancelled = "CANCELLED"

	MilestonePending   = "PENDING"
	MilestoneSubmitted = "SUBMITTED"
	MilestoneApproved  = "APPROVED"
	MilestoneRefunded  = "REFUNDED"
	MilestoneSplit     = "SPLIT"

	VoteRelease = "RELEASE"
	VoteRefund  = "REFUND"
	VoteSplit   = "SPLIT"

	DenomUGNOT = "ugnot"
)

// Milestone represents a single verifiable deliverable tranche inside a Vault.
type Milestone struct {
	ID                int
	Title             string
	AmountUgnot       int64
	Bps               int64
	Status            string
	EvidenceURL       string
	SubmittedAtHeight int64
	ApprovedAtHeight  int64
}

// Application tracks a builder's on-chain proposal to take on an OPEN vault.
type Application struct {
	Builder         address
	Pitch           string
	AppliedAtHeight int64
}

// Dispute tracks active or resolved arbiter council voting for a disputed milestone.
type Dispute struct {
	Active          bool
	MilestoneID     int
	OpenedBy        address
	Reason          string
	OpenedAtHeight  int64
	VotesRelease    int
	VotesRefund     int
	VotesSplit      int
	QuorumRequired  int
	ResolvedOutcome string
	Voted           map[address]string
}

// Vault is an isolated sub-realm milestone escrow contract.
// All escrowed ugnot is held inside the vault's dedicated cur.Sub(SubPath) address.
type Vault struct {
	ID                int
	Title             string
	Description       string
	Sponsor           address
	Builder           address
	SubPath           string
	EscrowAddr        address
	Status            string
	TotalDepositUgnot int64
	ReleasedUgnot     int64
	RefundedUgnot     int64
	TimeoutBlocks     int64
	CreatedAtHeight   int64
	Arbiters          []address
	Milestones        []*Milestone
	Applications      []*Application
	Dispute           *Dispute
}

// LockedAmount returns the theoretical unspent ugnot still escrowed in this vault.
func (v *Vault) LockedAmount() int64 {
	rem := v.TotalDepositUgnot - v.ReleasedUgnot - v.RefundedUgnot
	if rem < 0 {
		return 0
	}
	return rem
}

func (v *Vault) IsArbiter(addr address) bool {
	for _, a := range v.Arbiters {
		if a == addr {
			return true
		}
	}
	return false
}

func (v *Vault) GetMilestone(id int) *Milestone {
	if id < 1 || id > len(v.Milestones) {
		return nil
	}
	return v.Milestones[id-1]
}

func (v *Vault) AllMilestonesSettled() bool {
	for _, m := range v.Milestones {
		if m.Status == MilestonePending || m.Status == MilestoneSubmitted {
			return false
		}
	}
	return true
}

// BuilderStats records immutable, verifiable on-chain track record per builder.
type BuilderStats struct {
	Address             address
	MilestonesCompleted int
	VaultsCompleted     int
	TotalEarnedUgnot    int64
	DisputesWon         int
	DisputesLost        int
}

func vaultSubPath(id int) string {
	return "v" + strconv.Itoa(id)
}
