package raffle

import (
	"chain"
	"chain/banker"
	"chain/runtime"
	"chain/runtime/unsafe"
	"crypto/sha256"
	"math/overflow"

	"gno.land/p/g16m0r7rm7fv5hx0ekr7gvx8g4fr7eu08nzhk6gt/commitreveal"
	"gno.land/p/nt/avl/v0"
	"gno.land/p/nt/ufmt/v0"
)

type RaffleStatus int

const (
	StatusOpen RaffleStatus = iota
	StatusSettled
	StatusRefunding
)

func (s RaffleStatus) String() string {
	switch s {
	case StatusOpen:
		return "Open"
	case StatusSettled:
		return "Settled"
	case StatusRefunding:
		return "Refunding"
	default:
		return "Unknown"
	}
}

type Raffle struct {
	ID                   int64
	Organizer            address
	TicketPrice          int64
	MaxTickets           int64
	TicketsSold          int64
	CommitHash           [32]byte
	OrganizerFeeBps      int64
	SaleEndHeight        int64
	RevealDeadlineHeight int64
	Status               RaffleStatus
	Winner               address
	Buyers               *avl.Tree
	TicketIndexToBuyer   *avl.Tree
	Refunded             *avl.Tree
}

var (
	raffles      = avl.NewTree()
	nextRaffleID int64
)

func CreateRaffle(cur realm, commitHash [32]byte, ticketPrice int64, maxTickets int64, organizerFeeBps int64, saleDurationBlocks int64, revealWindowBlocks int64) int64 {
	if !cur.Previous().IsUserCall() {
		panic("raffle: only direct user calls can create a raffle")
	}
	if ticketPrice <= 0 {
		panic("raffle: ticketPrice must be positive")
	}
	if maxTickets <= 0 {
		panic("raffle: maxTickets must be positive")
	}
	if organizerFeeBps < 0 || organizerFeeBps > 10000 {
		panic("raffle: organizerFeeBps must be between 0 and 10000")
	}
	if saleDurationBlocks <= 0 {
		panic("raffle: saleDurationBlocks must be positive")
	}
	if revealWindowBlocks <= 0 {
		panic("raffle: revealWindowBlocks must be positive")
	}

	organizer := cur.Previous().Address()
	nowHeight := runtime.ChainHeight()
	saleEnd := nowHeight + saleDurationBlocks

	nextRaffleID++
	id := nextRaffleID

	r := &Raffle{
		ID:                   id,
		Organizer:            organizer,
		TicketPrice:          ticketPrice,
		MaxTickets:           maxTickets,
		CommitHash:           commitHash,
		OrganizerFeeBps:      organizerFeeBps,
		SaleEndHeight:        saleEnd,
		RevealDeadlineHeight: saleEnd + revealWindowBlocks,
		Status:               StatusOpen,
		Buyers:               avl.NewTree(),
		TicketIndexToBuyer:   avl.NewTree(),
		Refunded:             avl.NewTree(),
	}

	raffles.Set(itoa(id), r)
	return id
}

func BuyTicket(cur realm, raffleID int64) {
	if !cur.Previous().IsUserCall() {
		panic("raffle: only direct user calls can buy a ticket")
	}

	r := mustGetRaffle(raffleID)
	buyer := cur.Previous().Address()

	if r.Status != StatusOpen {
		panic("raffle: raffle is not open (status=" + r.Status.String() + ")")
	}
	if runtime.ChainHeight() >= r.SaleEndHeight {
		panic("raffle: ticket sale has ended")
	}
	if r.TicketsSold >= r.MaxTickets {
		panic("raffle: all tickets have been sold")
	}
	if r.Buyers.Get(buyer.String()) != nil {
		panic("raffle: this address has already bought a ticket")
	}

	sent := unsafe.OriginSend()
	amount := sent.AmountOf("ugnot")
	if amount != r.TicketPrice {
		panic("raffle: sent amount must exactly match the ticket price")
	}

	index := r.TicketsSold
	r.Buyers.Set(buyer.String(), index)
	r.TicketIndexToBuyer.Set(itoa(index), buyer.String())
	r.TicketsSold++
}

