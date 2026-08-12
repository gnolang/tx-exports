package deadmanswitch

import (
	"chain"
	"chain/banker"
	"chain/runtime"
	"chain/runtime/unsafe"
)

type Status int

const (
	StatusActive Status = iota
	StatusClaimed
)

func (s Status) String() string {
	switch s {
	case StatusActive:
		return "Active"
	case StatusClaimed:
		return "Claimed"
	default:
		return "Unknown"
	}
}

var (
	initialized   bool
	owner         address
	beneficiary   address
	timeoutBlocks int64
	lastHeartbeat int64
	status        Status
)

func Initialize(cur realm, ben address, timeout int64) {
	if !cur.Previous().IsUserCall() {
		panic("deadmanswitch: only direct user calls can initialize")
	}
	if initialized {
		panic("deadmanswitch: already initialized")
	}
	if timeout <= 0 {
		panic("deadmanswitch: timeoutBlocks must be positive")
	}

	caller := cur.Previous().Address()
	if ben == caller {
		panic("deadmanswitch: beneficiary cannot be the owner")
	}
	if ben == "" {
		panic("deadmanswitch: beneficiary cannot be empty")
	}

	owner = caller
	beneficiary = ben
	timeoutBlocks = timeout
	lastHeartbeat = runtime.ChainHeight()
	status = StatusActive
	initialized = true
}

func Deposit(cur realm) {
	requireOwner(cur)

	sent := unsafe.OriginSend()
	amount := sent.AmountOf("ugnot")
	if amount <= 0 {
		panic("deadmanswitch: deposit must include a positive ugnot amount")
	}

	lastHeartbeat = runtime.ChainHeight()
}

func Heartbeat(cur realm) {
	requireOwner(cur)
	lastHeartbeat = runtime.ChainHeight()
}

func WithdrawOwner(cur realm, amount int64) {
	requireOwner(cur)
	if amount <= 0 {
		panic("deadmanswitch: withdraw amount must be positive")
	}

	lastHeartbeat = runtime.ChainHeight()
	payout(cur, owner, amount)
}

func ChangeBeneficiary(cur realm, newBeneficiary address) {
	requireOwner(cur)
	if newBeneficiary == owner {
		panic("deadmanswitch: beneficiary cannot be the owner")
	}
	if newBeneficiary == "" {
		panic("deadmanswitch: beneficiary cannot be empty")
	}

	beneficiary = newBeneficiary
	lastHeartbeat = runtime.ChainHeight()
}

func ClaimAsBeneficiary(cur realm) {
	if !initialized {
		panic("deadmanswitch: not initialized yet")
	}
	if !cur.Previous().IsUserCall() {
		panic("deadmanswitch: only direct user calls can claim")
	}
	if cur.Previous().Address() != beneficiary {
		panic("deadmanswitch: caller is not the beneficiary")
	}
	if status != StatusActive {
		panic("deadmanswitch: vault is not active (status=" + status.String() + ")")
	}
	if runtime.ChainHeight() < lastHeartbeat+timeoutBlocks {
		panic("deadmanswitch: owner has not gone inactive long enough yet")
	}

	realmAddr := cur.Address()
	b := banker.NewBanker(banker.BankerTypeRealmSend, cur)
	balance := b.GetCoins(realmAddr).AmountOf("ugnot")

	status = StatusClaimed

	if balance > 0 {
		b.SendCoins(realmAddr, beneficiary, chain.Coins{chain.NewCoin("ugnot", balance)})
	}
}

func requireOwner(cur realm) {
	if !initialized {
		panic("deadmanswitch: not initialized yet")
	}
	if !cur.Previous().IsUserCall() {
		panic("deadmanswitch: only direct user calls are accepted")
	}
	if cur.Previous().Address() != owner {
		panic("deadmanswitch: caller is not the owner")
	}
	if status != StatusActive {
		panic("deadmanswitch: vault is not active (status=" + status.String() + ")")
	}
}

func payout(cur realm, to address, amount int64) {
	realmAddr := cur.Address()
	b := banker.NewBanker(banker.BankerTypeRealmSend, cur)

	have := b.GetCoins(realmAddr).AmountOf("ugnot")
	if have < amount {
		panic("deadmanswitch: internal invariant violation, insufficient realm balance for payout")
	}

	b.SendCoins(realmAddr, to, chain.Coins{chain.NewCoin("ugnot", amount)})
}

func GetOwner() address {
	return owner
}

func GetBeneficiary() address {
	return beneficiary
}

func GetStatus() string {
	if !initialized {
		return "NotInitialized"
	}
	return status.String()
}

func GetLastHeartbeat() int64 {
	return lastHeartbeat
}

func GetTimeoutBlocks() int64 {
	return timeoutBlocks
}

func GetClaimableAtBlock() int64 {
	return lastHeartbeat + timeoutBlocks
}

func IsInitialized() bool {
	return initialized
}
