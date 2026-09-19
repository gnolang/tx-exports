package fee

const Denom int64 = 10000

// ProtocolFee is (price * bps) / Denom without overflowing int64 on price*bps.
func ProtocolFee(price, bps int64) int64 {
	if price < 0 {
		panic("fee: negative price")
	}
	if bps < 0 || bps > Denom {
		panic("fee: bps")
	}
	q := price / Denom
	r := price % Denom
	return q*bps + r*bps/Denom
}

// SellerProceeds is the ugnot the seller receives after the protocol fee.
func SellerProceeds(price, bps int64) int64 {
	return price - ProtocolFee(price, bps)
}
