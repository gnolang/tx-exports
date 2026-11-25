package grantround

import (
	"strings"
	"testing"

	"gno.land/p/nt/uassert/v0"
)

const tSheetSalt = "sheet-salt-sheet-salt-sheet-salt" // exactly 32 characters

func commit(cur realm, id int, ev address, scores string) {
	testing.SetRealm(user(ev))
	CommitScores(cross(cur), id, SheetDigest(scores, tSheetSalt, ev))
}

func TestSheetDigestKnownVector(t *testing.T) {
	// printf '5,5;6,0|salt|g1evaluator' | sha256sum
	uassert.Equal(t, "d31ec990030b4a0a775ec95b3c125b26569b7b3f1d4d0a2ffd98259c8ccaf129", SheetDigest("5,5;6,0", "salt", address("g1evaluator")))
}

func TestCommitScores(cur realm, t *testing.T) {
	id := revealedRound(cur, 2, "lowest")
	hash := SheetDigest("5,5;6,0", tSheetSalt, e1)
	testing.SetRealm(user(e1))
	uassert.AbortsContains(t, cur, "64 lowercase hex", func() { CommitScores(cross(cur), id, "abc") }, "not a digest")
	uassert.AbortsContains(t, cur, "64 lowercase hex", func() { CommitScores(cross(cur), id, strings.ToUpper(hash)) }, "upper case")
	CommitScores(cross(cur), id, hash)
	uassert.Equal(t, hash, mustGet(id).Commits[0])
	uassert.AbortsContains(t, cur, "already committed", func() {
		CommitScores(cross(cur), id, SheetDigest("0,0;0,0", tSheetSalt, e1))
	})
	uassert.Equal(t, hash, mustGet(id).Commits[0], "first commitment kept")
}

func TestCommitScoresOnlyJoinedEvaluator(cur realm, t *testing.T) {
	id := revealedRound(cur, 2, "lowest")
	testing.SetRealm(user(outsider))
	uassert.AbortsContains(t, cur, "joined evaluator", func() {
		CommitScores(cross(cur), id, SheetDigest("1,1;1,1", tSheetSalt, outsider))
	})
}

func TestCommitScoresOutsidePhase(cur realm, t *testing.T) {
	id := adoptedRound(cur, 2, "lowest")
	hash := SheetDigest("5,5;6,0", tSheetSalt, e1)
	testing.SetRealm(user(e1))
	uassert.AbortsContains(t, cur, "score phase", func() { CommitScores(cross(cur), id, hash) }, "before the apps are revealed")

	testing.SetRealm(user(customer))
	Reveal(cross(cur), id, testAppsEncoded(), tSalt)
	testing.SkipHeights(30) // past HScore (h0+40)
	testing.SetRealm(user(e1))
	uassert.AbortsContains(t, cur, "score phase", func() { CommitScores(cross(cur), id, hash) }, "after HScore")
}

func openSheet(cur realm, id int, ev address, scores string) {
	testing.SetRealm(user(ev))
	RevealScores(cross(cur), id, scores, tSheetSalt)
}

func TestRevealScores(cur realm, t *testing.T) {
	id := revealedRound(cur, 2, "lowest")
	commit(cur, id, e1, "5,5;6,0")
	testing.SetRealm(user(e1))
	uassert.AbortsContains(t, cur, "sheet reveal phase", func() { RevealScores(cross(cur), id, "5,5;6,0", tSheetSalt) }, "before HScore")
	uassert.True(t, mustGet(id).Sheets[0] == nil, "nothing revealed early")

	testing.SkipHeights(30) // past HScore (h0+40)
	testing.SetRealm(user(e1))
	uassert.AbortsContains(t, cur, "do not match", func() { RevealScores(cross(cur), id, "5,5;6,0", tWrong) }, "wrong salt")
	uassert.AbortsContains(t, cur, "do not match", func() { RevealScores(cross(cur), id, "5,5;6,1", tSheetSalt) }, "other scores")
	uassert.True(t, mustGet(id).Sheets[0] == nil, "state unchanged after rejected reveals")
	RevealScores(cross(cur), id, "5,5;6,0", tSheetSalt)
	r := mustGet(id)
	uassert.Equal(t, e1, r.Sheets[0].Evaluator)
	uassert.Equal(t, 6, r.Sheets[0].Scores[1][0])
	uassert.AbortsContains(t, cur, "already revealed", func() { RevealScores(cross(cur), id, "5,5;6,0", tSheetSalt) })
}

