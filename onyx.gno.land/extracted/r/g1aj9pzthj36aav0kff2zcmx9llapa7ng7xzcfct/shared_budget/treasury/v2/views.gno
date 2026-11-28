package treasury

import (
	"chain"
	"chain/banker"
	"chain/runtime"
	"strconv"
	"strings"

	"gno.land/p/g1aj9pzthj36aav0kff2zcmx9llapa7ng7xzcfct/shared_budget/budget/v1"
)

const MaxPageSize = 20

type PolicyView struct {
	Path       string
	Address    address
	PeriodCap  int64
	ItemCap    int64
	Registered bool
	Used       int64
}

type ProgramView struct {
	ID                 int64
	Sponsor            address
	Status             string
	StartHeight        int64
	IssueEndHeight     int64
	PeriodBlocks       int64
	MaxHoldBlocks      int64
	CurrentPeriod      int64
	ActiveReservations int64
	Balance            budget.Ledger
	Maintenance        PolicyView
	Reimbursements     PolicyView
}

type ReservationView struct {
	ID              int64
	Lane            string
	Recipient       address
	Amount          int64
	Status          string
	Period          int64
	Deadline        int64
	ExpiredAtHeight bool
	Paid            bool
}

type ClaimView struct {
	Exists    bool
	Recipient address
	Amount    int64
	Paid      bool
}

func LatestProgramID() int64 {
	return latestProgramID
}

func GetProgram(programID int64) ProgramView {
	p := mustProgram(programID)
	height := runtime.ChainHeight()
	period := int64(0)
	if p.status != Draft {
		period = p.periodAt(height)
	}
	return ProgramView{
		ID:                 programID,
		Sponsor:            p.sponsor,
		Status:             p.statusAt(height),
		StartHeight:        p.start,
		IssueEndHeight:     p.issueEnd,
		PeriodBlocks:       p.periodBlocks,
		MaxHoldBlocks:      p.maxHold,
		CurrentPeriod:      period,
		ActiveReservations: p.activeCount,
		Balance:            p.ledger,
		Maintenance:        p.maintenance.view(period),
		Reimbursements:     p.reimbursements.view(period),
	}
}

func GetPeriodUsage(programID, period int64) (int64, int64) {
	if period < 0 {
		panic("period must be non-negative")
	}
	p := mustProgram(programID)
	return p.maintenance.usage[period], p.reimbursements.usage[period]
}

func GetReservation(programID int64, lane string, itemID int64) ReservationView {
	item := mustProgram(programID).rule(lane).items[itemID]
	if item == nil {
		panic("reservation not found")
	}
	return item.view(lane, itemID, runtime.ChainHeight())
}

func ListReservations(programID int64, lane string, offset, limit int) []ReservationView {
	if offset < 0 || limit < 1 || limit > MaxPageSize {
		panic("offset must be non-negative and limit must be 1 to 20")
	}
	rule := mustProgram(programID).rule(lane)
	remaining := len(rule.itemIDs) - offset
	if remaining <= 0 {
		return []ReservationView{}
	}
	if remaining < limit {
		limit = remaining
	}
	height := runtime.ChainHeight()
	page := make([]ReservationView, limit)
	for i, id := range rule.itemIDs[offset : offset+limit] {
		page[i] = rule.items[id].view(lane, id, height)
	}
	return page
}

func GetClaim(programID int64, lane string, itemID int64) ClaimView {
	c := mustProgram(programID).findClaim(lane, itemID)
	if c == nil {
		return ClaimView{}
	}
	return ClaimView{Exists: true, Recipient: c.recipient, Amount: c.amount, Paid: c.paid}
}

// GetTreasuryBalance returns bank cash and the sum owed to all programs.
func GetTreasuryBalance() (int64, int64) {
	addr := chain.PackageAddress(packagePath)
	return banker.NewReadonlyBanker().GetCoin(addr, budget.Denom), outstanding
}

func (rule *policy) view(period int64) PolicyView {
	return PolicyView{
		Path: rule.path, Address: rule.addr, PeriodCap: rule.periodCap, ItemCap: rule.itemCap,
		Registered: rule.registered, Used: rule.usage[period],
	}
}

func (item *reservation) view(lane string, id, height int64) ReservationView {
	return ReservationView{
		ID: id, Lane: lane, Recipient: item.payment.recipient, Amount: item.payment.amount,
		Status: item.status, Period: item.period, Deadline: item.deadline,
		ExpiredAtHeight: item.status == Reserved && height >= item.deadline,
		Paid:            item.payment.paid,
	}
}

