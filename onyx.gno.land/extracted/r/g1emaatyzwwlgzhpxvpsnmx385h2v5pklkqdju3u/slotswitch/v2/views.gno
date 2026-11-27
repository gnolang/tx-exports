package slotswitch

import (
	"strconv"
	"strings"
	"time"
)

type ReservationView struct {
	ID       int
	Issuer   address
	Holder   address
	Alias    string
	Start    int64
	Revision int
	Active   bool
}

type TeamView struct {
	Account address
	Alias   string
}

type ClinicView struct {
	ID            int
	Issuers       [2]address
	Accepted      bool
	DraftRevision int
	StartsAt      int64
	EndsAt        int64
	Cutoff        int64
	Teams         []TeamView
}

type ReceiptView struct {
	ClinicID   int
	ProposalID int
	Height     int64
	Time       int64
	Before     []ReservationView
	After      []ReservationView
}

type MoveView struct {
	Holder   address
	Gives    ReservationView
	Receives ReservationView
	Approved bool
}

type ProposalView struct {
	ClinicID   int
	ProposalID int
	State      string
	Expiry     int64
	Moves      []MoveView
}

func Clinic(clinicID int) ClinicView {
	c := requireClinic(clinicID)
	result := ClinicView{
		ID: clinicID, Issuers: c.issuers, Accepted: c.accepted, DraftRevision: c.draftRevision,
		StartsAt: c.startsAt, EndsAt: c.endsAt, Cutoff: c.cutoff,
	}
	for _, account := range c.enrolled {
		result.Teams = append(result.Teams, TeamView{Account: account, Alias: c.members[account]})
	}
	return result
}

func view(c *clinic, id int, s slot) ReservationView {
	return ReservationView{
		ID: id, Issuer: s.issuer, Holder: s.holder, Alias: c.members[s.holder], Start: s.start,
		Revision: s.revision, Active: s.active,
	}
}

func Roster(clinicID int) []ReservationView {
	c := requireClinic(clinicID)
	result := make([]ReservationView, 0, len(c.slots))
	for id := 1; id <= len(c.slots); id++ {
		result = append(result, view(c, id, c.slots[id]))
	}
	return result
}

func Accepted(clinicID int) bool {
	return requireClinic(clinicID).accepted
}

func ProposalState(clinicID, proposalID int) string {
	c := requireClinic(clinicID)
	return planState(c, c.plans[proposalID], time.Now().Unix())
}

func Proposal(clinicID, proposalID int) ProposalView {
	c := requireClinic(clinicID)
	p := c.plans[proposalID]
	result := ProposalView{
		ClinicID: clinicID, ProposalID: proposalID, State: planState(c, p, time.Now().Unix()),
	}
	if p == nil {
		return result
	}
	result.Expiry = p.expiry
	for source := 0; source < p.size; source++ {
		destination := (source + 1) % p.size
		result.Moves = append(result.Moves, MoveView{
			Holder:   p.old[source].holder,
			Gives:    view(c, p.slots[source], p.old[source]),
			Receives: view(c, p.slots[destination], rotatedSlot(p, destination)),
			Approved: p.approved[source],
		})
	}
	return result
}

func Receipt(clinicID, proposalID int) ReceiptView {
	c := requireClinic(clinicID)
	p := c.plans[proposalID]
	if p == nil || !p.settled {
		panic("settled proposal required")
	}
	receipt := ReceiptView{ClinicID: clinicID, ProposalID: proposalID, Height: p.height, Time: p.confirmedAt}
	for i := 0; i < p.size; i++ {
		receipt.Before = append(receipt.Before, view(c, p.slots[i], p.old[i]))
		receipt.After = append(receipt.After, view(c, p.slots[i], rotatedSlot(p, i)))
	}
	return receipt
}

