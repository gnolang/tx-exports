package whitelist

type Tier int

const (
	TierNone Tier = iota
	TierBasic
	TierVerified
	TierVIP
)

type Member struct {
	Addr        string
	Tier        Tier
	AddedHeight int64
	AddedBy     string
	Notes       string
}

type Registry struct {
	admin      string
	moderators map[string]bool
	members    map[string]*Member
	currentHeight int64
}

func NewRegistry(admin string) *Registry {
	r := &Registry{
		admin:      admin,
		moderators: make(map[string]bool),
		members:    make(map[string]*Member),
	}
	r.moderators[admin] = true
	return r
}

func (r *Registry) Tick(height int64) {
	if height > r.currentHeight {
		r.currentHeight = height
	}
}

func (r *Registry) AddModerator(caller, addr string) bool {
	if caller != r.admin {
		return false
	}
	r.moderators[addr] = true
	return true
}

func (r *Registry) RemoveModerator(caller, addr string) bool {
	if caller != r.admin || addr == r.admin {
		return false
	}
	delete(r.moderators, addr)
	return true
}

func (r *Registry) AddMember(caller, addr string, tier Tier, notes string) bool {
	if !r.moderators[caller] || tier == TierNone {
		return false
	}
	r.members[addr] = &Member{
		Addr:        addr,
		Tier:        tier,
		AddedHeight: r.currentHeight,
		AddedBy:     caller,
		Notes:       notes,
	}
	return true
}

func (r *Registry) UpgradeTier(caller, addr string, newTier Tier) bool {
	if !r.moderators[caller] {
		return false
	}
	m, ok := r.members[addr]
	if !ok || newTier <= m.Tier {
		return false
	}
	m.Tier = newTier
	return true
}

func (r *Registry) RemoveMember(caller, addr string) bool {
	if !r.moderators[caller] {
		return false
	}
	if _, ok := r.members[addr]; !ok {
		return false
	}
	delete(r.members, addr)
	return true
}

func (r *Registry) IsWhitelisted(addr string) bool {
	_, ok := r.members[addr]
	return ok
}

func (r *Registry) HasMinTier(addr string, minTier Tier) bool {
	m, ok := r.members[addr]
	if !ok {
		return false
	}
	return m.Tier >= minTier
}

func (r *Registry) GetMember(addr string) (*Member, bool) {
	m, ok := r.members[addr]
	return m, ok
}

func (r *Registry) MemberCount() int {
	return len(r.members)
}

func tierName(t Tier) string {
	switch t {
	case TierBasic:
		return "basic"
	case TierVerified:
		return "verified"
	case TierVIP:
		return "vip"
	default:
		return "none"
	}
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

func AddModerator(caller, addr string) bool {
	return registry.AddModerator(caller, addr)
}

func RemoveModerator(caller, addr string) bool {
	return registry.RemoveModerator(caller, addr)
}

func AddMember(caller, addr string, tier int, notes string) bool {
	return registry.AddMember(caller, addr, Tier(tier), notes)
}

func UpgradeTier(caller, addr string, newTier int) bool {
	return registry.UpgradeTier(caller, addr, Tier(newTier))
}

func RemoveMember(caller, addr string) bool {
	return registry.RemoveMember(caller, addr)
}

func IsWhitelisted(addr string) bool {
	return registry.IsWhitelisted(addr)
}

func HasMinTier(addr string, minTier int) bool {
	return registry.HasMinTier(addr, Tier(minTier))
}

func MemberCount() int {
	return registry.MemberCount()
}

func Render(path string) string {
	if path == "" {
		return "Whitelist realm — " + itoa(int64(registry.MemberCount())) + " members"
	}
	m, ok := registry.GetMember(path)
	if !ok {
		return "not whitelisted: " + path
	}
	return "Tier: " + tierName(m.Tier) + " | Added by: " + m.AddedBy
}
