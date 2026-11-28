// Package reimbursements gives the finance officer control over expense approvals.
package reimbursements

import (
	"chain"
	"chain/runtime"
	"chain/runtime/unsafe"
	"strconv"

	"gno.land/p/g1aj9pzthj36aav0kff2zcmx9llapa7ng7xzcfct/shared_budget/budget/v1"
	"gno.land/r/g1aj9pzthj36aav0kff2zcmx9llapa7ng7xzcfct/shared_budget/treasury/v2"
)

const packagePath = "gno.land/r/g1aj9pzthj36aav0kff2zcmx9llapa7ng7xzcfct/shared_budget/reimbursements/v2"

type Roles struct {
	Clerk          address
	FinanceOfficer address
}

type expense struct {
	digest   string
	decision string
}

type program struct {
	roles    Roles
	expenses map[int64]*expense
}

type ExpenseView struct {
	Evidence    string
	Decision    string
	Reservation treasury.ReservationView
}

var programs = make(map[int64]*program)

func Configure(cur realm, programID int64, clerk, financeOfficer address) {
	runtime.AssertOriginCall()
	caller := userCaller(cur)
	config := treasury.GetProgram(programID)
	if config.Sponsor != caller {
		panic("only the program sponsor can configure reimbursements")
	}
	if config.Status != treasury.Draft || config.Reimbursements.Path != packagePath || programs[programID] != nil {
		panic("reimbursements configuration requires an unconfigured draft with this policy pinned")
	}
	budget.RequireAddress(clerk)
	budget.RequireAddress(financeOfficer)
	if clerk == financeOfficer {
		panic("expense clerk and finance officer must be distinct")
	}

	programs[programID] = &program{
		roles:    Roles{Clerk: clerk, FinanceOfficer: financeOfficer},
		expenses: make(map[int64]*expense),
	}
	treasury.RegisterPolicy(cross(cur), programID)
	chain.Emit("ReimbursementsConfigured", "program", number(programID), "clerk", string(clerk), "finance", string(financeOfficer))
}

// SubmitExpense fixes the evidence and opens a reservation for holdBlocks.
func SubmitExpense(cur realm, programID, itemID int64, recipient address, amount, holdBlocks int64, proofDigest string) int64 {
	runtime.AssertOriginCall()
	caller := userCaller(cur)
	p := mustProgram(programID)
	if caller != p.roles.Clerk {
		panic("only the expense clerk can submit")
	}
	if recipient == p.roles.FinanceOfficer {
		panic("finance officer cannot be the recipient")
	}
	evidence := budget.EvidenceCommitment(programID, budget.Reimbursements, itemID, proofDigest)
	budget.RequirePositive(holdBlocks)
	deadline := budget.Add(runtime.ChainHeight(), holdBlocks)
	available := treasury.Reserve(cross(cur), programID, itemID, recipient, amount, deadline)
	p.expenses[itemID] = &expense{digest: evidence}
	chain.Emit("ExpenseSubmitted", "program", number(programID), "item", number(itemID), "actor", string(caller), "evidence", evidence)
	return available
}

func Decide(cur realm, programID, itemID int64, evidence string, approve bool) string {
	runtime.AssertOriginCall()
	caller := userCaller(cur)
	p := mustProgram(programID)
	if caller != p.roles.FinanceOfficer {
		panic("only the finance officer can decide")
	}
	item := p.mustExpense(itemID)
	if item.digest != evidence {
		panic("expense evidence does not match")
	}
	if item.decision != "" {
		panic("expense already decided")
	}

	if approve {
		treasury.Approve(cross(cur), programID, itemID)
		item.decision = treasury.Approved
	} else {
		treasury.Reject(cross(cur), programID, itemID)
		item.decision = treasury.Rejected
	}
	chain.Emit("ExpenseDecided", "program", number(programID), "item", number(itemID), "officer", string(caller), "decision", item.decision, "evidence", evidence)
	return item.decision
}

func GetRoles(programID int64) Roles {
	return mustProgram(programID).roles
}

func GetExpense(programID, itemID int64) ExpenseView {
	item := mustProgram(programID).mustExpense(itemID)
	return ExpenseView{
		Evidence:    item.digest,
		Decision:    item.decision,
		Reservation: treasury.GetReservation(programID, budget.Reimbursements, itemID),
	}
}

func Render(path string) string {
	id, itemID := budget.ParsePolicyViewPath(path)
	p := programs[id]
	if p == nil {
		return "# Shared Budget · Reimbursements\n\nOpen a program with `:programID` or an expense with `:programID/itemID`."
	}
	if itemID == 0 {
		return "# Reimbursements · Program " + number(id) + "\n\n" +
			"- Expense clerk: " + string(p.roles.Clerk) + "\n" +
			"- Finance officer: " + string(p.roles.FinanceOfficer) + "\n"
	}
	if p.expenses[itemID] == nil {
		return "# Reimbursements\n\nExpense not found."
	}
	expense := GetExpense(id, itemID)
	return "# Reimbursements · Expense " + number(itemID) + "\n\n" +
		"- Status: " + expense.Reservation.Status + "\n" +
		"- Evidence: `" + expense.Evidence + "`\n"
}

func mustProgram(id int64) *program {
	p := programs[id]
	if p == nil {
		panic("reimbursements is not configured for this program")
	}
	return p
}

func (p *program) mustExpense(itemID int64) *expense {
	item := p.expenses[itemID]
	if item == nil {
		panic("expense not found")
	}
	return item
}

func userCaller(cur realm) address {
	if !cur.IsCurrent() || cur.PkgPath() != packagePath || !cur.Previous().IsUserCall() {
		panic("direct reimbursements call required")
	}
	if len(unsafe.OriginSend()) != 0 {
		panic("unexpected attached coins")
	}
	return cur.Previous().Address()
}

func number(n int64) string {
	return strconv.FormatInt(n, 10)
}
