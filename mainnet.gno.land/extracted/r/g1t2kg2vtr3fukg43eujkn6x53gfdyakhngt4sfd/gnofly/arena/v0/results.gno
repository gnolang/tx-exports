package arena

import (
	"strings"

	"gno.land/p/g1t2kg2vtr3fukg43eujkn6x53gfdyakhngt4sfd/gnofly/arena/payout/v0"
)

// result is how a game ended, kept for readers: no payment is ever computed
// from it.
type result struct {
	mode     string
	stake    int64
	outcome  string // settled, cancelled or refunded
	players  int64  // how many played
	pot      int64  // their stakes
	fee      int64
	closedAt int64           // block time, Unix seconds
	payouts  []payout.Payout // who was paid what, in the order of the players
}

const (
	outcomeSettled   = "settled"
	outcomeCancelled = "cancelled"
	outcomeRefunded  = "refunded"
)

// maxResults is how many closed games the realm remembers.
const maxResults = 50

// A result is stored as one string, its fields separated by "|", the payouts
// last as "address:amount" separated by ",":
//
//	mode|stake|outcome|players|pot|fee|closedAt|g1...:19500000,g1...:500000
func (r result) encode() string {
	var b strings.Builder
	b.WriteString(r.mode)
	for _, n := range []string{itoa(r.stake), r.outcome, itoa(r.players), itoa(r.pot), itoa(r.fee), itoa(r.closedAt)} {
		b.WriteByte('|')
		b.WriteString(n)
	}
	b.WriteByte('|')
	b.WriteString(joinPayouts(r.payouts))
	return b.String()
}

func decodeResult(s string) result {
	f := strings.Split(s, "|")
	if len(f) != 8 {
		panic(errCorruptResult)
	}
	num := func(i int) int64 {
		n, ok := digits(f[i])
		if !ok {
			panic(errCorruptResult)
		}
		return n
	}
	r := result{mode: f[0], stake: num(1), outcome: f[2], players: num(3), pot: num(4), fee: num(5), closedAt: num(6)}
	if r.outcome != outcomeSettled && r.outcome != outcomeCancelled && r.outcome != outcomeRefunded {
		panic(errCorruptResult)
	}
	if f[7] == "" {
		return r
	}
	for _, entry := range strings.Split(f[7], ",") {
		colon := indexFrom(entry, 0, ':')
		if colon == 0 || colon == len(entry) {
			panic(errCorruptResult)
		}
		amount, ok := digits(entry[colon+1:])
		if !ok {
			panic(errCorruptResult)
		}
		r.payouts = append(r.payouts, payout.Payout{Address: address(entry[:colon]), Amount: amount})
	}
	return r
}

// record keeps the result of a closed game, and forgets the oldest one past
// maxResults.
func record(id string, r result) {
	results.Set(id, r.encode())
	closed = append(closed, id)
	if len(closed) > maxResults {
		results.Remove(closed[0])
		next := make([]string, len(closed)-1)
		copy(next, closed[1:])
		closed = next
	}
}

// resultOf returns the result of a closed game, if the realm still has it.
func resultOf(id string) (result, bool) {
	v := results.Get(id)
	if v == nil {
		return result{}, false
	}
	return decodeResult(v.(string)), true
}

// indexFrom returns the index of the first c in s at or after i, or len(s).
func indexFrom(s string, i int, c byte) int {
	for i < len(s) && s[i] != c {
		i++
	}
	return i
}

// digits parses a non-negative decimal of at most 18 digits.
func digits(s string) (int64, bool) {
	if len(s) == 0 || len(s) > 18 {
		return 0, false
	}
	n := int64(0)
	for i := 0; i < len(s); i++ {
		c := s[i]
		if c < '0' || c > '9' {
			return 0, false
		}
		n = n*10 + int64(c-'0')
	}
	return n, true
}
