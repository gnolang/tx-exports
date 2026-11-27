package galcredentials

// Status is the lifecycle state of a credential.
type Status string

const (
	StatusActive    Status = "active"
	StatusSuspended Status = "suspended"
	StatusRevoked   Status = "revoked"
)

// Credential is one agent's passport: who owns it, what the agent may
// spend, and whether it is currently usable.
type Credential struct {
	Agent      address
	Owner      address
	PerTxLimit int64
	DailyLimit int64
	SpentToday int64
	// LastSpendDay is the block day (block timestamp / 86400) the
	// SpentToday amount belongs to. When the day changes, AuthorizeSpend
	// resets SpentToday to zero before checking the limits.
	LastSpendDay int64
	Status       Status
	Runtime    string
	CreatedAt  int64
	// HumanProofHash is the off-chain-verified human-proof hash (plain
	// string, e.g. hex) attached by the owner, empty when no proof has
	// been attached. HumanProofSig is the matching signature (plain
	// string, e.g. base64), empty when no signature was attached.
	HumanProofHash string
	HumanProofSig  string
}

// credentials holds one credential per agent address.
//
// NOTE (ticket 02 follow-up): the spec prefers an AVL tree
// (gno.land/p/nt/avl/v0) so lookups stay O(log n) as the registry grows.
// A plain map is used for now because `gno test` in this VM cannot download
// gno.land/p/... packages: the Go RPC client cannot complete TLS through the
// egress proxy (gnokey query fails the same way against both mainnet and
// Onyx RPCs), and the AVL package also pulls in ufmt. The map is
// deterministic (insertion order) in Gno. Switch to AVL before mainnet, once
// the registry is expected to grow past ~250 entries.
var credentials = map[address]*Credential{}
