package zdex

func PlaceBid(cur realm, poolID string, giveU, wantAmt, expireH int64, allOrNone bool) uint64 {
	panic("zdex: orders disabled")
}

func PlaceAsk(cur realm, poolID string, giveT, wantU, expireH int64, allOrNone bool) uint64 {
	panic("zdex: orders disabled")
}

func FillOrder(cur realm, orderID uint64, giveAmt int64) (paid, received int64) {
	panic("zdex: orders disabled")
}

func CancelOrder(cur realm, orderID uint64) {
	panic("zdex: orders disabled")
}

func OrderCount() int {
	return orders.Size()
}
