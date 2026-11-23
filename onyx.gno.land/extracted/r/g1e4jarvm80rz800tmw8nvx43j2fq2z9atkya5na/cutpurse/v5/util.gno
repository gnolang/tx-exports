package cutpurse

import (
	"chain"
	"chain/banker"
	"chain/runtime"
	"chain/runtime/unsafe"
	"crypto/sha256"
	"encoding/hex"
	"strconv"
	"strings"

	"gno.land/p/nt/markdown/sanitize/v0"
)

// payIn enforces the send envelope of the call: the caller must cover want
// ugnot, anything above want is refunded immediately.
//
// A BankerTypeRealmSend banker can only spend the realm's own address, so fees
// must arrive with the message (tx send coins); banker.IssueCoin is not a
// substitute because realm-issued coins carry a "/<pkgpath>:" denom prefix and
// would not be the native ugnot the game escrows.
func payIn(cur realm, want int64) {
	// cur.Previous() is unreadable when a test drives the mutator with a bare
	// frame ("cannot seek beyond origin caller override"), so the caller-kind
	// guard is derived from the envelope instead: a realm caller attaches
	// nothing, so a zero envelope is a caller error, not a fee shortfall.
	sent := unsafe.OriginSend().AmountOf(Denom)
	if sent == 0 {
		panic(ErrNotUserCall)
	}
	who := here(cur)
	if sent < want {
		panic(ErrFeeTooLow)
	}
	if sent > want {
		banker.NewBanker(banker.BankerTypeRealmSend, cur).SendCoins(
			cur.Address(), who, chain.NewCoins(chain.NewCoin(Denom, sent-want)))
	}
}

// mustJob returns the job or panics e404.
func mustJob(id int64) *Job {
	j, ok := jobs[id]
	if !ok {
		panic(ErrNoJob)
	}
	return j
}

func mustHeight() int64 { return runtime.ChainHeight() }

// here is the acting player. It is the message's origin caller, not
// cur.Previous(): a crossed call from another *package* would otherwise act as
// that package's address instead of the signing wallet.
func here(cur realm) address {
	// Actor = the transaction's origin wallet, not cur.Previous(): `here` is a
	// non-crossing helper, so a Previous() taken in here re-anchors to this
	// frame and would resolve to the *previous* realm instead of the caller's
	// realm. OriginCaller is frame-independent and gives the human either way,
	// so a router realm cannot act on behalf of the last user in the tx.
	if who := unsafe.OriginCaller(); who != address("") {
		return who
	}
	// No origin wallet (a realm calling with no user behind it): the caller
	// frame is the only identity left.
	return cur.Previous().Address()
}

// clampFee bounds a caller-supplied fee into [MinFee, MaxFee].
func clampFee(fee int64) int64 {
	if fee < MinFee {
		return MinFee
	}
	if fee > MaxFee {
		return MaxFee
	}
	return fee
}

// cleanName sanitizes user text for write and bounds it to MaxNameRunes runes
// so Render is safe for arbitrarily long input (§10 R9).
func cleanName(raw string) string {
	trimmed := strings.TrimSpace(raw)
	if trimmed == "" {
		panic(ErrBadName)
	}
	rs := []rune(sanitize.InlineText(trimmed))
	if len(rs) > MaxNameRunes {
		rs = rs[:MaxNameRunes]
	}
	// a truncated trailing escape would eat the following character
	for len(rs) > 0 && rs[len(rs)-1] == '\\' {
		rs = rs[:len(rs)-1]
	}
	if len(rs) == 0 {
		panic(ErrBadName)
	}
	return string(rs)
}

func validSalt(salt string) bool {
	if len(salt) == 0 || len(salt) > MaxSaltLen {
		return false
	}
	for i := 0; i < len(salt); i++ {
		b := salt[i]
		if b <= 0x20 || b >= 0x7f {
			return false
		}
	}
	return true
}

func isHex64(h string) bool {
	if len(h) != 64 {
		return false
	}
	for i := 0; i < len(h); i++ {
		b := h[i]
		ok := (b >= '0' && b <= '9') || (b >= 'a' && b <= 'f') || (b >= 'A' && b <= 'F')
		if !ok {
			return false
		}
	}
	return true
}

func sha256Hex(s string) string {
	sum := sha256.Sum256([]byte(s))
	return hex.EncodeToString(sum[:])
}

// commitHash is the sealed preimage.
//
//   v1|action|len:caller|len:salt|id|round
//
// Free-form fields are length-prefixed instead of separator-delimited: the salt
// is printable ASCII and may itself contain "|", which would otherwise let two
// different (salt, field) pairs produce one preimage.
func commitHash(id int64, action uint8, salt, who string, round uint8) string {
	return sha256Hex(
		"v1|" + strconv.FormatUint(uint64(action), 10) + "|" +
			lenPrefix(who) + "|" +
			lenPrefix(salt) + "|" +
			strconv.FormatInt(id, 10) + "|" +
			strconv.FormatUint(uint64(round), 10))
}

func lenPrefix(s string) string { return strconv.Itoa(len(s)) + ":" + s }

// CommitHash is the render-facing helper (§7): designer passes the *typed*
// action and salt and shows the resulting string to paste in Commit.
func CommitHash(id int64, action uint8, salt, who string) string {
	rnd := uint8(0)
	if j, ok := jobs[id]; ok {
		rnd = j.Round
	}
	return commitHash(id, action, salt, who, rnd)
}

func maxInt64(a, b int64) int64 {
	if a > b {
		return a
	}
	return b
}

func isLive(j *Job) bool { return j.Phase < PhaseSettled }

func seatOf(j *Job, who address) int {
	for i := 0; i < int(j.NSeats); i++ {
		if j.Seats[i].Addr == who {
			return i
		}
	}
	return -1
}

func countCommitted(j *Job) int {
	n := 0
	for i := 0; i < int(j.NSeats); i++ {
		if j.Seats[i].Committed {
			n++
		}
	}
	return n
}

func countRevealed(j *Job) int {
	n := 0
	for i := 0; i < int(j.NSeats); i++ {
		if j.Seats[i].Action != ActNone {
			n++
		}
	}
	return n
}

func statFor(who address) *Stats {
	k := who.String()
	s, ok := stats[k]
	if !ok {
		s = &Stats{}
		stats[k] = s
	}
	return s
}

func repDown(who address) {
	s := statFor(who)
	if s.Escapes > 0 {
		s.Escapes--
	}
}

// purgeOld keeps the jobs map bounded: once more than LedgerMax jobs exist,
// settled jobs are dropped oldest-first (the ledger ring stays permanent).
func purgeOld() {
	for i := 0; i < LedgerMax; i++ {
		if len(jobs) <= LedgerMax {
			return
		}
		oldest := int64(0)
		found := false
		for id := range jobs {
			if !isLive(jobs[id]) && jobs[id].SettledAt != 0 && (!found || id < oldest) {
				oldest = id
				found = true
			}
		}
		if !found {
			return
		}
		delete(jobs, oldest)
	}
}