func Render(path string) string {
	if path == "" {
		return "# SlotSwitch v2\n\nOpen a clinic by its numeric ID or a cross-clinic exchange at `transfer/ID`."
	}
	segments := strings.Split(path, "/")
	if segments[0] == "transfer" {
		return renderTransfer(segments)
	}
	id, err := strconv.Atoi(segments[0])
	if err != nil || clinics[id] == nil {
		return "# Clinic unavailable"
	}
	if len(segments) == 3 && segments[1] == "proposal" {
		proposalID, err := strconv.Atoi(segments[2])
		if err != nil || proposalID <= 0 {
			return "# Proposal unavailable"
		}
		return renderProposal(Proposal(id, proposalID))
	}
	if len(segments) == 3 && segments[1] == "receipt" {
		proposalID, err := strconv.Atoi(segments[2])
		if err != nil || ProposalState(id, proposalID) != "settled" {
			return "# Receipt unavailable"
		}
		return renderReceipt(Receipt(id, proposalID))
	}
	if len(segments) != 1 {
		return "# Clinic page unavailable"
	}
	if !Accepted(id) {
		draft := Clinic(id)
		var page strings.Builder
		page.WriteString("# Clinic awaiting acceptance\n\n")
		page.WriteString("Draft revision " + strconv.Itoa(draft.DraftRevision))
		page.WriteString("\n\nClinic starts " + dateTime(draft.StartsAt))
		page.WriteString(" and ends " + dateTime(draft.EndsAt) + ".")
		page.WriteString("\n\nExchange cutoff " + dateTime(draft.Cutoff) + ".")
		page.WriteString("\n\nThe second desk must accept before either desk can issue bookings.\n")
		for _, team := range draft.Teams {
			page.WriteString("\n- " + team.Alias + " (" + team.Account.String() + ")")
		}
		return page.String()
	}
	var page strings.Builder
	page.WriteString("# Clinic ")
	page.WriteString(strconv.Itoa(id))
	page.WriteString("\n\n| Appointment | Issuer | Current holder | Status |\n|---|---|---|---|\n")
	for _, reservation := range Roster(id) {
		status := "Confirmed"
		if !reservation.Active {
			status = "Canceled"
		}
		page.WriteString("| ")
		page.WriteString(dateTime(reservation.Start))
		page.WriteString(" | ")
		page.WriteString(reservation.Issuer.String())
		page.WriteString(" | ")
		page.WriteString(reservation.Alias + " (" + reservation.Holder.String() + ")")
		page.WriteString(" | ")
		page.WriteString(status)
		page.WriteString(" |\n")
	}
	return page.String()
}

func renderProposal(proposal ProposalView) string {
	var page strings.Builder
	page.WriteString("# Proposal ")
	page.WriteString(strconv.Itoa(proposal.ProposalID))
	page.WriteString("\n\nStatus: ")
	page.WriteString(proposal.State)
	page.WriteString("\n")
	if len(proposal.Moves) == 0 {
		return page.String()
	}
	page.WriteString("\nApproval cutoff: ")
	page.WriteString(dateTime(proposal.Expiry))
	page.WriteString("\n\n| Participant | Gives appointment | Receives appointment | Approval |\n|---|---|---|---|\n")
	for _, move := range proposal.Moves {
		approval := "Pending"
		if move.Approved {
			approval = "Approved"
		}
		page.WriteString("| " + move.Holder.String())
		page.WriteString(" | #" + strconv.Itoa(move.Gives.ID))
		page.WriteString(" | #" + strconv.Itoa(move.Receives.ID))
		page.WriteString(" | " + approval + " |\n")
	}
	return page.String()
}

func renderReceipt(receipt ReceiptView) string {
	var page strings.Builder
	page.WriteString("# Exchange confirmed\n\nBlock " + strconv.FormatInt(receipt.Height, 10))
	page.WriteString(" at " + dateTime(receipt.Time) + ".")
	page.WriteString("\n\n| Appointment | Previous holder | Confirmed holder |\n|---|---|---|\n")
	for index, before := range receipt.Before {
		after := receipt.After[index]
		page.WriteString("| " + dateTime(before.Start) + " | " + before.Alias + " | " + after.Alias + " |\n")
	}
	return page.String()
}

func dateTime(epochSeconds int64) string {
	return time.Unix(epochSeconds, 0).UTC().Format("02 Jan 15:04:05 UTC")
}
