package bolo

import "chain/banker"

// CampaignView is a campaign as clients see it (API §2.4): a copy, holding nothing
// of the realm's state, its derived fields computed at now without writing.
type CampaignView struct {
	ID, Title, Description, Category, ImageCID, ImageAlt string
	ImageHidden                                          bool
	Organizer, Beneficiary                               address
	Mode, Status, CloseReason                            string
	Listed                                               bool
	Notice                                               string

	Goal      int64
	Raised    int64
	Refunded  int64
	Withdrawn int64
	NetRaised int64
	Balance   int64
	Untracked int64

	DonorCount, DonationCount, RefundCount, UpdateCount int

	Deposit          int64
	Bond             int64
	BondSlashed      bool
	BondReleasableAt int64

	CreatedAt, Deadline, ClosedAt, LastDonationAt, LastUpdateAt int64

	ClosableByAnyoneAt int64
	ExitOpensAt        int64
	FinalizableAt      int64

	EverWithdrawn bool
	ExitOpen      bool

	EscrowAddress address
	BondAddress   address
	Params        Params
}

// GetCampaign returns campaign id's view (API §4). An unknown or non-canonical ID is
// ErrNotFound (C9).
func GetCampaign(id string) CampaignView {
	return campaignView(campaignOf(id))
}

// campaignOf returns the campaign id names, or panics with ErrNotFound (C9).
func campaignOf(id string) *campaign {
	c, ok := lookup(id)
	if !ok {
		panic(ErrNotFound)
	}
	return c
}

// lookup returns the campaign id names, if id is canonical and the campaign exists.
func lookup(id string) (*campaign, bool) {
	n, ok := parseID(id)
	if !ok {
		return nil, false
	}
	v := campaigns.Get(n.Binary())
	if v == nil {
		return nil, false
	}
	return v.(*campaign), true
}

// effective returns c's status, close reason and close time at now, counting a
// passed deadline as recorded (API §2.4, §3.1), without writing.
func effective(c *campaign) (status, reason string, closedAt int64) {
	s := c.state
	if s.status == statusOpen && c.deadline != 0 && now() >= c.deadline {
		return statusClosed, reasonDeadline, c.deadline
	}
	return s.status, s.closeReason, s.closedAt
}

// trackedBalance is what the books say the escrow holds (API §2.4): 0 in direct
// mode.
func trackedBalance(c *campaign) int64 {
	if c.mode != modeEscrow {
		return 0
	}
	s := c.state
	return s.raised - s.withdrawn - s.refunded
}

// campaignView builds c's view at now (API §2.4).
func campaignView(c *campaign) CampaignView {
	s, p := c.state, c.params
	status, reason, closedAt := effective(c)
	balance := trackedBalance(c)
	untracked := banker.NewReadonlyBanker().GetCoin(escrowAddr(c.id), "ugnot") - balance
	if untracked < 0 {
		untracked = 0
	}
	v := CampaignView{
		ID:          idString(c.id),
		Title:       c.text.title,
		Description: c.text.description,
		Category:    c.category,
		ImageCID:    c.text.imageCID,
		ImageAlt:    c.text.imageAlt,
		ImageHidden: s.imageHidden,
		Organizer:   c.organizer,
		Beneficiary: c.beneficiary,
		Mode:        c.mode,
		Status:      status,
		CloseReason: reason,
		Listed:      s.listed,
		Notice:      s.notice,

		Goal:      c.goal,
		Raised:    s.raised,
		Refunded:  s.refunded,
		Withdrawn: s.withdrawn,
		NetRaised: s.raised - s.refunded,
		Balance:   balance,
		Untracked: untracked,

		DonorCount:    s.donorCount,
		DonationCount: s.donationCount,
		RefundCount:   s.refundCount,
		UpdateCount:   s.updateCount,

		Deposit:     p.CreationDeposit,
		Bond:        s.bond,
		BondSlashed: s.bondSlashed,

		CreatedAt:      c.createdAt,
		Deadline:       c.deadline,
		ClosedAt:       closedAt,
		LastDonationAt: s.lastDonationAt,
		LastUpdateAt:   s.lastUpdateAt,

		EverWithdrawn: s.everWithdrawn,
		EscrowAddress: escrowAddr(c.id),
		BondAddress:   bondAddr(c.id),
		Params:        p,
	}
	switch status {
	case statusOpen:
		v.ClosableByAnyoneAt = dormantAt(c)
		if c.deadline != 0 {
			v.FinalizableAt = finalizableAt(c, c.deadline, balance)
		}
	case statusClosed:
		v.BondReleasableAt = closedAt + p.BondHold
		v.FinalizableAt = finalizableAt(c, closedAt, balance)
	case statusSettled:
		v.BondReleasableAt = closedAt + p.BondHold
	}
	if c.mode == modeEscrow && status != statusOpen {
		v.ExitOpensAt = closedAt + p.ExitDelay
		v.ExitOpen = s.everWithdrawn && balance > 0 && now() >= v.ExitOpensAt
	}
	return v
}

// dormantAt is when anyone may close c for dormancy: its last activity plus its
// snapshot's dormancy period (API §3.1).
func dormantAt(c *campaign) int64 { return lastActivity(c) + c.params.DormancyPeriod }

// lastActivity is the latest of c's creation, its last gift and its last update:
// dormancy counts from it (API §3.1).
func lastActivity(c *campaign) int64 {
	last := c.createdAt
	if c.state.lastDonationAt > last {
		last = c.state.lastDonationAt
	}
	if c.state.lastUpdateAt > last {
		last = c.state.lastUpdateAt
	}
	return last
}

// finalizableAt is when Finalize first succeeds for c closed at closedAt (API §2.4,
// §3.4): at once in direct mode or with nothing tracked, else once the exit opens.
func finalizableAt(c *campaign, closedAt, balance int64) int64 {
	if c.mode == modeDirect || balance == 0 {
		return closedAt
	}
	return closedAt + c.params.ExitDelay
}
