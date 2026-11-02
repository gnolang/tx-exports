package validator_scores

import (
	"strconv"
	"strings"
)

// An edition keeps each candidate as its validated payload line, in the
// order added. One string per candidate costs about 160 bytes of storage
// deposit; a struct in an AVL tree cost about 3,700 bytes (measured on
// gnodev at the gnoland-1 runtime).
type edition struct {
	number          int
	computedAt      string
	scorecardSHA256 string
	arenas          []string
	sealed          bool
	lines           []string // "operator|moniker|total|rank|github|s1,...,sN"
}

// editions holds the sealed editions in order, then at most one open
// edition, always last.
var editions []*edition

// operatorLen is the length of a canonical g1 address, the prefix of a line.
const operatorLen = 40

// find returns the line stored for operator, if any.
func (e *edition) find(operator string) (string, bool) {
	if len(operator) != operatorLen {
		return "", false
	}
	for _, line := range e.lines {
		if line[:operatorLen] == operator {
			return line, true
		}
	}
	return "", false
}

func openEdition() *edition {
	if len(editions) == 0 || editions[len(editions)-1].sealed {
		return nil
	}
	return editions[len(editions)-1]
}

func requireOpen(number int) *edition {
	e := openEdition()
	if e == nil || e.number != number {
		panic("validator_scores: edition " + strconv.Itoa(number) + " is not open")
	}
	return e
}

// OpenEdition starts a new edition and returns its number. Publisher only.
// arenas is a comma-separated list, for example "challenge,test13,firedrill".
func OpenEdition(cur realm, computedAt, scorecardSHA256, arenas string) int {
	requirePublisher(cur)
	if openEdition() != nil {
		panic("validator_scores: an edition is already open")
	}
	if !isComputedAt(computedAt) {
		panic("validator_scores: invalid computedAt")
	}
	if !isSHA256Hex(scorecardSHA256) {
		panic("validator_scores: invalid scorecard SHA-256")
	}
	e := &edition{
		number:          len(editions) + 1,
		computedAt:      computedAt,
		scorecardSHA256: scorecardSHA256,
		arenas:          parseArenas(arenas),
	}
	editions = append(editions, e)
	return e.number
}

// AddCandidates adds one candidate per payload line to the open edition.
// Publisher only. The whole payload is validated before anything is stored.
func AddCandidates(cur realm, number int, payload string) {
	requirePublisher(cur)
	e := requireOpen(number)
	if payload == "" {
		panic("validator_scores: empty payload")
	}
	lines := strings.Split(payload, "\n")
	seen := map[string]bool{}
	for i, line := range lines {
		operator := checkLine(line, len(e.arenas), i+1)
		if _, found := e.find(operator); found || seen[operator] {
			panic(lineError(i+1, "duplicate operator"))
		}
		seen[operator] = true
	}
	e.lines = append(e.lines, lines...)
}

// Seal closes the open edition for good. Publisher only. It fails unless the
// edition holds exactly expectedCount candidates (at least one).
func Seal(cur realm, number int, expectedCount int) {
	requirePublisher(cur)
	e := requireOpen(number)
	if expectedCount < 1 {
		panic("validator_scores: expectedCount must be at least 1")
	}
	if got := len(e.lines); got != expectedCount {
		panic("validator_scores: edition holds " + strconv.Itoa(got) + " candidates, expected " + strconv.Itoa(expectedCount))
	}
	e.sealed = true
}

// DiscardOpen drops the open edition. Publisher only. Its number is reused
// by the next OpenEdition. The slot is cleared first so the backing array
// does not keep the discarded edition stored.
func DiscardOpen(cur realm) {
	requirePublisher(cur)
	if openEdition() == nil {
		panic("validator_scores: no open edition")
	}
	editions[len(editions)-1] = nil
	editions = editions[:len(editions)-1]
}