func Render(path string) string {
	if path == "" {
		return "# Shared Budget\n\nLatest program ID: " + number(latestProgramID) +
			"\n\nOpen a program with `:programID` or an item with `:programID/lane/itemID`."
	}
	parts := strings.SplitN(path, "/", 4)
	id, err := strconv.ParseInt(parts[0], 10, 64)
	if err != nil || programs[id] == nil {
		return "# Shared Budget\n\nProgram not found."
	}
	if len(parts) != 1 {
		if len(parts) == 3 {
			if parts[1] == "period" {
				return renderPeriod(id, parts[2])
			}
			if parts[1] == budget.Refund && parts[2] == "0" {
				return renderRefund(id)
			}
			return renderItem(id, parts[1], parts[2])
		}
		return "# Shared Budget\n\nUse a program, item, or period link."
	}

	p := GetProgram(id)
	b := p.Balance
	return "# Shared Budget · Program " + number(id) + "\n\n" +
		"- Status: " + p.Status + "\n" +
		"- Sponsor: " + string(p.Sponsor) + "\n" +
		"- Funded: " + number(b.Funded) + " ugnot\n" +
		"- Available: " + number(b.Available) + " ugnot\n" +
		"- Reserved: " + number(b.Reserved) + " ugnot\n" +
		"- Claimable: " + number(b.Claimable) + " ugnot\n" +
		"- Paid: " + number(b.Paid) + " ugnot\n" +
		"- Active reservations: " + number(p.ActiveReservations) + "\n" +
		"- Opening height: " + number(p.StartHeight) + "\n" +
		"- Issuance end: " + number(p.IssueEndHeight) + "\n" +
		"- Current period: [" + number(p.CurrentPeriod) + "](" + programURL(id) + "/period/" +
		number(p.CurrentPeriod) + ")\n" +
		renderPolicy(id, "Maintenance", budget.Maintenance, p.Maintenance) +
		renderPolicy(id, "Reimbursements", budget.Reimbursements, p.Reimbursements) +
		renderRefundLink(id)
}

func renderPolicy(id int64, name, lane string, p PolicyView) string {
	rule := programs[id].rule(lane)
	n := len(rule.itemIDs)
	start := 0
	if n > 4 {
		start = n - 4
	}
	recent := ""
	for _, itemID := range rule.itemIDs[start:] {
		item := rule.items[itemID]
		recent += "- [Item " + number(itemID) + "](" + programURL(id) + "/" + lane + "/" +
			number(itemID) + ") · " + item.status + " · " + number(item.payment.amount) + " ugnot\n"
	}
	link := strings.TrimPrefix(p.Path, "gno.land") + ":" + number(id)
	return "\n## " + name + "\n\n" +
		"- [Policy and roles](" + link + ")\n" +
		"- Period usage: " + number(p.Used) + " / " + number(p.PeriodCap) + " ugnot\n" +
		"- Item cap: " + number(p.ItemCap) + " ugnot\n" +
		recent
}

func programURL(id int64) string {
	return strings.TrimPrefix(packagePath, "gno.land") + ":" + number(id)
}

func renderRefundLink(id int64) string {
	if !GetClaim(id, budget.Refund, 0).Exists {
		return ""
	}
	return "\n[View sponsor refund](" + programURL(id) + "/refund/0)\n"
}

func renderRefund(id int64) string {
	c := GetClaim(id, budget.Refund, 0)
	if !c.Exists {
		return "# Sponsor refund\n\nNo refund claim."
	}
	return "# Sponsor refund\n\n" +
		"- Recipient: " + string(c.Recipient) + "\n" +
		"- Amount: " + number(c.Amount) + " ugnot\n" +
		"- Paid: " + strconv.FormatBool(c.Paid) + "\n"
}

func renderPeriod(id int64, text string) string {
	period, err := strconv.ParseInt(text, 10, 64)
	if err != nil || period < 0 || period > GetProgram(id).CurrentPeriod {
		return "# Shared Budget\n\nPeriod not found."
	}
	maintenance, reimbursements := GetPeriodUsage(id, period)
	return "# Shared Budget · Period " + number(period) + "\n\n" +
		"- Maintenance used: " + number(maintenance) + " ugnot\n" +
		"- Reimbursements used: " + number(reimbursements) + " ugnot\n"
}

func renderItem(programID int64, lane, itemText string) string {
	if lane != budget.Maintenance && lane != budget.Reimbursements {
		return "# Shared Budget\n\nPolicy lane not found."
	}
	id, err := strconv.ParseInt(itemText, 10, 64)
	if err != nil || programs[programID].rule(lane).items[id] == nil {
		return "# Shared Budget\n\nReservation not found."
	}
	item := GetReservation(programID, lane, id)
	return "# " + lane + " · Item " + number(id) + "\n\n" +
		"- Status: " + item.Status + "\n" +
		"- Recipient: " + string(item.Recipient) + "\n" +
		"- Amount: " + number(item.Amount) + " ugnot\n" +
		"- Period: " + number(item.Period) + "\n" +
		"- Deadline: " + number(item.Deadline) + "\n" +
		"- Eligible for expiry: " + strconv.FormatBool(item.ExpiredAtHeight) + "\n" +
		"- Paid: " + strconv.FormatBool(item.Paid) + "\n"
}
