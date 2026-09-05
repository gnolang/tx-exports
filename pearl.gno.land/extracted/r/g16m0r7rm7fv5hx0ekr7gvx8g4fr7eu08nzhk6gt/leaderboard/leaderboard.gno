package leaderboard

type Entry struct {
	Addr        string
	Score       int64
	LastUpdated int64
	SubmitCount int64
}

type Season struct {
	ID        string
	Name      string
	EndHeight int64
	Active    bool
	entries   map[string]*Entry
}

type Board struct {
	admin         string
	seasons       map[string]*Season
	nextSeq       int64
	currentHeight int64
	maxDelta      int64 // max score change allowed per submit, anti-spam/cheat guard
}

func NewBoard(admin string, maxDelta int64) *Board {
	return &Board{admin: admin, seasons: make(map[string]*Season), maxDelta: maxDelta}
}

func (b *Board) Tick(height int64) {
	if height > b.currentHeight {
		b.currentHeight = height
	}
}

func (b *Board) CreateSeason(caller, name string, durationBlocks int64) (string, bool) {
	if caller != b.admin || name == "" || durationBlocks <= 0 {
		return "", false
	}
	b.nextSeq++
	id := itoa(b.nextSeq)
	b.seasons[id] = &Season{
		ID:        id,
		Name:      name,
		EndHeight: b.currentHeight + durationBlocks,
		Active:    true,
		entries:   make(map[string]*Entry),
	}
	return id, true
}

func (b *Board) SubmitScore(seasonID, addr string, delta int64) bool {
	s, ok := b.seasons[seasonID]
	if !ok || !s.Active {
		return false
	}
	if b.currentHeight >= s.EndHeight {
		s.Active = false
		return false
	}
	if delta < 0 || delta > b.maxDelta {
		return false
	}
	e, exists := s.entries[addr]
	if !exists {
		e = &Entry{Addr: addr}
		s.entries[addr] = e
	}
	e.Score += delta
	e.LastUpdated = b.currentHeight
	e.SubmitCount++
	return true
}

func (b *Board) EndSeason(caller, seasonID string) bool {
	s, ok := b.seasons[seasonID]
	if !ok || caller != b.admin {
		return false
	}
	s.Active = false
	return true
}

func (b *Board) GetScore(seasonID, addr string) int64 {
	s, ok := b.seasons[seasonID]
	if !ok {
		return 0
	}
	e, ok := s.entries[addr]
	if !ok {
		return 0
	}
	return e.Score
}

// TopN returns up to n addresses ranked by score, highest first (simple selection sort, fine for bounded n).
func (b *Board) TopN(seasonID string, n int) []string {
	s, ok := b.seasons[seasonID]
	if !ok {
		return nil
	}
	addrs := make([]string, 0, len(s.entries))
	scores := make([]int64, 0, len(s.entries))
	for addr, e := range s.entries {
		addrs = append(addrs, addr)
		scores = append(scores, e.Score)
	}
	for i := 0; i < len(addrs); i++ {
		best := i
		for j := i + 1; j < len(addrs); j++ {
			if scores[j] > scores[best] {
				best = j
			}
		}
		addrs[i], addrs[best] = addrs[best], addrs[i]
		scores[i], scores[best] = scores[best], scores[i]
	}
	if n > len(addrs) {
		n = len(addrs)
	}
	return addrs[:n]
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

var board = NewBoard("g16m0r7rm7fv5hx0ekr7gvx8g4fr7eu08nzhk6gt", 1000)

func Tick(height int64) {
	board.Tick(height)
}

func CreateSeason(caller, name string, durationBlocks int64) string {
	id, ok := board.CreateSeason(caller, name, durationBlocks)
	if !ok {
		return ""
	}
	return id
}

func SubmitScore(seasonID, addr string, delta int64) bool {
	return board.SubmitScore(seasonID, addr, delta)
}

func EndSeason(caller, seasonID string) bool {
	return board.EndSeason(caller, seasonID)
}

func GetScore(seasonID, addr string) int64 {
	return board.GetScore(seasonID, addr)
}

func Render(path string) string {
	if path == "" {
		return "Leaderboard realm — use CreateSeason, SubmitScore, GetScore"
	}
	top := board.TopN(path, 5)
	if len(top) == 0 {
		return "no entries for season: " + path
	}
	out := "Top scores for " + path + ": "
	for i, addr := range top {
		out += itoa(int64(i+1)) + ") " + addr + " "
	}
	return out
}
