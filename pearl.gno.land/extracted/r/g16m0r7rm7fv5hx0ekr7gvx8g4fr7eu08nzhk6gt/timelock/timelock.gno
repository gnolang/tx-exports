package timelock

type LockStatus int

const (
	LockPending LockStatus = iota
	LockReady
	LockExecuted
	LockCancelled
)

type Action struct {
	ID            string
	Proposer      string
	Target        string // free-form description of the call/target
	Payload       string
	ReadyHeight   int64
	ExpiryHeight  int64
	Status        LockStatus
	Approvals     map[string]bool
	RequiredApprovals int
}

type Timelock struct {
	admin         string
	actions       map[string]*Action
	nextSeq       int64
	currentHeight int64
	delayBlocks   int64
	expiryBlocks  int64
	approvers     map[string]bool
}

func NewTimelock(admin string, delayBlocks, expiryBlocks int64) *Timelock {
	t := &Timelock{
		admin:        admin,
		actions:      make(map[string]*Action),
		delayBlocks:  delayBlocks,
		expiryBlocks: expiryBlocks,
		approvers:    make(map[string]bool),
	}
	t.approvers[admin] = true
	return t
}

func (t *Timelock) Tick(height int64) {
	if height > t.currentHeight {
		t.currentHeight = height
	}
}

func (t *Timelock) AddApprover(caller, addr string) bool {
	if caller != t.admin {
		return false
	}
	t.approvers[addr] = true
	return true
}

func (t *Timelock) Queue(proposer, target, payload string, requiredApprovals int) (string, bool) {
	if !t.approvers[proposer] || target == "" || requiredApprovals < 1 {
		return "", false
	}
	t.nextSeq++
	id := itoa(t.nextSeq)
	t.actions[id] = &Action{
		ID:                id,
		Proposer:          proposer,
		Target:            target,
		Payload:           payload,
		ReadyHeight:       t.currentHeight + t.delayBlocks,
		ExpiryHeight:      t.currentHeight + t.delayBlocks + t.expiryBlocks,
		Status:            LockPending,
		Approvals:         make(map[string]bool),
		RequiredApprovals: requiredApprovals,
	}
	return id, true
}

func (t *Timelock) Approve(caller, actionID string) bool {
	a, ok := t.actions[actionID]
	if !ok || a.Status != LockPending || !t.approvers[caller] {
		return false
	}
	a.Approvals[caller] = true
	return true
}

func (t *Timelock) approvalCount(a *Action) int {
	c := 0
	for range a.Approvals {
		c++
	}
	return c
}

func (t *Timelock) Execute(caller, actionID string) bool {
	a, ok := t.actions[actionID]
	if !ok || a.Status != LockPending {
		return false
	}
	if t.currentHeight < a.ReadyHeight {
		return false
	}
	if t.currentHeight > a.ExpiryHeight {
		a.Status = LockCancelled
		return false
	}
	if t.approvalCount(a) < a.RequiredApprovals {
		return false
	}
	a.Status = LockExecuted
	return true
}

func (t *Timelock) Cancel(caller, actionID string) bool {
	a, ok := t.actions[actionID]
	if !ok || a.Status != LockPending {
		return false
	}
	if caller != a.Proposer && caller != t.admin {
		return false
	}
	a.Status = LockCancelled
	return true
}

func (t *Timelock) GetAction(id string) (*Action, bool) {
	a, ok := t.actions[id]
	return a, ok
}

func (t *Timelock) BlocksUntilReady(actionID string) int64 {
	a, ok := t.actions[actionID]
	if !ok || a.Status != LockPending {
		return -1
	}
	remaining := a.ReadyHeight - t.currentHeight
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

var timelock = NewTimelock("g16m0r7rm7fv5hx0ekr7gvx8g4fr7eu08nzhk6gt", 20, 200)

func Tick(height int64) {
	timelock.Tick(height)
}

func AddApprover(caller, addr string) bool {
	return timelock.AddApprover(caller, addr)
}

func Queue(proposer, target, payload string, requiredApprovals int) string {
	id, ok := timelock.Queue(proposer, target, payload, requiredApprovals)
	if !ok {
		return ""
	}
	return id
}

func Approve(caller, actionID string) bool {
	return timelock.Approve(caller, actionID)
}

func Execute(caller, actionID string) bool {
	return timelock.Execute(caller, actionID)
}

func Cancel(caller, actionID string) bool {
	return timelock.Cancel(caller, actionID)
}

func BlocksUntilReady(actionID string) int64 {
	return timelock.BlocksUntilReady(actionID)
}

func Render(path string) string {
	if path == "" {
		return "Timelock realm — use Queue, Approve, Execute, Cancel"
	}
	a, ok := timelock.GetAction(path)
	if !ok {
		return "action not found: " + path
	}
	return "Target: " + a.Target + " | Proposer: " + a.Proposer
}
