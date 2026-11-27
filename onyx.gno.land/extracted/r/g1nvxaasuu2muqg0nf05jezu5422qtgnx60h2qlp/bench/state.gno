package bench

import (
	"crypto/sha256"
	"strconv"
	"strings"

	"gno.land/p/g1nvxaasuu2muqg0nf05jezu5422qtgnx60h2qlp/cube3x3"
	"gno.land/p/nt/avl/v0"
)

var (
	challenges   = avl.NewTree() // roundKey -> *challengeRecord
	commits      = avl.NewTree() // roundKey|addr -> commitreveal.Record
	submissions  = avl.NewTree() // roundKey|addr -> *submissionRecord
	leaderboards *avl.Node       // roundKey|pad(obtm,4)|pad(qtm,4)|pad(revealedAt,12)|addr -> addr
	quickRounds  = avl.NewTree() // pad(seq,10) -> roundKey
	customRules  = avl.NewTree() // <pkgPath>:<ruleID> -> registeredRule
	quickSeq     uint64
)

func computeRoundSeed(roundKey string, height int64, blockTimeUnix int64) [32]byte {
	return sha256.Sum256([]byte(Domain + "|" + roundKey + "|" + strconv.FormatInt(height, 10) + "|" + strconv.FormatInt(blockTimeUnix, 10)))
}

func computePhase(c *challengeRecord, nowUnix int64) string {
	if nowUnix < c.CommitDeadline {
		return "commit_open"
	}
	if nowUnix < c.RevealDeadline {
		return "reveal_open"
	}
	return "finalized"
}

func normalizeModeTag(raw string) (string, bool) {
	switch raw {
	case "":
		return "human", true
	case "human", "assisted", "ai":
		return raw, true
	default:
		return "", false
	}
}

func validateAgentModel(raw string) (string, bool) {
	model := strings.Trim(raw, " ")
	if len(model) > MaxAgentModelBytes {
		return "", false
	}
	for i := 0; i < len(model); i++ {
		if model[i] < 0x20 || model[i] > 0x7e {
			return "", false
		}
	}
	return model, true
}

// padInt64 preserves numeric ordering for nonnegative key parts that fit width.
func padInt64(n int64, width int) string {
	digits := strconv.FormatInt(n, 10)
	if len(digits) >= width {
		return digits
	}
	return strings.Repeat("0", width-len(digits)) + digits
}

// prefixRangeEnd returns the exclusive AVL bound for prefix roundKey + "|".
// ASCII '~' sorts after '|', decimal digits and lowercase address characters.
func prefixRangeEnd(prefix string) string {
	return prefix + "~"
}

func leaderboardKey(roundKey string, sub *submissionRecord) string {
	return roundKey + "|" + padInt64(int64(sub.OBTM), 4) + "|" + padInt64(int64(sub.QTM), 4) + "|" +
		padInt64(sub.RevealedAt, 12) + "|" + sub.Solver
}

func submissionRank(roundKey string, sub *submissionRecord) int {
	index, _, found := leaderboards.Get(leaderboardKey(roundKey, sub))
	if !found {
		return 0
	}
	// Get returns the insertion index for a missing key. The bare prefix sorts
	// immediately before this round's entries, so its index is the round's offset.
	first, _, _ := leaderboards.Get(roundKey + "|")
	return index - first + 1
}

func resolveRule(ruleKey string) (cube3x3.ConstraintRule, bool) {
	if rule, ok := cube3x3.BuiltinRule(ruleKey); ok {
		return rule, true
	}
	entry, ok := customRules.Get(ruleKey).(registeredRule)
	return entry.Rule, ok
}
