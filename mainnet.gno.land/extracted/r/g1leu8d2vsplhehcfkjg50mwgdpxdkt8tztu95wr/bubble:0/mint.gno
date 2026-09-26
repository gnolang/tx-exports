package bubble

import (
	"strconv"
	"strings"
	"time"

	"chain"
)

// The supply, in three pools that add up to the maximum and never mix.
const (
	MaxSupply    = 100_000_000 * one
	premine      = 10_000_000 * one // Jae's, at init
	ReferralPool = 40_000_000 * one // the minter's, for referrals, under the day cap
	Reserve      = 50_000_000 * one // the holders', by govern:reserve only

	MaxBatch = 100          // entries in one MintMany
	MaxEntry = 50_000 * one // per address per batch: room for a big inviter's day, never a whole day's cap
)

// premineTo is the address the premine goes to (Jae, jarvis room 99/102/105, 2026-09-25).
const premineTo = address("g1ecsuj0q572jr0dhu29q9njtnmw03hyu7tyyvv6")

var (
	premined       int64 // what init minted (the premine)
	referralMinted int64 // out of ReferralPool
	reserveMinted  int64 // out of Reserve
	mintedDay      int64 // minted by the minter on dayKey's day
	dayKey         int64 // unix day of mintedDay
	lastBatch      string
	batches        int64
)

func Premined() int64       { return premined }
func ReferralMinted() int64 { return referralMinted }
func ReserveMinted() int64  { return reserveMinted }
func Batches() int64        { return batches }
func LastBatch() string     { return lastBatch }

// MintedToday is what the minter has minted on the current UTC day, and the day's cap.
func MintedToday() (minted, ceiling int64) {
	if dayOf() != dayKey {
		return 0, dayCap
	}
	return mintedDay, dayCap
}

func dayOf() int64 { return time.Now().Unix() / 86400 }

func mustBeMinter(cur realm) {
	who := caller(cur)
	if minter == "" {
		panic("bubble: nobody may mint; the holders can name a minter")
	}
	if who != minter && (admin == "" || who != admin) {
		panic("bubble: only the minter")
	}
	if paused {
		panic("bubble: minting is paused")
	}
}

// referralMint is one credit out of the referral pool, under every wall. amount is base units.
func referralMint(to address, amount int64) {
	if !to.IsValid() {
		panic("bubble: not an address: " + to.String())
	}
	if amount <= 0 || amount > MaxEntry {
		panic("bubble: an entry is between 1 and " + whole(MaxEntry) + " BUBBLE")
	}
	if referralMinted+amount > ReferralPool {
		panic("bubble: the referral pool is spent; what is left is the holders' reserve")
	}
	if d := dayOf(); d != dayKey {
		dayKey, mintedDay = d, 0
	}
	if mintedDay+amount > dayCap {
		panic("bubble: over today's cap of " + whole(dayCap) + " BUBBLE")
	}
	mintedDay += amount
	referralMinted += amount
	ledger.Mint(to, amount)
}

// Mint credits one address. The minter's hand tool; the box mints through MintMany.
func Mint(cur realm, to address, amount int64) {
	mustBeMinter(cur)
	referralMint(to, amount)
	chain.Emit("Credit", "to", to.String(), "amount", strconv.FormatInt(amount, 10))
}

// MintMany credits a batch: "g1…:amount,g1…:amount" (base units), at most MaxBatch entries, no address twice, under
// the pool and the day cap. All or nothing — a bad entry panics, which aborts the whole transaction, and names the
// entry ("entry 3 g1…: over today's cap") so the box can drop it and send the rest. batchID is eight ASCII digits
// that must exceed the last one landed, so a batch the box re-sends after a lost receipt cannot land twice.
func MintMany(cur realm, batchID string, list string) {
	mustBeMinter(cur)
	if len(batchID) != 8 {
		panic("bubble: a batch id is eight digits")
	}
	for i := 0; i < len(batchID); i++ {
		if batchID[i] < '0' || batchID[i] > '9' {
			panic("bubble: a batch id is eight digits")
		}
	}
	if batchID <= lastBatch {
		panic("bubble: batch " + batchID + " is not after " + lastBatch)
	}
	parts := strings.Split(list, ",")
	if list == "" || len(parts) > MaxBatch {
		panic("bubble: a batch is 1 to " + strconv.Itoa(MaxBatch) + " entries")
	}
	seen := map[string]bool{}
	total := int64(0)
	for i, p := range parts {
		c := strings.Index(p, ":")
		if c <= 0 {
			panic("bubble: entry " + strconv.Itoa(i+1) + ": expected g1…:amount")
		}
		to, raw := p[:c], p[c+1:]
		n, err := strconv.ParseInt(raw, 10, 64)
		if err != nil {
			panic("bubble: entry " + strconv.Itoa(i+1) + " " + to + ": bad amount")
		}
		if seen[to] {
			panic("bubble: entry " + strconv.Itoa(i+1) + " " + to + ": twice in one batch")
		}
		seen[to] = true
		func() {
			defer func() {
				if r := recover(); r != nil {
					panic("bubble: entry " + strconv.Itoa(i+1) + " " + to + ": " + strings.TrimPrefix(toString(r), "bubble: "))
				}
			}()
			referralMint(address(to), n)
		}()
		total += n
	}
	lastBatch = batchID
	batches++
	chain.Emit("Batch", "id", batchID, "entries", strconv.Itoa(len(parts)), "total", strconv.FormatInt(total, 10))
}

func toString(r any) string {
	switch e := r.(type) {
	case error:
		return e.Error()
	case string:
		return e
	}
	return "failed"
}

// whole renders base units as whole BUBBLE for a message.
func whole(n int64) string { return strconv.FormatInt(n/one, 10) }
