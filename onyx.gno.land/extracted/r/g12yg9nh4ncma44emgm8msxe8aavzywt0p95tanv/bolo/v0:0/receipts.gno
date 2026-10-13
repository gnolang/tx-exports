package bolo

import "gno.land/p/nt/seqid/v0"

// ReceiptView is one gift, as the receipt page and the campaign page show it (API
// §2.4): a copy, holding nothing of the realm's state.
type ReceiptView struct {
	ID, CampaignID string
	Seq            int64
	Donor          address // empty when Anonymous
	Anonymous      bool
	Amount, Tip    int64
	Message        string // empty when MessageHidden
	MessageHidden  bool   // hidden by moderation; the receipt and amount stay
	At             int64
	RaisedAfter    int64 // the campaign's gross total right after this gift
	DonorRefunded  int64 // what this donor was refunded on this campaign after this gift (INV-12)
}

// GetReceipt returns gift seq of campaign id (API §4): an unknown campaign or
// sequence number is ErrNotFound.
func GetReceipt(id string, seq int64) ReceiptView {
	c := campaignOf(id)
	return receiptView(c, receiptOf(c, seq))
}

// receiptOf returns gift seq of c, or panics with ErrNotFound.
func receiptOf(c *campaign, seq int64) *receipt {
	if seq <= 0 {
		panic(ErrNotFound)
	}
	v := c.receipts.Get(seqid.ID(seq).Binary())
	if v == nil {
		panic(ErrNotFound)
	}
	return v.(*receipt)
}

// ListRecent returns the campaign's last gifts, newest first, at most recentSize
// (API §4): read through the ring of sequence numbers in its hot state.
func ListRecent(id string) []ReceiptView {
	c := campaignOf(id)
	s := c.state
	n := s.donationCount
	if n > recentSize {
		n = recentSize
	}
	views := make([]ReceiptView, 0, n)
	for i := 1; i <= n; i++ {
		seq := s.recent[(s.recentNext-i+recentSize)%recentSize]
		views = append(views, receiptView(c, c.receipts.Get(seqid.ID(seq).Binary()).(*receipt)))
	}
	return views
}

// receiptView builds r's view (API §2.4): the donor blanked when the gift was
// anonymous, the message when moderation hid it, and what this donor was refunded
// since, so a receipt can't vouch for money taken back (INV-12).
func receiptView(c *campaign, r *receipt) ReceiptView {
	v := ReceiptView{
		ID:            receiptID(c.id, seqid.ID(r.seq)),
		CampaignID:    idString(c.id),
		Seq:           int64(r.seq),
		Anonymous:     r.anonymous,
		Amount:        r.amount,
		Tip:           r.tip,
		MessageHidden: r.messageHidden,
		At:            r.at,
		RaisedAfter:   r.raisedAfter,
	}
	if !r.anonymous {
		v.Donor = r.donor
	}
	if !r.messageHidden {
		v.Message = r.message
	}
	if k := contributionOf(c, r.donor); k != nil {
		v.DonorRefunded = k.refunded - r.refundedBefore
	}
	return v
}
