package mint

import (
	"strings"

	"gno.land/r/sys/users"
	validators "gno.land/r/sys/validators/v2"

	"gno.land/p/g19dzk54hhsdc3gllpksuj6gu4a3e6fl8cr6rn4w/sinopia/safe/v1"
	"gno.land/r/g19dzk54hhsdc3gllpksuj6gu4a3e6fl8cr6rn4w/sinopia/core"
)

// Allowlist sets (design §4.6). A phase's set is a comma-separated
// union of terms; an address is eligible if any term admits it:
//
//	users             registered in r/sys/users (live check)
//	validators        in the active validator set (live check)
//	holders:<cid>     holds a token of collection <cid>
//	merkle:<root>     in a sha256 merkle tree; the minter passes the proof
//
// A term may carry "|"-separated provenance notes for humans, e.g.
// "merkle:<root>|src:<git-sha>|data:<sha256>"; notes never affect logic.
const (
	MaxSetLen   = 512
	MaxSetTerms = 4
)

type setTerm struct {
	name, arg string
}

// parseSet validates a set and returns its terms; it panics on any error so
// AddPhase rejects a malformed set before it is ever frozen.
func parseSet(set string) []setTerm {
	safe.AssertText("set", set, MaxSetLen)
	parts := strings.Split(set, ",")
	if len(parts) > MaxSetTerms {
		panic("set: at most 4 terms")
	}
	terms := make([]setTerm, 0, len(parts))
	for _, part := range parts {
		body, _, _ := strings.Cut(part, "|")
		name, arg, _ := strings.Cut(body, ":")
		switch name {
		case "users", "validators":
			if arg != "" {
				panic("set: " + name + " takes no argument")
			}
		case "holders":
			core.Info(arg) // panics for an unknown collection
		case "merkle":
			arg = safe.AssertHex("set merkle root", arg, 32)
		default:
			panic("set: unknown term " + name)
		}
		terms = append(terms, setTerm{name: name, arg: arg})
	}
	return terms
}

// eligible reports whether addr may mint in a phase with this set, and why
// not. Live sets are evaluated at mint time, so a deleted user or a removed
// validator loses eligibility immediately.
func eligible(cid, set string, addr address, proof string) (bool, string) {
	if set == "" {
		return true, ""
	}
	for _, t := range parseSet(set) {
		switch t.name {
		case "users":
			if users.ResolveAddress(addr) != nil {
				return true, ""
			}
		case "validators":
			if validators.IsValidator(addr) {
				return true, ""
			}
		case "holders":
			if n, err := core.BalanceOf(t.arg, addr); err == nil && n > 0 {
				return true, ""
			}
		case "merkle":
			if proof != "" && safe.MerkleVerify(t.arg, safe.AllowlistLeaf(cid, addr), proof) {
				return true, ""
			}
		}
	}
	return false, "address is not in this phase's allowlist (" + set + ")"
}
