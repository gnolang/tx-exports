package bankkkk

import (
	"errors"
	"fmt"
)

// order is an unexposed struct for security.
type order struct {
	from      Address
	to        Address
	amount    Coins
	processed bool
}

// String method for order provides a string representation.
func (o *order) String() string {
	return fmt.Sprintf("From: %s, To: %s, Amount: %v, Processed: %t", o.from, o.to, o.amount, o.processed)
}

// Order wraps the internal *order for external use.
type Order struct {
	*order
}

// NewOrder creates a new Order.
func NewOrder(from Address, to Address, amount Coins) Order {
	return Order{
		order: &order{
			from:   from,
			to:     to,
			amount: amount,
		},
	}
}

// Execute processes the order, returns error if already processed or nil.
func (o *Order) Execute() error {
	if o.order == nil {
		return errors.New("order is nil")
	}
	if o.order.processed {
		return errors.New("order already processed")
	}
	o.order.processed = true
	// TODO: Implement the actual execution logic.
	return nil
}

func (o Order) IsZero() bool {
	return o.order == nil
}

func (o Order) From() Address {
	return o.order.from
}

func (o Order) To() Address {
	return o.order.to
}

func (o Order) Amount() Coins {
	return o.order.amount
}

func (o Order) Processed() bool {
	return o.order.processed
}

//----------------------------------------
// Escrow

type EscrowTerms struct {
	PartyA  Address
	PartyB  Address
	AmountA Coins
	AmountB Coins
}

type EscrowContract struct {
	EscrowTerms
	OrderA Order
	OrderB Order
}

func CreateEscrow(terms EscrowTerms) *EscrowContract {
	return &EscrowContract{
		EscrowTerms: terms,
	}
}

func (esc *EscrowContract) SetOrderA(order Order) {
	if !esc.OrderA.IsZero() {
		panic("order-a already set")
	}
	if esc.EscrowTerms.PartyA != order.From() {
		panic("invalid order-a:from mismatch")
	}
	if esc.EscrowTerms.PartyB != order.To() {
		panic("invalid order-a:to mismatch")
	}
	if !esc.EscrowTerms.AmountA.Equal(order.Amount()) {
		panic("invalid order-a amount")
	}
	esc.OrderA = order
}

func (esc *EscrowContract) SetOrderB(order Order) {
	if !esc.OrderB.IsZero() {
		panic("order-b already set")
	}
	if esc.EscrowTerms.PartyB != order.From() {
		panic("invalid order-b:from mismatch")
	}
	if esc.EscrowTerms.PartyA != order.To() {
		panic("invalid order-b:to mismatch")
	}
	if !esc.EscrowTerms.AmountB.Equal(order.Amount()) {
		panic("invalid order-b amount")
	}
	esc.OrderB = order
}

func (esc *EscrowContract) Execute() error {
	if esc.OrderA.IsZero() || esc.OrderB.IsZero() {
		return errors.New("one or both orders not set")
	}
	if err := esc.OrderA.Execute(); err != nil {
		return err
	}
	if err := esc.OrderB.Execute(); err != nil {
		return err
	}
	return nil
}

//----------------------------------------
// Supporting types and methods.

type (
	Address string
	Coins   []Coin
	Coin    struct {
		Denom  string
		Amount int64
	}
)

func (c Coins) Equal(b Coins) bool {
	if len(c) != len(b) {
		return false
	}
	for i, coinA := range c {
		coinB := b[i]
		if coinA.Denom != coinB.Denom || coinA.Amount != coinB.Amount {
			return false
		}
	}
	return true
}
