package deadmanswitch

import (
	"chain"
	"chain/banker"
	"chain/runtime"
	"chain/runtime/unsafe"

	"gno.land/p/nt/avl/v0"
	"gno.land/p/nt/ufmt/v0"
)

// Switch holds funds that release to a beneficiary if the owner fails to
// "check in" within the configured interval.
type Switch struct {
	ID            int64
	Owner         address
	Beneficiary   address
	Balance       int64
	CheckInBlocks int64
	LastCheckIn   int64
	Triggered     bool
}

var (
	switches *avl.Tree // id (string) -> *Switch
	nextID   int64
)

func init() {
	switches = avl.NewTree()
	nextID = 1
}

func assertUserCall(cur realm) address {
	if !cur.Previous().IsUserCall() {
		panic("deadmanswitch: must be a direct user call")
	}
	return cur.Previous().Address()
}

func idKey(id int64) string {
	return ufmt.Sprintf("%020d", id)
}

func getSwitch(id int64) *Switch {
	key := idKey(id)
	if !switches.Has(key) {
		panic("deadmanswitch: switch not found")
	}
	raw := switches.Get(key)
	return raw.(*Switch)
}

// CreateSwitch funds a new dead-man's switch. checkInBlocks is the max
// number of blocks the owner can go without checking in before the
// beneficiary can claim the funds.
func CreateSwitch(cur realm, beneficiary address, checkInBlocks int64) int64 {
	caller := assertUserCall(cur)
	if checkInBlocks <= 0 {
		panic("deadmanswitch: checkInBlocks must be positive")
	}
	sent := unsafe.OriginSend()
	amount := sent.AmountOf("ugnot")
	if amount <= 0 {
		panic("deadmanswitch: must fund the switch with ugnot")
	}

	id := nextID
	nextID++

	switches.Set(idKey(id), &Switch{
		ID:            id,
		Owner:         caller,
		Beneficiary:   beneficiary,
		Balance:       amount,
		CheckInBlocks: checkInBlocks,
		LastCheckIn:   runtime.ChainHeight(),
		Triggered:     false,
	})
	return id
}

// CheckIn resets the timer, proving the owner is still active.
func CheckIn(cur realm, id int64) {
	caller := assertUserCall(cur)
	s := getSwitch(id)
	if caller != s.Owner {
		panic("deadmanswitch: only the owner can check in")
	}
	if s.Triggered {
		panic("deadmanswitch: switch already triggered")
	}
	s.LastCheckIn = runtime.ChainHeight()
}

// TopUp adds more funds to an existing switch.
func TopUp(cur realm, id int64) {
	assertUserCall(cur)
	s := getSwitch(id)
	if s.Triggered {
		panic("deadmanswitch: switch already triggered")
	}
	sent := unsafe.OriginSend()
	amount := sent.AmountOf("ugnot")
	if amount <= 0 {
		panic("deadmanswitch: must send ugnot to top up")
	}
	s.Balance += amount
}

// Claim lets the beneficiary withdraw funds once the check-in window has
// elapsed without a check-in.
func Claim(cur realm, id int64) {
	caller := assertUserCall(cur)
	s := getSwitch(id)
	if caller != s.Beneficiary {
		panic("deadmanswitch: only the beneficiary can claim")
	}
	if s.Triggered {
		panic("deadmanswitch: already claimed")
	}
	elapsed := runtime.ChainHeight() - s.LastCheckIn
	if elapsed < s.CheckInBlocks {
		panic("deadmanswitch: check-in window has not elapsed yet")
	}

	realmAddr := cur.Address()
	bk := banker.NewBanker(banker.BankerTypeRealmSend, cur)
	have := bk.GetCoins(realmAddr).AmountOf("ugnot")
	amount := s.Balance
	if amount > have {
		amount = have
	}
	if amount > 0 {
		bk.SendCoins(realmAddr, s.Beneficiary, chain.Coins{chain.NewCoin("ugnot", amount)})
	}

	s.Balance = 0
	s.Triggered = true
}

// CancelSwitch lets the owner reclaim funds and deactivate the switch
// at any time before it is triggered.
func CancelSwitch(cur realm, id int64) {
	caller := assertUserCall(cur)
	s := getSwitch(id)
	if caller != s.Owner {
		panic("deadmanswitch: only the owner can cancel")
	}
	if s.Triggered {
		panic("deadmanswitch: already triggered")
	}

	realmAddr := cur.Address()
	bk := banker.NewBanker(banker.BankerTypeRealmSend, cur)
	have := bk.GetCoins(realmAddr).AmountOf("ugnot")
	amount := s.Balance
	if amount > have {
		amount = have
	}
	if amount > 0 {
		bk.SendCoins(realmAddr, s.Owner, chain.Coins{chain.NewCoin("ugnot", amount)})
	}

	s.Balance = 0
	s.Triggered = true
}

func Render(path string) string {
	out := "# Dead Man's Switch\n\n"
	out += ufmt.Sprintf("Total switches: %d\n\n", switches.Size())
	switches.Iterate("", "", func(key string, value interface{}) bool {
		s := value.(*Switch)
		out += ufmt.Sprintf("## #%d\n", s.ID)
		out += ufmt.Sprintf("Owner: %s | Beneficiary: %s | Balance: %d ugnot | Triggered: %t\n\n",
			s.Owner, s.Beneficiary, s.Balance, s.Triggered)
		return false
	})
	return out
}
