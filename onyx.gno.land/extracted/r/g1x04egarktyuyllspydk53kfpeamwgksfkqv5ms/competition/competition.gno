package competition

import (
	"chain"
	"chain/banker"
	"chain/runtime"
	"chain/runtime/unsafe"
	"encoding/hex"
	"strconv"
	"strings"
	"time"
)

const (
	denom = "ugnot"
	ruleset = "strait-run-v1"
	maxScore = 30200
	attemptCap = 3
	weekSeconds int64 = 7 * 24 * 60 * 60
	firstMonday int64 = 4 * 24 * 60 * 60
	maxCoin int64 = 9223372036854775807
)

var (
	admin address
	verifier address
	treasury address
	paused bool
	firstSeason int64
	nextSnapshot int64
	seasonRules = make(map[int64][10]int64)
	seasons = make(map[int64]*Season)
	duels = make(map[int64]*Duel)
	duelReferences = make(map[string]bool)
	pilotDuels = make(map[address][]int64)
	catalog = make(map[int64]*Cosmetic)
	purchases = make(map[string]*Purchase)
	nextDuelID int64 = 1
	nextCosmeticID int64 = 1
	retainedClaimable int64
)

func init(cur realm) {
	admin = cur.Previous().Address()
}

func Configure(cur realm, signer, retainedRecipient address, start int64) {
	runtime.AssertOriginCall()
	requireAdmin(cur)
	now := time.Now().Unix()
	require(firstSeason == 0 && start >= weekID(now)+1 && start < weekID(now)+53, "publish a future opening week")
	require(signer.IsValid() && signer != admin && retainedRecipient.IsValid(), "invalid verifier or treasury")
	firstSeason, nextSnapshot = start, start
	verifier, treasury = signer, retainedRecipient
}

func SetVerifier(cur realm, signer address) {
	runtime.AssertOriginCall()
	requireAdmin(cur)
	require(signer.IsValid() && signer != admin, "invalid verifier")
	verifier = signer
}

func PauseEntries(cur realm, stop bool) {
	runtime.AssertOriginCall()
	requireAdmin(cur)
	paused = stop
}

func PublishShares(cur realm, id int64, csv string) {
	runtime.AssertOriginCall()
	requireAdmin(cur)
	now := weekID(time.Now().Unix())
	require(firstSeason > 0 && id >= firstSeason && id > now && id < now+53, "only a future season can be configured")
	require(len(csv) <= 50, "invalid share length")
	_, published := seasonRules[id]
	require(!published, "shares already published")
	parts := strings.Split(csv, ",")
	require(len(parts) == 10, "ten shares required")
	var shares [10]int64
	var total int64
	for i, part := range parts {
		value, err := strconv.ParseInt(part, 10, 64)
		require(err == nil && value > 0 && value <= 10000, "invalid share")
		shares[i] = value
		total += value
	}
	require(total == 10000, "shares must sum to 10000")
	seasonRules[id] = shares
}

func ClaimTreasury(cur realm) int64 {
	runtime.AssertOriginCall()
	caller := paidCaller(cur, 0)
	require(caller == treasury, "treasury only")
	amount := retainedClaimable
	retainedClaimable = 0
	pay(cur, caller, amount)
	return amount
}

func requireAdmin(cur realm) {
	require(paidCaller(cur, 0) == admin, "admin only")
}

// The public entry point must assert the origin before calling this helper.
func paidCaller(cur realm, amount int64) address {
	require(cur.IsCurrent(), "invalid realm frame")
	previous := cur.Previous()
	require(previous.IsUserCall(), "direct wallet call required")
	checkPayment(unsafe.OriginSend(), amount)
	return previous.Address()
}

func checkPayment(sent chain.Coins, amount int64) {
	if amount == 0 {
		require(len(sent) == 0, "unexpected payment")
		return
	}
	require(amount > 0 && len(sent) == 1 && sent[0].Denom == denom && sent[0].Amount == amount, "exact ugnot payment required")
}

func pay(cur realm, recipient address, amount int64) {
	if amount > 0 {
		banker.NewBanker(banker.BankerTypeRealmSend, cur).SendCoins(cur.Address(), recipient, chain.Coins{{Denom: denom, Amount: amount}})
	}
}

func require(condition bool, message string) {
	if !condition {
		panic(message)
	}
}

func checkedAdd(a, b int64) int64 {
	require(a >= 0 && b >= 0 && a <= maxCoin-b, "amount overflow")
	return a + b
}

func basisPoints(amount, share int64) int64 {
	return amount/10000*share + amount%10000*share/10000
}

func weekID(timestamp int64) int64 {
	return (timestamp-firstMonday)/weekSeconds
}

func weekStart(id int64) int64 {
	return firstMonday + id*weekSeconds
}

func decimal(value int64) string {
	return strconv.FormatInt(value, 10)
}

func validHex(value string, size int) bool {
	if len(value) != size || strings.ToLower(value) != value {
		return false
	}
	_, err := hex.DecodeString(value)
	return err == nil
}
