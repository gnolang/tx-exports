package zdex

import "chain"

const (
	listPending  = int64(0)
	listApproved = int64(1)
	listRejected = int64(2)
	maxLogoURI   = 128
)

type Listing struct {
	TokenKey  string
	Symbol    string
	Name      string
	Decimals  int64
	LogoURI   string
	Requester address
	Deposit   int64
	Status    int64
}

func isStableSym(s string) bool {
	return s == "USDC" || s == "USDT" || s == "DAI"
}

func tryListing(symbol string) *Listing {
	v := listings.Get(symbol)
	if v == nil {
		return nil
	}
	return v.(*Listing)
}

func requireListed(symbol string) {
	l := tryListing(symbol)
	require(l != nil && l.Status == listApproved, "zdex: not listed")
}

func upsertApprovedListing(symbol, name, tokenKey string, decimals int64, who address) {
	listings.Set(symbol, &Listing{
		TokenKey:  tokenKey,
		Symbol:    symbol,
		Name:      name,
		Decimals:  decimals,
		Requester: who,
		Status:    listApproved,
	})
}

func cleanLogo(s string) string {
	out := ""
	n := 0
	for i := 0; i < len(s) && n < maxLogoURI; i++ {
		c := s[i]
		if c == ';' || c == '\n' || c == '\r' {
			continue
		}
		out += s[i : i+1]
		n++
	}
	return out
}

// RequestListing posts a token for admin review. Caller sends exactly 1 GNOT.
// Approved tokens may CreatePool and appear in the UI catalog. Reject refunds.
func RequestListing(cur realm, tokenKey, symbol, name string, decimals int64, logoURI string) string {
	assertNotPaused()
	require(cur.Previous().IsUserCall(), "zdex: EOA only")
	require(symbol != "" && symbol != "GNOT" && symbol != nativeDenom, "zdex: symbol")
	require(decimals >= 0 && decimals <= 18, "zdex: decimals")
	prev := tryListing(symbol)
	require(prev == nil || prev.Status == listRejected, "zdex: listing exists")
	takeUgnot(cur, minListUgnot)
	caller := cur.Previous().Address()
	if name == "" {
		name = symbol
	}
	listings.Set(symbol, &Listing{
		TokenKey:  tokenKey,
		Symbol:    symbol,
		Name:      name,
		Decimals:  decimals,
		LogoURI:   cleanLogo(logoURI),
		Requester: caller,
		Deposit:   minListUgnot,
		Status:    listPending,
	})
	chain.Emit("RequestListing", "symbol", symbol, "from", caller.String())
	return symbol
}

func ApproveListing(cur realm, symbol string) {
	mustOwner(cur)
	rejectStrayUgnot()
	l := tryListing(symbol)
	require(l != nil && l.Status == listPending, "zdex: not pending")
	dep := l.Deposit
	l.Status = listApproved
	l.Deposit = 0
	if dep > 0 {
		sendUgnot(0, cur, admin, dep)
	}
	chain.Emit("ApproveListing", "symbol", symbol)
}

func RejectListing(cur realm, symbol string) {
	mustOwner(cur)
	rejectStrayUgnot()
	l := tryListing(symbol)
	require(l != nil && l.Status == listPending, "zdex: not pending")
	dep := l.Deposit
	to := l.Requester
	l.Status = listRejected
	l.Deposit = 0
	if dep > 0 {
		sendUgnot(0, cur, to, dep)
	}
	chain.Emit("RejectListing", "symbol", symbol)
}

func ListingOf(symbol string) (status, decimals, deposit int64) {
	l := tryListing(symbol)
	if l == nil {
		return 0, 0, 0
	}
	return l.Status, l.Decimals, l.Deposit
}

func ListingSnapshot(symbol string) string {
	l := tryListing(symbol)
	if l == nil {
		return ""
	}
	return listingLine(l)
}

func ListingList() string {
	out := ""
	listings.Iterate("", "", func(_ string, v any) bool {
		if out != "" {
			out += "\n"
		}
		out += listingLine(v.(*Listing))
		return false
	})
	return out
}

func listingLine(l *Listing) string {
	st := l.Status
	dec := l.Decimals
	dep := l.Deposit
	line := l.Symbol + ";" + l.Name + ";" + l.TokenKey + ";"
	line += itoa(dec) + ";" + itoa(st) + ";" + itoa(dep) + ";" + l.Requester.String()
	return line + ";" + l.LogoURI
}
