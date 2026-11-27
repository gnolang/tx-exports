package treasury

import (
	"chain"
	"chain/banker"
	"chain/runtime"
	"chain/runtime/unsafe"
	"strconv"
)

const (
	basePath           = "gno.land/r/g15x668kjgd79wml9kgy2phrfv3qpn0yqsg9wsy3/shared_budget_spike"
	treasuryPath       = basePath + "/treasury/v1"
	maintenancePath    = basePath + "/maintenance/v1"
	reimbursementsPath = basePath + "/reimbursements/v1"
	denom              = "ugnot"
	openingDeposit     = int64(1000000)
	maxItemID          = 64
)

type lane struct {
	operator address
	limit    int64
	itemCap  int64
	reserved int64
	items    map[int]int64
}

type budget struct {
	maintenance    lane
	reimbursements lane
	closed         bool
}

var budgets = make(map[address]*budget)

// Open funds a single demo budget for the signing sponsor.
func Open(cur realm, maintenanceOperator, reimbursementsOperator address) {
	runtime.AssertOriginCall()
	sponsor := directSponsor(cur)
	if budgets[sponsor] != nil {
		panic("sponsor already opened a budget")
	}
	if maintenanceOperator == "" || reimbursementsOperator == "" || maintenanceOperator == reimbursementsOperator {
		panic("assign two distinct operators")
	}

	coins := unsafe.OriginSend()
	if len(coins) != 1 || coins[0].Denom != denom || coins[0].Amount != openingDeposit {
		panic("attach exactly 1000000ugnot")
	}

	budgets[sponsor] = &budget{
		maintenance: lane{
			operator: maintenanceOperator,
			limit:    800000,
			itemCap:  800000,
			items:    make(map[int]int64),
		},
		reimbursements: lane{
			operator: reimbursementsOperator,
			limit:    500000,
			itemCap:  300000,
			items:    make(map[int]int64),
		},
	}
}

// Reserve is only callable by the pinned policy realms. Each policy realm
// forwards the wallet address obtained from its own immediate caller.
func Reserve(cur realm, sponsor, operator address, itemID int, amount int64) int64 {
	requireTreasury(cur)
	caller := cur.Previous()
	switch caller.PkgPath() {
	case maintenancePath, reimbursementsPath:
	default:
		panic("unregistered policy realm")
	}

	b := mustBudget(sponsor)
	if b.closed {
		panic("budget is closed")
	}
	policy := &b.maintenance
	if caller.PkgPath() == reimbursementsPath {
		policy = &b.reimbursements
	}
	if operator != policy.operator {
		panic("caller is not the lane operator")
	}
	if itemID < 1 || itemID > maxItemID || amount <= 0 || amount > policy.itemCap {
		panic("invalid item ID or amount")
	}
	if policy.items[itemID] != 0 {
		panic("item already reserved")
	}
	if amount > policy.limit-policy.reserved {
		panic("lane cap exceeded")
	}
	if amount > b.available() {
		panic("shared balance exceeded")
	}

	policy.items[itemID] = amount
	policy.reserved += amount
	return b.available()
}

// Close cancels the demo holds and returns the sponsor's deposit.
func Close(cur realm) {
	runtime.AssertOriginCall()
	sponsor := directSponsor(cur)
	if len(unsafe.OriginSend()) != 0 {
		panic("unexpected attached coins")
	}
	b := mustBudget(sponsor)
	if b.closed {
		panic("budget is closed")
	}

	b.closed = true
	b.maintenance.reserved = 0
	b.reimbursements.reserved = 0
	payment := chain.Coins{chain.NewCoin(denom, openingDeposit)}
	banker.NewBanker(banker.BankerTypeRealmSend, cur).SendCoins(cur.Address(), sponsor, payment)
}

func Available(sponsor address) int64 {
	return mustBudget(sponsor).available()
}

func Render(path string) string {
	if path == "" {
		return "# Shared Budget reservation spike\n\nAppend `:g1…` for a sponsor's budget."
	}
	b := budgets[address(path)]
	if b == nil {
		return "# Shared Budget\n\nBudget not found."
	}
	if b.closed {
		return "# Shared Budget\n\nClosed. Deposit refunded."
	}
	return "# Shared Budget\n\n" +
		"- Available: " + strconv.FormatInt(b.available(), 10) + " ugnot\n" +
		"- Maintenance reserved: " + strconv.FormatInt(b.maintenance.reserved, 10) + " ugnot\n" +
		"- Reimbursements reserved: " + strconv.FormatInt(b.reimbursements.reserved, 10) + " ugnot"
}

func (b *budget) available() int64 {
	if b.closed {
		return 0
	}
	return openingDeposit - b.maintenance.reserved - b.reimbursements.reserved
}

func mustBudget(sponsor address) *budget {
	b := budgets[sponsor]
	if b == nil {
		panic("budget not found")
	}
	return b
}

func requireTreasury(cur realm) {
	if !cur.IsCurrent() || cur.PkgPath() != treasuryPath {
		panic("invalid treasury context")
	}
}

func directSponsor(cur realm) address {
	requireTreasury(cur)
	caller := cur.Previous()
	if !caller.IsUserCall() {
		panic("direct sponsor call required")
	}
	return caller.Address()
}
