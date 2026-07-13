// Package membership models joinable communities without holding chain state itself.
// Realms persist Member / CommunityConfig values and orchestrate access rules.
package membership

// Status of a member in a community.
type Status int

const (
	StatusNone Status = iota
	StatusPending
	StatusActive
	StatusBanned
)

// Member is a single community participant record.
type Member struct {
	Address   string
	Status    Status
	JoinedAt  int64 // unix seconds; set by realm using time.Now().Unix() if available
	Display   string
	Meta      string // free-form (e.g. JSON-ish notes)
}

// CommunityConfig holds policy for a paid/free community kit.
type CommunityConfig struct {
	Name           string
	Description    string
	// OpenJoin: if true, Join activates immediately; else StatusPending.
	OpenJoin       bool
	// RequireApproval: admin must Approve before active (overrides OpenJoin if true).
	RequireApproval bool
	MaxMembers     int // 0 = unlimited
	ActiveCount    int
}

// CanJoin reports whether a new member may join under config.
func CanJoin(cfg *CommunityConfig, currentActive int) bool {
	if cfg == nil {
		return false
	}
	if cfg.MaxMembers > 0 && currentActive >= cfg.MaxMembers {
		return false
	}
	return true
}

// NewMember constructs a member with initial status from config.
func NewMember(addr, display string, cfg *CommunityConfig, now int64) Member {
	st := StatusActive
	if cfg != nil && (cfg.RequireApproval || !cfg.OpenJoin) {
		st = StatusPending
	}
	return Member{
		Address:  addr,
		Status:   st,
		JoinedAt: now,
		Display:  display,
	}
}

// Activate sets member to active and bumps count if transitioning from non-active.
func Activate(m *Member, cfg *CommunityConfig) {
	if m == nil || cfg == nil {
		return
	}
	if m.Status == StatusActive {
		return
	}
	if m.Status == StatusBanned {
		panic("membership: cannot activate banned member")
	}
	m.Status = StatusActive
	cfg.ActiveCount++
}

// Ban marks member banned and decrements active count if needed.
func Ban(m *Member, cfg *CommunityConfig) {
	if m == nil || cfg == nil {
		return
	}
	if m.Status == StatusActive {
		cfg.ActiveCount--
		if cfg.ActiveCount < 0 {
			cfg.ActiveCount = 0
		}
	}
	m.Status = StatusBanned
}

// Leave removes active status.
func Leave(m *Member, cfg *CommunityConfig) {
	if m == nil || cfg == nil {
		return
	}
	if m.Status == StatusActive {
		cfg.ActiveCount--
		if cfg.ActiveCount < 0 {
			cfg.ActiveCount = 0
		}
	}
	m.Status = StatusNone
}

// StatusString for Render helpers.
func StatusString(s Status) string {
	switch s {
	case StatusPending:
		return "pending"
	case StatusActive:
		return "active"
	case StatusBanned:
		return "banned"
	default:
		return "none"
	}
}
