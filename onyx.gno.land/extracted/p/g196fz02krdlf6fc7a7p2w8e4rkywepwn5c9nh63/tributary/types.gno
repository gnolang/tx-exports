package tributary

const (
	// ScaleBPS is 100.00% expressed in basis points.
	ScaleBPS int64 = 10000
	// MaxEdgesPerNode bounds fan-out per node for deterministic gas usage.
	MaxEdgesPerNode = 12
	// MaxDepth bounds DAG traversal depth to guarantee bounded execution.
	MaxDepth = 8
	// MaxReceiptsStored keeps recent deposit trace history bounded on-chain.
	MaxReceiptsStored = 25
)

// Edge defines a directed revenue-sharing split from a downstream node
// to an upstream dependency node.
type Edge struct {
	TargetID string
	BPS      int64 // 1..10000 (100 BPS = 1.00%)
	Label    string
}

// Node represents a package, realm, creator, or collective inside the DAG.
type Node struct {
	ID             string
	Title          string
	PkgRef         string
	Owner          address
	Beneficiary    address
	Edges          []Edge
	Locked         bool
	TotalInflow    int64
	TotalRetained  int64
	TotalForwarded int64
	CreatedHeight  int64
}

// TraceStep records one exact integer transfer along the waterfall during a deposit.
type TraceStep struct {
	FromID string
	ToID   string // empty when retained by FromID's beneficiary
	Amount int64
	BPS    int64
}

// DepositReceipt captures an auditable summary of one routed deposit.
type DepositReceipt struct {
	Seq       int64
	EntryID   string
	Depositor address
	Amount    int64
	Height    int64
	Hops      int
	Credits   int // distinct beneficiaries credited
	Memo      string
}

// ShareEntry summarizes the effective end-to-end share a beneficiary receives
// per 10,000 BPS deposited into a given root node.
type ShareEntry struct {
	NodeID      string
	Title       string
	Beneficiary address
	EffectiveBPS int64
}

// ForwardedBPS returns the sum of all outgoing split basis points for this node.
func (n *Node) ForwardedBPS() int64 {
	var sum int64
	for _, e := range n.Edges {
		sum += e.BPS
	}
	return sum
}

// RetainedBPS returns the share kept directly by this node's beneficiary.
func (n *Node) RetainedBPS() int64 {
	return ScaleBPS - n.ForwardedBPS()
}
