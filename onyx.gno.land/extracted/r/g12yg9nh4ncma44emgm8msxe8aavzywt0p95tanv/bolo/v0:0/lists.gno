package bolo

import "gno.land/p/nt/avl/v0"

// Lists (API §4). A size is clamped to 1–50 (INV-9). The campaign lists page by
// cursor: each reaches its place in its index by key, in O(log n), never by counting
// entries. The per-campaign lists page by number, by offset in the campaign's own tree.

const maxPageSize = 50

// idKeyLen is the length of a campaign's key, seqid.ID.Binary().
const idKeyLen = 8

// pageSize clamps a requested size to 1–50.
func pageSize(size int) int {
	if size < 1 {
		return 1
	}
	if size > maxPageSize {
		return maxPageSize
	}
	return size
}

// ListCampaigns returns the open, listed campaigns, newest first, from below after (""
// for the newest), and the cursor to pass next, "" at the end; category may be "".
// A campaign past a deadline nobody recorded is left out (Q6). One call reads at most
// four times size entries, so a page can be short while the cursor isn't "".
func ListCampaigns(after string, size int, category string) ([]CampaignView, string) {
	size = pageSize(size)
	index, prefix := &active, ""
	if category != "" {
		index, prefix = &activeByCategory, category+"/"
	}
	return campaignPage(index, prefix, after, size, 4*size, func(c *campaign) bool {
		status, _, _ := effective(c)
		return status == statusOpen
	})
}

// ListByOrganizer returns the campaigns addr organizes, delisted included, newest
// first, from below after, and the cursor to pass next. An address is compared as
// given (C12).
func ListByOrganizer(addr address, after string, size int) ([]CampaignView, string) {
	size = pageSize(size)
	return campaignPage(&byOrganizer, addr.String()+"/", after, size, size, everyCampaign)
}

// ListByBeneficiary returns the campaigns naming addr as beneficiary, delisted included
// — the beneficiary must keep seeing them (INV-4) — newest first, from below after,
// and the cursor to pass next.
func ListByBeneficiary(addr address, after string, size int) ([]CampaignView, string) {
	size = pageSize(size)
	return campaignPage(&byBeneficiary, addr.String()+"/", after, size, size, everyCampaign)
}

// ListByDonor returns the campaigns addr gave to at least once without anonymity,
// newest first, from below after, and the cursor to pass next: a campaign where all of
// addr's gifts were anonymous is in no index under addr.
func ListByDonor(addr address, after string, size int) ([]CampaignView, string) {
	size = pageSize(size)
	return campaignPage(&byDonor, addr.String()+"/", after, size, size, everyCampaign)
}

func everyCampaign(*campaign) bool { return true }

// campaignPage reads index newest first: the keys under prefix — a category's or an
// address's range, which ends at the "/" after it, or the whole index for "" — below
// after's key. It reads at most budget entries, keeps size views of those keep
// accepts, and returns them with the ID of the last entry read when more remain, ""
// when the range is done. A non-canonical after is ErrNotFound (C9).
func campaignPage(index *avl.Tree, prefix, after string, size, budget int, keep func(*campaign) bool) ([]CampaignView, string) {
	start, end := prefix, ""
	if prefix != "" {
		end = prefix[:len(prefix)-1] + "0" // "0" sorts right after "/"
	}
	cursor := ""
	if after != "" {
		id, ok := parseID(after)
		if !ok {
			panic(ErrNotFound)
		}
		cursor = prefix + id.Binary()
		end = cursor
	}
	views := []CampaignView{}
	last, read, more := "", 0, false
	// A reverse traversal includes its end: the cursor's own entry, read last time, is
	// skipped. A key whose ID part isn't a campaign key's eight bytes stops the reading:
	// only a prefix holding "/" — an address or a category crafted to end in a key's
	// first bytes — meets one, and every key in its range is such a key, so walking on
	// would read them all, past the budget, to find nothing.
	index.ReverseIterate(start, end, func(key string, _ any) bool {
		if key == cursor {
			return false
		}
		if len(key) != len(prefix)+idKeyLen {
			return true
		}
		if len(views) == size || read == budget {
			more = true
			return true
		}
		read++
		c := campaigns.Get(key[len(prefix):]).(*campaign)
		last = idString(c.id)
		if keep(c) {
			views = append(views, campaignView(c))
		}
		return false
	})
	if !more {
		return views, ""
	}
	return views, last
}

// pageOffset returns where page starts, newest first, in a tree of n entries paged by
// size, and false past the end. A page counts from 1; below 1 reads as 1.
func pageOffset(page, size, n int) (int, bool) {
	if page < 1 {
		page = 1
	}
	if page-1 > n/size {
		return 0, false
	}
	return (page - 1) * size, true
}

// ListReceipts returns a page of the campaign's gifts, newest first.
func ListReceipts(id string, page, size int) []ReceiptView {
	c := campaignOf(id)
	size = pageSize(size)
	views := []ReceiptView{}
	if offset, ok := pageOffset(page, size, c.receipts.Size()); ok {
		c.receipts.ReverseIterateByOffset(offset, size, func(_ string, v any) bool {
			views = append(views, receiptView(c, v.(*receipt)))
			return false
		})
	}
	return views
}

// WithdrawalView is one payout to the beneficiary (API §2.4): its tracked amount and
// the coins sent outside Bolo it carried, apart.
type WithdrawalView struct {
	Seq, Amount, Untracked, At int64
	To                         address
}

// ListWithdrawals returns a page of the campaign's withdrawals, newest first.
func ListWithdrawals(id string, page, size int) []WithdrawalView {
	c := campaignOf(id)
	size = pageSize(size)
	views := []WithdrawalView{}
	if offset, ok := pageOffset(page, size, c.withdrawals.Size()); ok {
		c.withdrawals.ReverseIterateByOffset(offset, size, func(_ string, v any) bool {
			w := v.(*withdrawal)
			views = append(views, WithdrawalView{Seq: int64(w.seq), Amount: w.amount, Untracked: w.untracked, At: w.at, To: w.to})
			return false
		})
	}
	return views
}

// RefundView is one payout to a donor (API §2.4). Donor is empty when all of that
// donor's gifts to the campaign were anonymous; Kind is "open" or "exit".
type RefundView struct {
	Seq, Amount, At int64
	Donor           address
	Kind            string
}

// ListRefunds returns a page of the campaign's refunds, newest first.
func ListRefunds(id string, page, size int) []RefundView {
	c := campaignOf(id)
	size = pageSize(size)
	views := []RefundView{}
	if offset, ok := pageOffset(page, size, c.refunds.Size()); ok {
		c.refunds.ReverseIterateByOffset(offset, size, func(_ string, v any) bool {
			r := v.(*refund)
			view := RefundView{Seq: int64(r.seq), Amount: r.amount, At: r.at, Kind: r.kind}
			if k := contributionOf(c, r.donor); k != nil && k.public {
				view.Donor = r.donor
			}
			views = append(views, view)
			return false
		})
	}
	return views
}

// UpdateView is one organizer update (API §2.4).
type UpdateView struct {
	Seq, At int64
	Body    string
}

// ListUpdates returns a page of the campaign's updates, newest first.
func ListUpdates(id string, page, size int) []UpdateView {
	c := campaignOf(id)
	size = pageSize(size)
	views := []UpdateView{}
	if offset, ok := pageOffset(page, size, c.updates.Size()); ok {
		c.updates.ReverseIterateByOffset(offset, size, func(_ string, v any) bool {
			u := v.(*update)
			views = append(views, UpdateView{Seq: int64(u.seq), At: u.at, Body: u.body})
			return false
		})
	}
	return views
}
