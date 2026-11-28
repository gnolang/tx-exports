package idox

import (
"chain"
"gno.land/p/nt/avl/v0"
)

type MilestoneStatus uint8

const (
StatusPending MilestoneStatus = iota
StatusSubmitted
StatusApproved
StatusRejected
)

type Badge struct {
ID          string
Name        string
Issuer      address
IssuedBlock int64
}

type BuilderProfile struct {
Addr            address
Handle          string
Badges          *avl.Tree
CompletedTasks  int
TotalEarned     int64
ReputationScore int
}

type GuardrailPolicy struct {
AgentAddr         address
MaxSinglePayout   int64
DailySpendLimit   int64
CooldownBlocks    int64
RequireBadgeMatch bool
Paused            bool
}

type Milestone struct {
ID            int
Title         string
RequiredBadge string
Allocation    int64
ProofHash     string
AuditNote     string
Status        MilestoneStatus
}

type ProjectVault struct {
ID             uint64
Title          string
Sponsor        address
Contractor     address
TotalEscrowed  chain.Coin
ReleasedAmount int64
Milestones     []*Milestone
CreatedBlock   int64
}

type AuditLog struct {
BlockHeight int64
ProjectID   uint64
MilestoneID int
Action      string
Reason      string
}
