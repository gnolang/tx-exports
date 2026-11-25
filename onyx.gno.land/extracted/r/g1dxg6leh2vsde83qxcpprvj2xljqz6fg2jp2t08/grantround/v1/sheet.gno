package grantround

import (
	"chain/runtime"
	"crypto/sha256"
	"encoding/hex"

	"gno.land/p/g1dxg6leh2vsde83qxcpprvj2xljqz6fg2jp2t08/rulecalc/v1"
)

// SheetDigest is the commitment to a score sheet:
// hex(sha256(scores + "|" + salt + "|" + evaluator)). The evaluator address binds
// it to its author, so a copied hash cannot be opened by another evaluator.
//
// Off-chain equivalent:
//
//	printf 'SCORES|SALT|g1evaluator' | sha256sum
func SheetDigest(scores, salt string, evaluator address) string {
	sum := sha256.Sum256([]byte(scores + "|" + salt + "|" + evaluator.String()))
	return hex.EncodeToString(sum[:])
}

// CommitScores stores the caller's SheetDigest once, before HScore.
func CommitScores(cur realm, roundID int, hash string) {
	r := mustGet(roundID)
	if PhaseOf(r, runtime.ChainHeight()) != PhaseScore {
		panic("grantround: not in the score phase")
	}
	i := r.joinedIndex(cur.Previous().Address())
	if r.Commits[i] != "" {
		panic("grantround: scores already committed")
	}
	if !isHexDigest(hash) {
		panic("grantround: scores hash must be 64 lowercase hex characters")
	}
	r.Commits[i] = hash
}

// RevealScores opens the caller's committed sheet after HScore and until
// HSheetReveal. scores is "c0,c1;c0,c1": apps by ID separated by ";", criteria
// in rule order separated by ","; salt has at least minSaltLen bytes. A
// commitment left closed, or made with a shorter salt, counts as a missed mandate.
func RevealScores(cur realm, roundID int, scores string, salt string) {
	r := mustGet(roundID)
	if PhaseOf(r, runtime.ChainHeight()) != PhaseSheetReveal {
		panic("grantround: not in the sheet reveal phase")
	}
	caller := cur.Previous().Address()
	i := r.joinedIndex(caller)
	if r.Commits[i] == "" {
		panic("grantround: no committed scores to reveal")
	}
	if r.Sheets[i] != nil {
		panic("grantround: scores already revealed")
	}
	mustLongSalt(salt)
	if SheetDigest(scores, salt, caller) != r.Commits[i] {
		panic("grantround: scores do not match the committed hash")
	}
	parsed, err := parseScores(scores)
	if err != nil {
		panic("grantround: invalid scores: " + err.Error())
	}
	sheet := rulecalc.Sheet{Evaluator: caller, Scores: parsed}
	if err := rulecalc.ValidateSheet(*r.Rule, len(r.Apps), sheet); err != nil {
		panic("grantround: invalid scores: " + err.Error())
	}
	r.Sheets[i] = &sheet
}
