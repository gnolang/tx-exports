package streampay

import (
	"chain"
	"chain/banker"
	"chain/runtime"
	"chain/runtime/unsafe"
	"math/overflow"

	"gno.land/p/nt/avl/v0"
	"gno.land/p/nt/ufmt/v0"
)

type StreamStatus int

const (
	StatusActive StreamStatus = iota
	StatusCancelled
	StatusCompleted
)

func (s StreamStatus) String() string {
	switch s {
	case StatusActive:
		return "Active"
	case StatusCancelled:
		return "Cancelled"
	case StatusCompleted:
		return "Completed"
	default:
		return "Unknown"
	}
}

type Stream struct {
	ID              int64
	Sender          address
	Recipient       address
	TotalAmount     int64
	StartBlock      int64
	DurationBlocks  int64
	Withdrawn       int64
	Status          StreamStatus
	CancelledAmount int64
}

var (
	streams      avl.Tree
	nextStreamID int64
)

func CreateStream(cur realm, recipient address, durationBlocks int64) int64 {
	if !cur.Previous().IsUserCall() {
		panic("streampay: only direct user calls can create a stream")
	}
	if durationBlocks <= 0 {
		panic("streampay: durationBlocks must be positive")
	}

	sent := unsafe.OriginSend()
	amount := sent.AmountOf("ugnot")
	if amount <= 0 {
		panic("streampay: stream must be funded with a positive ugnot amount")
	}

	sender := cur.Previous().Address()
	if recipient == sender {
		panic("streampay: sender and recipient cannot be the same address")
	}

	nowHeight := runtime.ChainHeight()

	nextStreamID++
	id := nextStreamID

	s := &Stream{
		ID:             id,
		Sender:         sender,
		Recipient:      recipient,
		TotalAmount:    amount,
		StartBlock:     nowHeight,
		DurationBlocks: durationBlocks,
		Status:         StatusActive,
	}

	streams.Set(itoa(id), s)
	return id
}

func vestedAmount(s *Stream, atBlock int64) int64 {
	if atBlock <= s.StartBlock {
		return 0
	}
	elapsed := atBlock - s.StartBlock
	if elapsed >= s.DurationBlocks {
		return s.TotalAmount
	}

	product, ok := overflow.Mul64(s.TotalAmount, elapsed)
	if !ok {
		panic("streampay: internal error, vesting calculation overflowed")
	}

	return product / s.DurationBlocks
}

func Claimable(streamID int64) int64 {
	s := mustGetStream(streamID)
	if s.Status != StatusActive {
		return 0
	}
	vested := vestedAmount(s, runtime.ChainHeight())
	claimable := vested - s.Withdrawn
	if claimable < 0 {
		return 0
	}
	return claimable
}

func Withdraw(cur realm, streamID int64) {
	if !cur.Previous().IsUserCall() {
		panic("streampay: only direct user calls can withdraw")
	}

	s := mustGetStream(streamID)
	caller := cur.Previous().Address()

	if caller != s.Recipient {
		panic("streampay: only the stream recipient can withdraw")
	}
	if s.Status != StatusActive {
		panic("streampay: stream is not active (status=" + s.Status.String() + ")")
	}

	vested := vestedAmount(s, runtime.ChainHeight())
	amount := vested - s.Withdrawn
	if amount <= 0 {
		panic("streampay: nothing to withdraw yet")
	}

	s.Withdrawn += amount
	if s.Withdrawn >= s.TotalAmount {
		s.Status = StatusCompleted
	}

	payout(cur, s.Recipient, amount)
}

func CancelStream(cur realm, streamID int64) {
	if !cur.Previous().IsUserCall() {
		panic("streampay: only direct user calls can cancel a stream")
	}

	s := mustGetStream(streamID)
	caller := cur.Previous().Address()

	if caller != s.Sender {
		panic("streampay: only the stream sender can cancel")
	}
	if s.Status != StatusActive {
		panic("streampay: stream is not active (status=" + s.Status.String() + ")")
	}

	vested := vestedAmount(s, runtime.ChainHeight())
	owedToRecipient := vested - s.Withdrawn
	if owedToRecipient < 0 {
		owedToRecipient = 0
	}
	refundToSender := s.TotalAmount - vested

	s.Status = StatusCancelled
	s.Withdrawn += owedToRecipient
	s.CancelledAmount = refundToSender

	if owedToRecipient > 0 {
		payout(cur, s.Recipient, owedToRecipient)
	}
	if refundToSender > 0 {
		payout(cur, s.Sender, refundToSender)
	}
}

func mustGetStream(streamID int64) *Stream {
        raw := streams.Get(itoa(streamID))
	if raw == nil {
		panic("streampay: stream not found")
	}
	s, ok := raw.(*Stream)
        if !ok {
		panic("streampay: internal error, corrupted stream entry")
	}
	return s
}

func payout(cur realm, to address, amount int64) {
	realmAddr := cur.Address()
	b := banker.NewBanker(banker.BankerTypeRealmSend, cur)

	have := b.GetCoins(realmAddr).AmountOf("ugnot")
	if have < amount {
		panic("streampay: internal invariant violation, insufficient realm balance for payout")
	}

	b.SendCoins(realmAddr, to, chain.Coins{chain.NewCoin("ugnot", amount)})
}

func itoa(i int64) string {
	return ufmt.Sprintf("%d", i)
}

func GetStreamStatus(streamID int64) string {
	return mustGetStream(streamID).Status.String()
}

func GetStreamSender(streamID int64) address {
	return mustGetStream(streamID).Sender
}

func GetStreamRecipient(streamID int64) address {
	return mustGetStream(streamID).Recipient
}

func GetStreamTotal(streamID int64) int64 {
	return mustGetStream(streamID).TotalAmount
}

func GetStreamWithdrawn(streamID int64) int64 {
	return mustGetStream(streamID).Withdrawn
}

func GetStreamDeadlineBlock(streamID int64) int64 {
	s := mustGetStream(streamID)
	return s.StartBlock + s.DurationBlocks
}