func RevealAndSettle(cur realm, raffleID int64, salt []byte, data []byte) {
	if !cur.Previous().IsUserCall() {
		panic("raffle: only direct user calls can reveal and settle")
	}

	r := mustGetRaffle(raffleID)
	caller := cur.Previous().Address()

	if caller != r.Organizer {
		panic("raffle: only the organizer can reveal and settle")
	}
	if r.Status != StatusOpen {
		panic("raffle: raffle is not open (status=" + r.Status.String() + ")")
	}
	nowHeight := runtime.ChainHeight()
	if nowHeight < r.SaleEndHeight {
		panic("raffle: ticket sale has not ended yet")
	}
	if nowHeight >= r.RevealDeadlineHeight {
		panic("raffle: reveal deadline has passed")
	}
	if !commitreveal.Verify(r.CommitHash, salt, data) {
		panic("raffle: revealed salt/data does not match the commitment")
	}

	if r.TicketsSold == 0 {
		r.Status = StatusSettled
		return
	}

	winnerIndex := deriveWinnerIndex(data, r.TicketsSold)
	rawWinner := r.TicketIndexToBuyer.Get(itoa(winnerIndex))
	if rawWinner == nil {
		panic("raffle: internal error, winner index has no buyer")
	}
	winnerAddrStr, ok := rawWinner.(string)
	if !ok {
		panic("raffle: internal error, corrupted buyer entry")
	}
	winner := address(winnerAddrStr)

	pot, ok := overflow.Mul64(r.TicketsSold, r.TicketPrice)
	if !ok {
		panic("raffle: internal error, pot calculation overflowed")
	}

	feeProduct, ok := overflow.Mul64(pot, r.OrganizerFeeBps)
	if !ok {
		panic("raffle: internal error, fee calculation overflowed")
	}
	organizerCut := feeProduct / 10000
	winnerPayout := pot - organizerCut

	r.Status = StatusSettled
	r.Winner = winner

	if organizerCut > 0 {
		payout(cur, r.Organizer, organizerCut)
	}
	if winnerPayout > 0 {
		payout(cur, winner, winnerPayout)
	}
}

func ReclaimRefund(cur realm, raffleID int64) {
	if !cur.Previous().IsUserCall() {
		panic("raffle: only direct user calls can reclaim a refund")
	}

	r := mustGetRaffle(raffleID)
	buyer := cur.Previous().Address()

	if r.Status == StatusSettled {
		panic("raffle: raffle already settled, no refunds available")
	}
	if runtime.ChainHeight() < r.RevealDeadlineHeight {
		panic("raffle: reveal deadline has not passed yet")
	}
	if r.Buyers.Get(buyer.String()) == nil {
		panic("raffle: caller did not buy a ticket for this raffle")
	}
	if r.Refunded.Get(buyer.String()) != nil {
		panic("raffle: caller has already reclaimed their refund")
	}

	r.Status = StatusRefunding
	r.Refunded.Set(buyer.String(), true)

	payout(cur, buyer, r.TicketPrice)
}

func deriveWinnerIndex(data []byte, ticketsSold int64) int64 {
	h := sha256.Sum256(data)
	var n uint64
	for i := 0; i < 8; i++ {
		n = n<<8 | uint64(h[i])
	}
	return int64(n % uint64(ticketsSold))
}

func mustGetRaffle(raffleID int64) *Raffle {
	raw := raffles.Get(itoa(raffleID))
	if raw == nil {
		panic("raffle: raffle not found")
	}
	r, ok := raw.(*Raffle)
	if !ok {
		panic("raffle: internal error, corrupted raffle entry")
	}
	return r
}

func payout(cur realm, to address, amount int64) {
	realmAddr := cur.Address()
	b := banker.NewBanker(banker.BankerTypeRealmSend, cur)

	have := b.GetCoins(realmAddr).AmountOf("ugnot")
	if have < amount {
		panic("raffle: internal invariant violation, insufficient realm balance for payout")
	}

	b.SendCoins(realmAddr, to, chain.Coins{chain.NewCoin("ugnot", amount)})
}

func itoa(i int64) string {
	return ufmt.Sprintf("%d", i)
}

func GetRaffleStatus(raffleID int64) string {
	return mustGetRaffle(raffleID).Status.String()
}

func GetRaffleOrganizer(raffleID int64) address {
	return mustGetRaffle(raffleID).Organizer
}

func GetTicketsSold(raffleID int64) int64 {
	return mustGetRaffle(raffleID).TicketsSold
}

func GetRaffleWinner(raffleID int64) address {
	return mustGetRaffle(raffleID).Winner
}

func GetSaleEndHeight(raffleID int64) int64 {
	return mustGetRaffle(raffleID).SaleEndHeight
}

func GetRevealDeadlineHeight(raffleID int64) int64 {
	return mustGetRaffle(raffleID).RevealDeadlineHeight
}

func HasBoughtTicket(raffleID int64, addr address) bool {
	return mustGetRaffle(raffleID).Buyers.Get(addr.String()) != nil
}
