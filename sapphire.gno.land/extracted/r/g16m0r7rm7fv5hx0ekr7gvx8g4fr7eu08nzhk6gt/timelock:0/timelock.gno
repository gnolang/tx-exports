package timelock

import (
	"chain"
	"chain/banker"
	"chain/runtime"
	"chain/runtime/unsafe"

	"gno.land/p/nt/avl/v0"
	"gno.land/p/nt/ufmt/v0"
)

// Status represents the lifecycle of a timelocked transfer.
type Status int

const (
	StatusPending Status = iota
	StatusExecuted
	StatusCancelled
)

func (s Status) String() string {
	switch s {
	case StatusPending:
		return "pending"
	case StatusExecuted:
		return "executed"
	case StatusCancelled:
		return "cancelled"
	default:
		return "unknown"
	}
}

// LockedTransfer is a ugnot transfer that can only be executed once
// the chain reaches ExecutableAt, giving observers a window to react.
type LockedTransfer struct {
	ID            int64
	Creator       address
	Recipient     address
	Amount        int64
	ExecutableAt  int64
	Status        Status
}

const minDelayBlocks int64 = 10

var (
	transfers *avl.Tree // id (string) -> *LockedTransfer
	nextID    int64
)

func init() {
	transfers = avl.NewTree()
	nextID = 1
}

func assertUserCall(cur realm) address {
	if !cur.Previous().IsUserCall() {
		panic("timelock: must be a direct user call")
	}
	return cur.Previous().Address()
}

func idKey(id int64) string {
	return ufmt.Sprintf("%020d", id)
}

func getTransfer(id int64) *LockedTransfer {
	key := idKey(id)
	if !transfers.Has(key) {
		panic("timelock: transfer not found")
	}
	raw := transfers.Get(key)
	return raw.(*LockedTransfer)
}

// Schedule queues a ugnot transfer, funded now, executable after delayBlocks.
func Schedule(cur realm, recipient address, delayBlocks int64) int64 {
	caller := assertUserCall(cur)
	if delayBlocks < minDelayBlocks {
		panic("timelock: delayBlocks below minimum")
	}
	sent := unsafe.OriginSend()
	amount := sent.AmountOf("ugnot")
	if amount <= 0 {
		panic("timelock: must fund the transfer with ugnot")
	}

	id := nextID
	nextID++

	transfers.Set(idKey(id), &LockedTransfer{
		ID:           id,
		Creator:      caller,
		Recipient:    recipient,
		Amount:       amount,
		ExecutableAt: runtime.ChainHeight() + delayBlocks,
		Status:       StatusPending,
	})
	return id
}

// Execute releases the funds to the recipient once the delay has elapsed.
// Callable by anyone, so execution isn't dependent on the creator being online.
func Execute(cur realm, id int64) {
	assertUserCall(cur)
	t := getTransfer(id)
	if t.Status != StatusPending {
		panic("timelock: transfer is not pending")
	}
	if runtime.ChainHeight() < t.ExecutableAt {
		panic("timelock: delay has not elapsed yet")
	}

	realmAddr := cur.Address()
	bk := banker.NewBanker(banker.BankerTypeRealmSend, cur)
	have := bk.GetCoins(realmAddr).AmountOf("ugnot")
	amount := t.Amount
	if amount > have {
		amount = have
	}
	if amount > 0 {
		bk.SendCoins(realmAddr, t.Recipient, chain.Coins{chain.NewCoin("ugnot", amount)})
	}

	t.Status = StatusExecuted
}

// Cancel lets the creator abort a pending transfer and reclaim funds,
// as long as it hasn't become executable yet.
func Cancel(cur realm, id int64) {
	caller := assertUserCall(cur)
	t := getTransfer(id)
	if t.Status != StatusPending {
		panic("timelock: transfer is not pending")
	}
	if caller != t.Creator {
		panic("timelock: only the creator can cancel")
	}
	if runtime.ChainHeight() >= t.ExecutableAt {
		panic("timelock: cannot cancel after executable window opens")
	}

	realmAddr := cur.Address()
	bk := banker.NewBanker(banker.BankerTypeRealmSend, cur)
	have := bk.GetCoins(realmAddr).AmountOf("ugnot")
	amount := t.Amount
	if amount > have {
		amount = have
	}
	if amount > 0 {
		bk.SendCoins(realmAddr, t.Creator, chain.Coins{chain.NewCoin("ugnot", amount)})
	}

	t.Status = StatusCancelled
}

func Render(path string) string {
	out := "# Timelock\n\n"
	out += ufmt.Sprintf("Total scheduled transfers: %d\n\n", transfers.Size())
	transfers.Iterate("", "", func(key string, value interface{}) bool {
		t := value.(*LockedTransfer)
		out += ufmt.Sprintf("## #%d\n", t.ID)
		out += ufmt.Sprintf("Recipient: %s | Amount: %d ugnot | Executable at: %d | Status: %s\n\n",
			t.Recipient, t.Amount, t.ExecutableAt, t.Status.String())
		return false
	})
	return out
}