func TestRevealScoresCopiedHash(cur realm, t *testing.T) {
	id := revealedRound(cur, 2, "lowest")
	commit(cur, id, e1, "5,5;6,0")
	testing.SetRealm(user(e2)) // e2 copies e1's public hash
	CommitScores(cross(cur), id, SheetDigest("5,5;6,0", tSheetSalt, e1))
	testing.SkipHeights(30)
	openSheet(cur, id, e1, "5,5;6,0") // scores and salt are now public
	testing.SetRealm(user(e2))
	uassert.AbortsContains(t, cur, "do not match", func() { RevealScores(cross(cur), id, "5,5;6,0", tSheetSalt) }, "copied hash")
	uassert.True(t, mustGet(id).Sheets[1] == nil, "copied hash stays closed")
}

func TestRevealScoresInvalidSheet(cur realm, t *testing.T) {
	id := revealedRound(cur, 2, "lowest")
	commit(cur, id, e1, "11,0;0,0")
	commit(cur, id, e2, "5,5")
	commit(cur, id, e3, "a,b;c,d")
	testing.SkipHeights(30)
	testing.SetRealm(user(e1))
	uassert.AbortsContains(t, cur, "invalid scores", func() { RevealScores(cross(cur), id, "11,0;0,0", tSheetSalt) }, "out of range")
	testing.SetRealm(user(e2))
	uassert.AbortsContains(t, cur, "invalid scores", func() { RevealScores(cross(cur), id, "5,5", tSheetSalt) }, "missing app")
	testing.SetRealm(user(e3))
	uassert.AbortsContains(t, cur, "invalid scores", func() { RevealScores(cross(cur), id, "a,b;c,d", tSheetSalt) }, "not numbers")
}

func TestRevealScoresWithoutCommit(cur realm, t *testing.T) {
	id := revealedRound(cur, 2, "lowest")
	testing.SkipHeights(30)
	testing.SetRealm(user(e1))
	uassert.AbortsContains(t, cur, "no committed scores", func() { RevealScores(cross(cur), id, "5,5;6,0", tSheetSalt) })
	testing.SetRealm(user(outsider))
	uassert.AbortsContains(t, cur, "joined evaluator", func() { RevealScores(cross(cur), id, "5,5;6,0", tSheetSalt) })
}

func TestRevealScoresAfterDeadline(cur realm, t *testing.T) {
	id := revealedRound(cur, 2, "lowest")
	commit(cur, id, e1, "5,5;6,0")
	testing.SkipHeights(40) // past HSheetReveal (h0+50)
	testing.SetRealm(user(e1))
	uassert.AbortsContains(t, cur, "sheet reveal phase", func() { RevealScores(cross(cur), id, "5,5;6,0", tSheetSalt) })
}

func TestRevealScoresAtDeadline(cur realm, t *testing.T) {
	id := revealedRound(cur, 2, "lowest")
	commit(cur, id, e1, "5,5;6,0")
	testing.SkipHeights(39) // h0+50 == HSheetReveal
	openSheet(cur, id, e1, "5,5;6,0")
	uassert.True(t, mustGet(id).Sheets[0] != nil, "the deadline block still counts")
}

// The short salt opens the commitment, so only the length can reject it.
func TestRevealScoresShortSalt(cur realm, t *testing.T) {
	uassert.Equal(t, 32, len(tSheetSalt))
	id := revealedRound(cur, 2, "lowest")
	testing.SetRealm(user(e1))
	CommitScores(cross(cur), id, SheetDigest("5,5;6,0", tSheetSalt[:31], e1))
	testing.SetRealm(user(e2))
	CommitScores(cross(cur), id, SheetDigest("5,5;6,0", "", e2))
	commit(cur, id, e3, "5,5;6,0")
	testing.SkipHeights(30)
	testing.SetRealm(user(e1))
	uassert.AbortsContains(t, cur, "salt too short", func() { RevealScores(cross(cur), id, "5,5;6,0", tSheetSalt[:31]) }, "31")
	testing.SetRealm(user(e2))
	uassert.AbortsContains(t, cur, "salt too short", func() { RevealScores(cross(cur), id, "5,5;6,0", "") }, "empty")
	openSheet(cur, id, e3, "5,5;6,0")
	r := mustGet(id)
	uassert.True(t, r.Sheets[0] == nil && r.Sheets[1] == nil, "short salts stay closed")
	uassert.True(t, r.Sheets[2] != nil, "32 characters are enough")
}
