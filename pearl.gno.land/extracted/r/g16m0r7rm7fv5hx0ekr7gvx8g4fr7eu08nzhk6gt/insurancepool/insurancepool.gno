package insurancepool

type ClaimStatus int

const (
	ClaimPending ClaimStatus = iota
	ClaimApproved
	ClaimRejected
	ClaimPaid
)

type Policyholder struct {
	Addr        string
	Premium     int64
	Coverage    int64
	JoinedAt    int64
	Active      bool
}

type Claim struct {
	ID       string
	Claimant string
	Amount   int64
	Reason   string
	Status   ClaimStatus
	Filed    int64
	Approver string
}

type Pool struct {
	admin         string
	assessors     map[string]bool
	holders       map[string]*Policyholder
	claims        map[string]*Claim
	poolBalance   int64
	nextClaimSeq  int64
	currentHeight int64
	minPremium    int64
	coverageRatio int64 // coverage = premium * coverageRatio
}

func NewPool(admin string, minPremium, coverageRatio int64) *Pool {
	return &Pool{
		admin:         admin,
		assessors:     make(map[string]bool),
		holders:       make(map[string]*Policyholder),
		claims:        make(map[string]*Claim),
		minPremium:    minPremium,
		coverageRatio: coverageRatio,
	}
}

func (p *Pool) Tick(height int64) {
	if height > p.currentHeight {
		p.currentHeight = height
	}
}

func (p *Pool) AddAssessor(caller, addr string) bool {
	if caller != p.admin {
		return false
	}
	p.assessors[addr] = true
	return true
}

func (p *Pool) Join(addr string, premium int64) bool {
	if premium < p.minPremium {
		return false
	}
	if h, exists := p.holders[addr]; exists && h.Active {
		return false
	}
	p.poolBalance += premium
	p.holders[addr] = &Policyholder{
		Addr:     addr,
		Premium:  premium,
		Coverage: premium * p.coverageRatio,
		JoinedAt: p.currentHeight,
		Active:   true,
	}
	return true
}

func (p *Pool) TopUp(addr string, amount int64) bool {
	h, ok := p.holders[addr]
	if !ok || !h.Active || amount <= 0 {
		return false
	}
	p.poolBalance += amount
	h.Premium += amount
	h.Coverage = h.Premium * p.coverageRatio
	return true
}

func (p *Pool) Leave(addr string) bool {
	h, ok := p.holders[addr]
	if !ok || !h.Active {
		return false
	}
	h.Active = false
	return true
}

func (p *Pool) FileClaim(claimant string, amount int64, reason string) (string, bool) {
	h, ok := p.holders[claimant]
	if !ok || !h.Active {
		return "", false
	}
	if amount <= 0 || amount > h.Coverage {
		return "", false
	}
	p.nextClaimSeq++
	id := itoa(p.nextClaimSeq)
	p.claims[id] = &Claim{
		ID:       id,
		Claimant: claimant,
		Amount:   amount,
		Reason:   reason,
		Status:   ClaimPending,
		Filed:    p.currentHeight,
	}
	return id, true
}

func (p *Pool) AssessClaim(assessor, claimID string, approve bool) bool {
	if !p.assessors[assessor] && assessor != p.admin {
		return false
	}
	c, ok := p.claims[claimID]
	if !ok || c.Status != ClaimPending {
		return false
	}
	if approve {
		if c.Amount > p.poolBalance {
			return false
		}
		c.Status = ClaimApproved
	} else {
		c.Status = ClaimRejected
	}
	c.Approver = assessor
	return true
}

func (p *Pool) PayClaim(claimID string) bool {
	c, ok := p.claims[claimID]
	if !ok || c.Status != ClaimApproved {
		return false
	}
	if c.Amount > p.poolBalance {
		return false
	}
	p.poolBalance -= c.Amount
	c.Status = ClaimPaid
	return true
}

func (p *Pool) GetHolder(addr string) (*Policyholder, bool) {
	h, ok := p.holders[addr]
	return h, ok
}

func (p *Pool) GetClaim(id string) (*Claim, bool) {
	c, ok := p.claims[id]
	return c, ok
}

func (p *Pool) Balance() int64 {
	return p.poolBalance
}

func itoa(n int64) string {
	if n == 0 {
		return "0"
	}
	neg := n < 0
	if neg {
		n = -n
	}
	var buf [20]byte
	i := len(buf)
	for n > 0 {
		i--
		buf[i] = byte('0' + n%10)
		n /= 10
	}
	s := string(buf[i:])
	if neg {
		s = "-" + s
	}
	return s
}

// package-level singleton + exported entry points for the realm

var pool = NewPool("g16m0r7rm7fv5hx0ekr7gvx8g4fr7eu08nzhk6gt", 100, 5)

func Tick(height int64) {
	pool.Tick(height)
}

func AddAssessor(caller, addr string) bool {
	return pool.AddAssessor(caller, addr)
}

func Join(addr string, premium int64) bool {
	return pool.Join(addr, premium)
}

func TopUp(addr string, amount int64) bool {
	return pool.TopUp(addr, amount)
}

func Leave(addr string) bool {
	return pool.Leave(addr)
}

func FileClaim(claimant string, amount int64, reason string) string {
	id, ok := pool.FileClaim(claimant, amount, reason)
	if !ok {
		return ""
	}
	return id
}

func AssessClaim(assessor, claimID string, approve bool) bool {
	return pool.AssessClaim(assessor, claimID, approve)
}

func PayClaim(claimID string) bool {
	return pool.PayClaim(claimID)
}

func Balance() int64 {
	return pool.Balance()
}

func Render(path string) string {
	if path == "" {
		return "InsurancePool realm — balance: " + itoa(pool.Balance())
	}
	c, ok := pool.GetClaim(path)
	if !ok {
		return "claim not found: " + path
	}
	return c.Reason + " | amount:" + itoa(c.Amount)
}
