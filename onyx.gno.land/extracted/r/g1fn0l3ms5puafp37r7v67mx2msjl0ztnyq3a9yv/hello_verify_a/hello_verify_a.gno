package hello_verify_a

import (
	"chain"
	"chain/banker"
	"chain/runtime"
	"chain/runtime/unsafe"
	"strconv"
	"strings"
	"time"

	"gno.land/r/g1fn0l3ms5puafp37r7v67mx2msjl0ztnyq3a9yv/hello_verify_b"
)

var (
	admin           address
	realmAddr       address
	realmPkgPath    string
	totalAccepted   int64
	lastCrossResult string
	sendLogs        []string
	payoutLogs      []string
	timeLogs        []string
)

func init(cur realm) {
	admin = cur.Previous().Address()
	realmAddr = cur.Address()
	realmPkgPath = cur.PkgPath()
}

// MintTestDenom issues a secondary realm-scoped native coin (/<pkgpath>:dummy)
// to admin so Langkah 0 can genuinely test wrong-denom and multi-coin -send on onyx-1.
func MintTestDenom(cur realm, amount int64) string {
	if !cur.Previous().IsUserCall() {
		panic("must be called directly by EOA")
	}
	if cur.Previous().Address() != admin {
		panic("unauthorized: only deployer admin")
	}
	if amount <= 0 {
		panic("amount must be > 0")
	}
	denom := chain.CoinDenom(cur.PkgPath(), "dummy")
	b := banker.NewBanker(banker.BankerTypeRealmIssue, cur)
	b.IssueCoin(admin, denom, amount)
	return denom
}

// InspectSend logs raw unsafe.OriginSend() without enforcing amount/denom rules.
// Used in Langkah 0 to observe OriginSend behavior with various -send payloads.
func InspectSend(cur realm, label string) string {
	if !cur.Previous().IsUserCall() {
		panic("InspectSend must be called directly by EOA")
	}
	sent := unsafe.OriginSend()
	b := banker.NewReadonlyBanker()
	bal := b.GetCoin(cur.Address(), "ugnot")
	entry := "label=" + label +
		" len=" + strconv.Itoa(len(sent)) +
		" coins=" + sent.String() +
		" realmUgnotBal=" + strconv.FormatInt(bal, 10) +
		" height=" + strconv.FormatInt(runtime.ChainHeight(), 10) +
		" unix=" + strconv.FormatInt(time.Now().Unix(), 10)
	sendLogs = append(sendLogs, entry)
	return entry
}

// DepositExact enforces strict coin validation:
// - direct EOA call (cur.Previous().IsUserCall())
// - single coin only (len == 1)
// - denom == "ugnot"
// - exact amount == expected (> 0)
func DepositExact(cur realm, expected int64) string {
	if !cur.Previous().IsUserCall() {
		panic("must be called directly by EOA")
	}
	if expected <= 0 {
		panic("expected amount must be > 0")
	}
	sent := unsafe.OriginSend()
	if len(sent) != 1 {
		panic("must send exactly one coin, got len=" + strconv.Itoa(len(sent)) + " coins=" + sent.String())
	}
	if sent[0].Denom != "ugnot" {
		panic("invalid denom: only ugnot allowed, got " + sent[0].Denom)
	}
	if sent[0].Amount != expected {
		panic("exact amount mismatch: expected " + strconv.FormatInt(expected, 10) + " got " + strconv.FormatInt(sent[0].Amount, 10))
	}

	totalAccepted += expected
	entry := "accepted=" + strconv.FormatInt(expected, 10) +
		" from=" + cur.Previous().Address().String() +
		" total=" + strconv.FormatInt(totalAccepted, 10) +
		" unix=" + strconv.FormatInt(time.Now().Unix(), 10)
	sendLogs = append(sendLogs, entry)
	return entry
}

// DepositThenPanic intentionally mutates state and panics AFTER receiving -send coins.
// Used in Langkah 0 to verify on testnet that coins are refunded and NOT stuck in the realm.
func DepositThenPanic(cur realm) string {
	if !cur.Previous().IsUserCall() {
		panic("must be called directly by EOA")
	}
	sent := unsafe.OriginSend()
	if len(sent) == 0 {
		panic("send at least 1 coin to test rollback")
	}
	totalAccepted += sent.AmountOf("ugnot")
	sendLogs = append(sendLogs, "should-rollback:"+sent.String())
	panic("intentional panic after receiving coins: " + sent.String())
}

