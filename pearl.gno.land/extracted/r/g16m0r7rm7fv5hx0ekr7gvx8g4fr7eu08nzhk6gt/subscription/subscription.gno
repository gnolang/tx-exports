package subscription

type SubStatus int

const (
	SubActive SubStatus = iota
	SubPastDue
	SubSuspended
	SubCancelled
)

type Plan struct {
	ID           string
	Name         string
	PricePerCycle int64
	CycleBlocks  int64
	Active       bool
}

type Subscription struct {
	ID            string
	Subscriber    string
	PlanID        string
	Status        SubStatus
	NextDueHeight int64
	MissedCycles  int64
	Balance       int64 // prepaid credit
}

type Service struct {
	admin          string
	plans          map[string]*Plan
	subs           map[string]*Subscription
	nextPlanSeq    int64
	nextSubSeq     int64
	currentHeight  int64
	graceCycles    int64 // missed cycles allowed before suspension
	revenue        int64
}

func NewService(admin string, graceCycles int64) *Service {
	return &Service{
		admin:       admin,
		plans:       make(map[string]*Plan),
		subs:        make(map[string]*Subscription),
		graceCycles: graceCycles,
	}
}

func (s *Service) Tick(height int64) {
	if height > s.currentHeight {
		s.currentHeight = height
	}
}

func (s *Service) CreatePlan(caller, name string, pricePerCycle, cycleBlocks int64) (string, bool) {
	if caller != s.admin || pricePerCycle <= 0 || cycleBlocks <= 0 {
		return "", false
	}
	s.nextPlanSeq++
	id := itoa(s.nextPlanSeq)
	s.plans[id] = &Plan{ID: id, Name: name, PricePerCycle: pricePerCycle, CycleBlocks: cycleBlocks, Active: true}
	return id, true
}

func (s *Service) DeactivatePlan(caller, planID string) bool {
	p, ok := s.plans[planID]
	if !ok || caller != s.admin {
		return false
	}
	p.Active = false
	return true
}

func (s *Service) Subscribe(subscriber, planID string, initialDeposit int64) (string, bool) {
	p, ok := s.plans[planID]
	if !ok || !p.Active || initialDeposit < p.PricePerCycle {
		return "", false
	}
	s.nextSubSeq++
	id := itoa(s.nextSubSeq)
	remaining := initialDeposit - p.PricePerCycle
	s.revenue += p.PricePerCycle
	s.subs[id] = &Subscription{
		ID:            id,
		Subscriber:    subscriber,
		PlanID:        planID,
		Status:        SubActive,
		NextDueHeight: s.currentHeight + p.CycleBlocks,
		Balance:       remaining,
	}
	return id, true
}

func (s *Service) TopUp(subID string, amount int64) bool {
	sub, ok := s.subs[subID]
	if !ok || amount <= 0 || sub.Status == SubCancelled {
		return false
	}
	sub.Balance += amount
	return true
}

// ProcessCycle attempts to bill a subscription if its due height has passed.
func (s *Service) ProcessCycle(subID string) bool {
	sub, ok := s.subs[subID]
	if !ok || sub.Status == SubCancelled {
		return false
	}
	p, ok := s.plans[sub.PlanID]
	if !ok {
		return false
	}
	if s.currentHeight < sub.NextDueHeight {
		return false
	}
	if sub.Balance >= p.PricePerCycle {
		sub.Balance -= p.PricePerCycle
		s.revenue += p.PricePerCycle
		sub.NextDueHeight += p.CycleBlocks
		sub.MissedCycles = 0
		if sub.Status == SubPastDue {
			sub.Status = SubActive
		}
		return true
	}
	sub.MissedCycles++
	sub.NextDueHeight += p.CycleBlocks
	if sub.MissedCycles > s.graceCycles {
		sub.Status = SubSuspended
	} else {
		sub.Status = SubPastDue
	}
	return false
}

func (s *Service) Reactivate(subID string, topUp int64) bool {
	sub, ok := s.subs[subID]
	if !ok || sub.Status != SubSuspended {
		return false
	}
	p, ok := s.plans[sub.PlanID]
	if !ok {
		return false
	}
	sub.Balance += topUp
	if sub.Balance < p.PricePerCycle {
		return false
	}
	sub.Balance -= p.PricePerCycle
	s.revenue += p.PricePerCycle
	sub.MissedCycles = 0
	sub.Status = SubActive
	sub.NextDueHeight = s.currentHeight + p.CycleBlocks
	return true
}

func (s *Service) Cancel(caller, subID string) int64 {
	sub, ok := s.subs[subID]
	if !ok || caller != sub.Subscriber || sub.Status == SubCancelled {
		return 0
	}
	refund := sub.Balance
	sub.Balance = 0
	sub.Status = SubCancelled
	return refund
}

func (s *Service) GetSubscription(id string) (*Subscription, bool) {
	sub, ok := s.subs[id]
	return sub, ok
}

func (s *Service) GetPlan(id string) (*Plan, bool) {
	p, ok := s.plans[id]
	return p, ok
}

func (s *Service) Revenue() int64 {
	return s.revenue
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
	str := string(buf[i:])
	if neg {
		str = "-" + str
	}
	return str
}

// package-level singleton + exported entry points for the realm

var service = NewService("g16m0r7rm7fv5hx0ekr7gvx8g4fr7eu08nzhk6gt", 2)

func Tick(height int64) {
	service.Tick(height)
}

func CreatePlan(caller, name string, pricePerCycle, cycleBlocks int64) string {
	id, ok := service.CreatePlan(caller, name, pricePerCycle, cycleBlocks)
	if !ok {
		return ""
	}
	return id
}

func DeactivatePlan(caller, planID string) bool {
	return service.DeactivatePlan(caller, planID)
}

func Subscribe(subscriber, planID string, initialDeposit int64) string {
	id, ok := service.Subscribe(subscriber, planID, initialDeposit)
	if !ok {
		return ""
	}
	return id
}

func TopUp(subID string, amount int64) bool {
	return service.TopUp(subID, amount)
}

func ProcessCycle(subID string) bool {
	return service.ProcessCycle(subID)
}

func Reactivate(subID string, topUp int64) bool {
	return service.Reactivate(subID, topUp)
}

func Cancel(caller, subID string) int64 {
	return service.Cancel(caller, subID)
}

func Revenue() int64 {
	return service.Revenue()
}

func Render(path string) string {
	if path == "" {
		return "Subscription realm — total revenue: " + itoa(service.Revenue())
	}
	sub, ok := service.GetSubscription(path)
	if !ok {
		return "subscription not found: " + path
	}
	return "Subscriber: " + sub.Subscriber + " | Balance: " + itoa(sub.Balance) + " | Missed: " + itoa(sub.MissedCycles)
}
