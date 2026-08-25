package gsfarmv5

// syncBookToCash sets the share book to the WUGNOT this slot actually
// holds after unwind so PreviewRedeem never promises more than cash.
func syncBookToCash(f *slot) {
	have := f.cash
	booked := f.book.TotalAssets()
	if booked > have {
		f.book.TakeLoss(booked - have)
		return
	}
	if have > booked && f.book.TotalShares() > 0 {
		f.book.AddProfit(have - booked)
	}
}
