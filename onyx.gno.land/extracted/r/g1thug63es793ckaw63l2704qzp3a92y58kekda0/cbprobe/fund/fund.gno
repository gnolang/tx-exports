// Package fund is the Charterbook skeleton probe. It checks three things on
// Onyx before the real build: package approval for the imports we plan to use,
// how session keys look from inside a realm, and an escrow sub-account
// (cur.Sub) that receives a GRC20 deposit and pays it out again.
package fund

import (
	"chain"
	"chain/runtime"
	"crypto/sha256"
	"encoding/hex"
	"math/bits"
	"strings"

	"gno.land/p/nt/avl/v0"
	"gno.land/p/nt/grc20/v0"
	"gno.land/p/nt/markdown/sanitize/v0"
	"gno.land/p/nt/ufmt/v0"
	"gno.land/r/nt/grc20reg/v0"

	"gno.land/r/g1thug63es793ckaw63l2704qzp3a92y58kekda0/cbprobe/tusd"
)

const escrowSub = "escrow"

var (
	token    *grc20.Token
	deployer address
	selfPath string
	records  = avl.NewTree() // seq -> string
	seq      int
	escrowIn int64 // internal ledger: deposited and not yet released
)

func init(cur realm) {
	token = grc20reg.MustGet(tusd.TokenKey())
	deployer = cur.Previous().Address()
	selfPath = cur.PkgPath()
}

// WhoAmI records how the caller looks from inside the realm: the origin
// caller, cur.Previous(), and runtime.GetSessionInfo(). Call it once with a
// master key and once with a session key.
func WhoAmI(cur realm) string {
	sessAddr, expires, allow, isSession := runtime.GetSessionInfo()
	line := ufmt.Sprintf("height=%d previous=%s isSession=%t sessionKey=%s expires=%d allowPaths=%s",
		runtime.ChainHeight(), cur.Previous().Address().String(),
		isSession, sessAddr.String(), expires, strings.Join(allow, ","))
	addRecord(line)
	chain.Emit("WhoAmI", "isSession", ufmt.Sprintf("%t", isSession))
	return line
}

// MasterOnly succeeds only when the transaction was signed by a master key.
func MasterOnly(cur realm) string {
	if _, _, _, isSession := runtime.GetSessionInfo(); isSession {
		panic("master key required: session keys are refused")
	}
	addRecord("MasterOnly ok from " + cur.Previous().Address().String())
	return "ok"
}

// SessionOnly succeeds only when the transaction was signed by a session key.
func SessionOnly(cur realm) string {
	sessAddr, _, _, isSession := runtime.GetSessionInfo()
	if !isSession {
		panic("session key required")
	}
	addRecord("SessionOnly ok from session " + sessAddr.String())
	return "ok"
}

// EscrowAddress is the address of the escrow sub-account.
func EscrowAddress() address {
	return chain.DerivePkgSubAddr(selfPath, escrowSub)
}

// Deposit moves amount PUSD from the caller into the escrow sub-account.
// The caller must first Approve this realm for at least amount.
func Deposit(cur realm, amount int64) {
	if amount <= 0 {
		panic("amount must be positive")
	}
	caller := cur.Previous().Address()
	escrow := cur.Sub(escrowSub).Address()
	checkErr(token.RealmTeller(0, cur).TransferFrom(0, cur, caller, escrow, amount))
	escrowIn += amount
	addRecord(ufmt.Sprintf("Deposit %d from %s to escrow %s", amount, caller.String(), escrow.String()))
}

// Release pays amount PUSD out of the escrow sub-account. Deployer only.
func Release(cur realm, to address, amount int64) {
	if cur.Previous().Address() != deployer {
		panic("deployer only")
	}
	if amount <= 0 || amount > escrowIn {
		panic("amount out of range")
	}
	sub := cur.Sub(escrowSub)
	checkErr(token.RealmTeller(0, sub).Transfer(0, sub, to, amount))
	escrowIn -= amount
	addRecord(ufmt.Sprintf("Release %d from escrow to %s", amount, to.String()))
}

// MulDiv returns floor(a*b/c) with a 128-bit intermediate, the arithmetic the
// fund will use for share and NAV calculations.
func MulDiv(a, b, c uint64) uint64 {
	if c == 0 {
		panic("division by zero")
	}
	hi, lo := bits.Mul64(a, b)
	if hi >= c {
		panic("overflow")
	}
	q, _ := bits.Div64(hi, lo, c)
	return q
}

// Hash returns the hex SHA-256 of s.
func Hash(s string) string {
	h := sha256.Sum256([]byte(s))
	return hex.EncodeToString(h[:])
}

func Render(path string) string {
	var b strings.Builder
	b.WriteString("# Charterbook skeleton probe\n\nTest realm on Onyx. Not a fund. No real value.\n\n")
	b.WriteString(ufmt.Sprintf("- Deployer: %s\n- Token: %s\n- Escrow sub-account: %s\n- Escrow balance (token ledger): %d\n- Escrow balance (internal ledger): %d\n\n## Records\n\n",
		deployer.String(), sanitize.InlineText(tusd.TokenKey()), EscrowAddress().String(), token.BalanceOf(EscrowAddress()), escrowIn))
	records.ReverseIterate("", "", func(_ string, v any) bool {
		b.WriteString("- " + sanitize.InlineText(v.(string)) + "\n")
		return false
	})
	return b.String()
}

func addRecord(s string) {
	seq++
	records.Set(ufmt.Sprintf("%06d", seq), s)
}

func checkErr(err error) {
	if err != nil {
		panic(err.Error())
	}
}
