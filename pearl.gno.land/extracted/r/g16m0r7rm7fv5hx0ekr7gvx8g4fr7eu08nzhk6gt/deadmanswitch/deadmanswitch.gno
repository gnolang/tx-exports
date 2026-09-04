package deadmanswitch

type SwitchStatus int

const (
	SwitchActive SwitchStatus = iota
	SwitchTriggered
	SwitchClaimed
	SwitchCancelled
)

type Beneficiary struct {
	Addr    string
	SharePct int64 // out of 100
}

type Switch struct {
	ID            string
	Owner         string
	LastCheckin   int64
	TimeoutBlocks int64
	Balance       int64
	Beneficiaries []Beneficiary
	Status        SwitchStatus
	claimed       map[string]bool
}

type Registry struct {
	admin         string
	switches      map[string]*Switch
	nextSeq       int64
	currentHeight int64
}

func NewRegistry(admin string) *Registry {
	return &Registry{admin: admin, switches: make(map[string]*Switch)}
}

func (r *Registry) Tick(height int64) {
	if height > r.currentHeight {
		r.currentHeight = height
	}
}

func (r *Registry) CreateSwitch(owner string, timeoutBlocks int64) (string, bool) {
	if owner == "" || timeoutBlocks <= 0 {
		return "", false
	}
	r.nextSeq++
	id := itoa(r.nextSeq)
	r.switches[id] = &Switch{
		ID:            id,
		Owner:         owner,
		LastCheckin:   r.currentHeight,
		TimeoutBlocks: timeoutBlocks,
		Status:        SwitchActive,
		claimed:       make(map[string]bool),
	}
	return id, true
}

func (r *Registry) SetBeneficiaries(caller, switchID string, addrs []string, pcts []int64) bool {
	s, ok := r.switches[switchID]
	if !ok || s.Status != SwitchActive || caller != s.Owner {
		return false
	}
	if len(addrs) != len(pcts) || len(addrs) == 0 {
		return false
	}
	var total int64
	for _, p := range pcts {
		if p <= 0 {
			return false
		}
		total += p
	}
	if total != 100 {
		return false
	}
	bens := make([]Beneficiary, len(addrs))
	for i, a := range addrs {
		bens[i] = Beneficiary{Addr: a, SharePct: pcts[i]}
	}
	s.Beneficiaries = bens
	return true
}

func (r *Registry) Deposit(switchID string, amount int64) bool {
	s, ok := r.switches[switchID]
	if !ok || s.Status != SwitchActive || amount <= 0 {
		return false
	}
	s.Balance += amount
	return true
}

func (r *Registry) Checkin(caller, switchID string) bool {
	s, ok := r.switches[switchID]
	if !ok || s.Status != SwitchActive || caller != s.Owner {
		return false
	}
	s.LastCheckin = r.currentHeight
	return true
}

func (r *Registry) Trigger(switchID string) bool {
	s, ok := r.switches[switchID]
	if !ok || s.Status != SwitchActive {
		return false
	}
	if r.currentHeight-s.LastCheckin < s.TimeoutBlocks {
		return false
	}
	if len(s.Beneficiaries) == 0 {
		return false
	}
	s.Status = SwitchTriggered
	return true
}

func (r *Registry) ClaimShare(caller, switchID string) int64 {
	s, ok := r.switches[switchID]
	if !ok || s.Status != SwitchTriggered {
		return 0
	}
	if s.claimed[caller] {
		return 0
	}
	var pct int64 = -1
	for _, b := range s.Beneficiaries {
		if b.Addr == caller {
			pct = b.SharePct
			break
		}
	}
	if pct < 0 {
		return 0
	}
	share := (s.Balance * pct) / 100
	s.claimed[caller] = true
	allClaimed := true
	for _, b := range s.Beneficiaries {
		if !s.claimed[b.Addr] {
			allClaimed = false
			break
		}
	}
	if allClaimed {
		s.Status = SwitchClaimed
	}
	return share
}

func (r *Registry) Cancel(caller, switchID string) bool {
	s, ok := r.switches[switchID]
	if !ok || caller != s.Owner || s.Status != SwitchActive {
		return false
	}
	s.Status = SwitchCancelled
	return true
}

func (r *Registry) GetSwitch(id string) (*Switch, bool) {
	s, ok := r.switches[id]
	return s, ok
}

func (r *Registry) BlocksUntilTrigger(switchID string) int64 {
	s, ok := r.switches[switchID]
	if !ok || s.Status != SwitchActive {
		return -1
	}
	elapsed := r.currentHeight - s.LastCheckin
	remaining := s.TimeoutBlocks - elapsed
	if remaining < 0 {
		return 0
	}
	return remaining
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

func CreateSwitch(owner string, timeoutBlocks int64) string {
	id, ok := registry.CreateSwitch(owner, timeoutBlocks)
	if !ok {
		return ""
	}
	return id
}

func SetBeneficiaries(caller, switchID string, addrs []string, pcts []int64) bool {
	return registry.SetBeneficiaries(caller, switchID, addrs, pcts)
}

func Deposit(switchID string, amount int64) bool {
	return registry.Deposit(switchID, amount)
}

func Checkin(caller, switchID string) bool {
	return registry.Checkin(caller, switchID)
}

func Trigger(switchID string) bool {
	return registry.Trigger(switchID)
}

func ClaimShare(caller, switchID string) int64 {
	return registry.ClaimShare(caller, switchID)
}

func Cancel(caller, switchID string) bool {
	return registry.Cancel(caller, switchID)
}

func BlocksUntilTrigger(switchID string) int64 {
	return registry.BlocksUntilTrigger(switchID)
}

func Render(path string) string {
	if path == "" {
		return "DeadManSwitch realm — use CreateSwitch, Checkin, Trigger, ClaimShare"
	}
	s, ok := registry.GetSwitch(path)
	if !ok {
		return "switch not found: " + path
	}
	return "Owner: " + s.Owner + " | Balance: " + itoa(s.Balance) + " | Beneficiaries: " + itoa(int64(len(s.Beneficiaries)))
}
