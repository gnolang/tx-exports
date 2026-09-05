package splitpayment

type Payee struct {
	Addr      string
	SharePct  int64 // out of 10000 (basis points) for precision
	Withdrawn int64
}

type Split struct {
	ID           string
	Owner        string
	Payees       []*Payee
	TotalDeposited int64
	Active       bool
}

type Registry struct {
	admin         string
	splits        map[string]*Split
	nextSeq       int64
	currentHeight int64
}

func NewRegistry(admin string) *Registry {
	return &Registry{admin: admin, splits: make(map[string]*Split)}
}

func (r *Registry) Tick(height int64) {
	if height > r.currentHeight {
		r.currentHeight = height
	}
}

func (r *Registry) CreateSplit(owner string, addrs []string, sharesBps []int64) (string, bool) {
	if owner == "" || len(addrs) != len(sharesBps) || len(addrs) == 0 {
		return "", false
	}
	var total int64
	for _, s := range sharesBps {
		if s <= 0 {
			return "", false
		}
		total += s
	}
	if total != 10000 {
		return "", false
	}
	r.nextSeq++
	id := itoa(r.nextSeq)
	payees := make([]*Payee, len(addrs))
	for i, a := range addrs {
		payees[i] = &Payee{Addr: a, SharePct: sharesBps[i]}
	}
	r.splits[id] = &Split{ID: id, Owner: owner, Payees: payees, Active: true}
	return id, true
}

func (r *Registry) Deposit(splitID string, amount int64) bool {
	s, ok := r.splits[splitID]
	if !ok || !s.Active || amount <= 0 {
		return false
	}
	s.TotalDeposited += amount
	return true
}

// owed computes total entitlement minus already withdrawn for a payee.
func (r *Registry) owed(s *Split, p *Payee) int64 {
	entitlement := (s.TotalDeposited * p.SharePct) / 10000
	owed := entitlement - p.Withdrawn
	if owed < 0 {
		return 0
	}
	return owed
}

func (r *Registry) Withdraw(caller, splitID string) int64 {
	s, ok := r.splits[splitID]
	if !ok || !s.Active {
		return 0
	}
	for _, p := range s.Payees {
		if p.Addr == caller {
			amt := r.owed(s, p)
			p.Withdrawn += amt
			return amt
		}
	}
	return 0
}

func (r *Registry) Owed(splitID, addr string) int64 {
	s, ok := r.splits[splitID]
	if !ok {
		return 0
	}
	for _, p := range s.Payees {
		if p.Addr == addr {
			return r.owed(s, p)
		}
	}
	return 0
}

func (r *Registry) DeactivateSplit(caller, splitID string) bool {
	s, ok := r.splits[splitID]
	if !ok || (caller != s.Owner && caller != r.admin) {
		return false
	}
	s.Active = false
	return true
}

func (r *Registry) GetSplit(id string) (*Split, bool) {
	s, ok := r.splits[id]
	return s, ok
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

var registry = NewRegistry("g16m0r7rm7fv5hx0ekr7gvx8g4fr7eu08nzhk6gt")

func Tick(height int64) {
	registry.Tick(height)
}

func CreateSplit(owner string, addrs []string, sharesBps []int64) string {
	id, ok := registry.CreateSplit(owner, addrs, sharesBps)
	if !ok {
		return ""
	}
	return id
}

func Deposit(splitID string, amount int64) bool {
	return registry.Deposit(splitID, amount)
}

func Withdraw(caller, splitID string) int64 {
	return registry.Withdraw(caller, splitID)
}

func Owed(splitID, addr string) int64 {
	return registry.Owed(splitID, addr)
}

func DeactivateSplit(caller, splitID string) bool {
	return registry.DeactivateSplit(caller, splitID)
}

func Render(path string) string {
	if path == "" {
		return "SplitPayment realm — use CreateSplit, Deposit, Withdraw, Owed"
	}
	s, ok := registry.GetSplit(path)
	if !ok {
		return "split not found: " + path
	}
	return "Owner: " + s.Owner + " | Total deposited: " + itoa(s.TotalDeposited) + " | Payees: " + itoa(int64(len(s.Payees)))
}
