package slotswitch

import (
	"strconv"
	"strings"
	"time"
)

type TransferLegView struct {
	ClinicID int
	Before   ReservationView
	After    ReservationView
}

type TransferParticipantView struct {
	Role     int
	Account  address
	Approved bool
}

type TransferView struct {
	ID           int
	State        string
	Expiry       int64
	Proposer     address
	Legs         []TransferLegView
	Participants []TransferParticipantView
}

type TransferReceiptView struct {
	ProposalID int
	Height     int64
	Time       int64
	Legs       []TransferLegView
}

func Transfer(id int) TransferView {
	p := transfers[id]
	result := TransferView{ID: id, State: transferState(p, time.Now().Unix())}
	if p == nil {
		return result
	}
	result.Expiry = p.expiry
	result.Proposer = p.before[0].holder
	result.Legs = transferLegs(p)
	for role, account := range transferAccounts(p) {
		if account != "" {
			result.Participants = append(result.Participants, TransferParticipantView{Role: role, Account: account, Approved: p.approved[role]})
		}
	}
	return result
}

func TransferReceipt(id int) TransferReceiptView {
	p := transfers[id]
	if p == nil || p.terminal != "settled" {
		panic("settled transfer required")
	}
	return TransferReceiptView{ProposalID: id, Height: p.height, Time: p.time, Legs: transferLegs(p)}
}

func transferLegs(p *transfer) []TransferLegView {
	result := make([]TransferLegView, 0, len(p.clinics))
	for i, clinicID := range p.clinics {
		c := clinics[clinicID]
		result = append(result, TransferLegView{ClinicID: clinicID,
			Before: view(c, p.slots[i], p.before[i]), After: view(c, p.slots[i], transferredSlot(p, i))})
	}
	return result
}

func renderTransfer(path []string) string {
	if len(path) != 2 && len(path) != 3 {
		return "# Transfer unavailable"
	}
	id, err := strconv.Atoi(path[1])
	if err != nil || id <= 0 || transfers[id] == nil {
		return "# Transfer unavailable"
	}
	transfer := Transfer(id)
	var page strings.Builder
	if len(path) == 3 {
		if path[2] != "receipt" || transfer.State != "settled" {
			return "# Transfer receipt unavailable"
		}
		receipt := TransferReceipt(id)
		page.WriteString("# Transfer confirmed\n\nBlock " + strconv.FormatInt(receipt.Height, 10) + " at " + dateTime(receipt.Time) + ".")
	} else {
		page.WriteString("# Transfer " + strconv.Itoa(id) + "\n\nStatus: " + transfer.State + ".")
	}
	page.WriteString("\n\n| Clinic | Appointment | Original holder | ")
	if transfer.State == "settled" {
		page.WriteString("Confirmed holder")
	} else {
		page.WriteString("Proposed holder")
	}
	page.WriteString(" |\n|---|---|---|---|\n")
	for _, leg := range transfer.Legs {
		page.WriteString("| " + strconv.Itoa(leg.ClinicID) + " | " + dateTime(leg.Before.Start))
		page.WriteString(" | " + appointmentLabel(leg.Before) + " | " + appointmentLabel(leg.After) + " |\n")
	}
	return page.String()
}

func appointmentLabel(reservation ReservationView) string {
	if reservation.Holder == "" {
		return "Unassigned"
	}
	return reservation.Alias
}
