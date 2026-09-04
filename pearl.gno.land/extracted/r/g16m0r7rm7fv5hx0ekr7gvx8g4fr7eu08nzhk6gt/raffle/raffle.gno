package raffle

type RaffleStatus int

const (
	RaffleOpen RaffleStatus = iota
	RaffleClosed
	RaffleDrawn
	RaffleCancelled
)

type Ticket struct {
	Buyer string
	Count int64
}

type RaffleRound struct {
	ID          string
	Organizer   string
	TicketPrice int64
	EndHeight   int64
	Status      RaffleStatus
	Pool        int64
	Tickets     []Ticket
	TotalTicks  int64
	Winner      string
	Seed        int64
}

type House struct {
	admin         string
	rounds        map[string]*RaffleRound
	nextSeq       int64
	currentHeight int64
}

func NewHouse(admin string) *House {
	return &House{admin: admin, rounds: make(map[string]*RaffleRound)}
}

func (h *House) Tick(height int64) {
	if height > h.currentHeight {
		h.currentHeight = height
	}
}

func (h *House) CreateRound(organizer string, ticketPrice, durationBlocks int64) (string, bool) {
	if ticketPrice <= 0 || durationBlocks <= 0 || organizer == "" {
		return "", false
	}
	h.nextSeq++
	id := itoa(h.nextSeq)
	h.rounds[id] = &RaffleRound{
		ID:          id,
		Organizer:   organizer,
		TicketPrice: ticketPrice,
		EndHeight:   h.currentHeight + durationBlocks,
		Status:      RaffleOpen,
	}
	return id, true
}

func (h *House) BuyTickets(roundID, buyer string, count int64) bool {
	r, ok := h.rounds[roundID]
	if !ok || r.Status != RaffleOpen || count <= 0 {
		return false
	}
	if h.currentHeight >= r.EndHeight {
		r.Status = RaffleClosed
		return false
	}
	cost := r.TicketPrice * count
	r.Pool += cost
	r.TotalTicks += count
	r.Tickets = append(r.Tickets, Ticket{Buyer: buyer, Count: count})
	// mix buyer address chars + height into the seed, cheap non-crypto entropy
	seedMix := r.Seed
	for i := 0; i < len(buyer); i++ {
		seedMix = seedMix*31 + int64(buyer[i])
	}
	r.Seed = seedMix + h.currentHeight + count
	return true
}

func (h *House) Close(roundID string) bool {
	r, ok := h.rounds[roundID]
	if !ok || r.Status != RaffleOpen {
		return false
	}
	if h.currentHeight < r.EndHeight {
		return false
	}
	r.Status = RaffleClosed
	return true
}

func (h *House) Draw(roundID string) (string, bool) {
	r, ok := h.rounds[roundID]
	if !ok || r.Status != RaffleClosed {
		return "", false
	}
	if r.TotalTicks == 0 {
		r.Status = RaffleCancelled
		return "", false
	}
	seed := r.Seed
	if seed < 0 {
		seed = -seed
	}
	target := seed % r.TotalTicks
	var cursor int64
	winner := ""
	for _, t := range r.Tickets {
		cursor += t.Count
		if target < cursor {
			winner = t.Buyer
			break
		}
	}
	r.Winner = winner
	r.Status = RaffleDrawn
	return winner, true
}

func (h *House) ClaimPrize(roundID, caller string) int64 {
	r, ok := h.rounds[roundID]
	if !ok || r.Status != RaffleDrawn || caller != r.Winner {
		return 0
	}
	amount := r.Pool
	r.Pool = 0
	return amount
}

func (h *House) CancelRound(caller, roundID string) bool {
	r, ok := h.rounds[roundID]
	if !ok || (r.Status != RaffleOpen && r.Status != RaffleClosed) {
		return false
	}
	if caller != r.Organizer && caller != h.admin {
		return false
	}
	r.Status = RaffleCancelled
	return true
}

func (h *House) GetRound(id string) (*RaffleRound, bool) {
	r, ok := h.rounds[id]
	return r, ok
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

var house = NewHouse("g16m0r7rm7fv5hx0ekr7gvx8g4fr7eu08nzhk6gt")

func Tick(height int64) {
	house.Tick(height)
}

func CreateRound(organizer string, ticketPrice, durationBlocks int64) string {
	id, ok := house.CreateRound(organizer, ticketPrice, durationBlocks)
	if !ok {
		return ""
	}
	return id
}

func BuyTickets(roundID, buyer string, count int64) bool {
	return house.BuyTickets(roundID, buyer, count)
}

func Close(roundID string) bool {
	return house.Close(roundID)
}

func Draw(roundID string) string {
	winner, ok := house.Draw(roundID)
	if !ok {
		return ""
	}
	return winner
}

func ClaimPrize(roundID, caller string) int64 {
	return house.ClaimPrize(roundID, caller)
}

func CancelRound(caller, roundID string) bool {
	return house.CancelRound(caller, roundID)
}

func Render(path string) string {
	if path == "" {
		return "Raffle realm — use CreateRound, BuyTickets, Close, Draw, ClaimPrize"
	}
	r, ok := house.GetRound(path)
	if !ok {
		return "round not found: " + path
	}
	return "Pool: " + itoa(r.Pool) + " | Tickets: " + itoa(r.TotalTicks) + " | Winner: " + r.Winner
}
