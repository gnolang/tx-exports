package treasury

import (
	"chain"
	"chain/runtime/unsafe"
	"strconv"

	"gno.land/p/g1mv0052e7r6s09f5t9xsqf00nj3tqsgt9dg52jr/gvs/poolkey"
	"gno.land/p/nt/markdown/sanitize/v0"
)

// Holds protocol harvest fees. Vaults Transfer WUGNOT here; this realm
// never holds user deposits.

var (
	admin address
	self  address
)

func init() {
	self = unsafe.CurrentRealm().Address()
	admin = unsafe.OriginCaller()
	if admin == address("") {
		admin = self
	}
}

func Admin() address        { return admin }
func VaultAddress() address { return self }
func Want() string          { return poolkey.WugnotKey }
func Balance() int64        { return tokenBalance() }

func TransferAdmin(cur realm, next address) {
	mustAdmin(cur)
	if next == address("") {
		panic("empty admin")
	}
	admin = next
}

func Sweep(cur realm, to address, amount int64) {
	mustAdmin(cur)
	if to == address("") {
		panic("empty dest")
	}
	if amount <= 0 {
		amount = Balance()
	}
	if amount <= 0 {
		panic("nothing to sweep")
	}
	pushToken(cur, to, amount)
	chain.Emit("Sweep", "to", to.String(), "amount", strconv.FormatInt(amount, 10))
}

func mustAdmin(cur realm) {
	if cur.Previous().Address() != admin {
		panic("admin only")
	}
}

func Render(path string) string {
	_ = path
	out := "# Gno Vault Strategy — Treasury\n\n"
	out += "Protocol share of harvest (default 5%). Not user deposits.\n\n"
	out += "- **WUGNOT**: " + strconv.FormatInt(Balance(), 10) + "\n"
	out += "- **Address**: " + sanitize.InlineText(self.String()) + "\n"
	out += "- **Admin**: " + sanitize.InlineText(admin.String()) + "\n"
	return out
}