// SendFromRealm sends ugnot from this realm's balance to `to` using BankerTypeRealmSend.
// Restricted to admin (deployer) so random testnet users cannot drain verification funds.
func SendFromRealm(cur realm, to address, amount int64) string {
	if !cur.Previous().IsUserCall() {
		panic("must be called directly by EOA")
	}
	if cur.Previous().Address() != admin {
		panic("unauthorized: only deployer admin")
	}
	if amount <= 0 {
		panic("amount must be > 0")
	}
	b := banker.NewBanker(banker.BankerTypeRealmSend, cur)
	b.SendCoins(cur.Address(), to, chain.NewCoins(chain.NewCoin("ugnot", amount)))
	entry := "sent=" + strconv.FormatInt(amount, 10) + "ugnot" +
		" to=" + to.String() +
		" unix=" + strconv.FormatInt(time.Now().Unix(), 10)
	payoutLogs = append(payoutLogs, entry)
	return entry
}

// CallCrossB invokes hello_verify_b.RecordCaller using cross(cur) to verify
// cross-realm call semantics and PreviousRealm vs OriginCaller.
func CallCrossB(cur realm, tag string) string {
	res := hello_verify_b.RecordCaller(cross(cur), "via_a:"+tag)
	lastCrossResult = res
	return res
}

// RecordTimestamp records block height and time.Now().Unix() for gas/storage and clock verification.
func RecordTimestamp(cur realm, tag string) int64 {
	if !cur.Previous().IsUserCall() {
		panic("must be called directly by EOA")
	}
	nowUnix := time.Now().Unix()
	entry := "tag=" + tag +
		" height=" + strconv.FormatInt(runtime.ChainHeight(), 10) +
		" unix=" + strconv.FormatInt(nowUnix, 10)
	timeLogs = append(timeLogs, entry)
	return nowUnix
}

func TotalAccepted() int64 {
	return totalAccepted
}

func Render(path string) string {
	b := banker.NewReadonlyBanker()
	bal := b.GetCoin(realmAddr, "ugnot")

	if path == "json/state" {
		return `{"realm":"hello_verify_a","addr":"` + realmAddr.String() +
			`","pkgPath":"` + realmPkgPath +
			`","admin":"` + admin.String() +
			`","realmUgnotBal":` + strconv.FormatInt(bal, 10) +
			`,"totalAccepted":` + strconv.FormatInt(totalAccepted, 10) +
			`,"sendLogsCount":` + strconv.Itoa(len(sendLogs)) +
			`,"payoutLogsCount":` + strconv.Itoa(len(payoutLogs)) +
			`,"timeLogsCount":` + strconv.Itoa(len(timeLogs)) +
			`,"lastCrossResult":"` + escapeJSON(lastCrossResult) + `"}`
	}

	var sb strings.Builder
	sb.WriteString("# hello_verify_a (Langkah 0 Scratch)\n\n")
	sb.WriteString("- Realm Address: `" + realmAddr.String() + "`\n")
	sb.WriteString("- Admin: `" + admin.String() + "`\n")
	sb.WriteString("- Realm `ugnot` Balance: `" + strconv.FormatInt(bal, 10) + "`\n")
	sb.WriteString("- Total Accepted: `" + strconv.FormatInt(totalAccepted, 10) + "`\n")
	sb.WriteString("- Last Cross-Realm B Result: `" + lastCrossResult + "`\n\n")

	sb.WriteString("## Send Logs\n")
	for _, l := range sendLogs {
		sb.WriteString("- `" + l + "`\n")
	}
	sb.WriteString("\n## Payout Logs\n")
	for _, l := range payoutLogs {
		sb.WriteString("- `" + l + "`\n")
	}
	sb.WriteString("\n## Timestamp Logs\n")
	for _, l := range timeLogs {
		sb.WriteString("- `" + l + "`\n")
	}
	return sb.String()
}

func escapeJSON(s string) string {
	s = strings.ReplaceAll(s, `\`, `\\`)
	s = strings.ReplaceAll(s, `"`, `\"`)
	return s
}
