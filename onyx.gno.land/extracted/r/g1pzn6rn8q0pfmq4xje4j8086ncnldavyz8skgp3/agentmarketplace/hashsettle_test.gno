package agentmarketplace

import (
	"testing"

	"gno.land/p/nt/uassert/v0"
	"gno.land/p/nt/urequire/v0"
)

const knownPhrase = "the expected result phrase"

func TestHashCommitHappyPath(cur realm, t *testing.T) {
	reset()
	register(cur, carol, "Research Bot", "research", RateHourly, 500000)
	hash := sha256Hex(knownPhrase)
	id := postHash(cur, alice, "Known answer task", "Reveal the phrase I already committed to.", "research", 2000000, hash, 3600)
	tk := mustGetTask(id)
	uassert.Equal(t, hash, tk.CommitHash)
	uassert.False(t, tk.RevealBy.IsZero())

	bidID := bid(cur, carol, id, 1500000, "I know it")
	accept(cur, alice, id, bidID)

	urequire.AbortsWithMessage(t, cur, "this task requires a hash reveal: call RevealAndComplete", func() {
		complete(cur, carol, id)
	})
	urequire.AbortsWithMessage(t, cur, "preimage does not match the commit hash", func() {
		reveal(cur, carol, id, "wrong phrase")
	})
	urequire.AbortsWithMessage(t, cur, "preimage must not be empty", func() {
		reveal(cur, carol, id, "")
	})
	urequire.AbortsWithMessage(t, cur, "only the winning agent can mark this task complete", func() {
		reveal(cur, alice, id, knownPhrase)
	})

	reveal(cur, carol, id, knownPhrase)
	tk = mustGetTask(id)
	uassert.Equal(t, StatusCompleted, tk.Status)
	uassert.True(t, tk.Settled)
	uassert.Equal(t, 1, mustGetAgent(carol).Completed)

	// poster can rate after a hash settlement just like a normal one
	rid := rate(cur, alice, id, 5, "Hash matched")
	uassert.Equal(t, 1, rid)
	_, trust, _, _ := ScoreOf(carol)
	uassert.Equal(t, int64(5000), trust)
}

func TestHashCommitRefusesOrdinaryCompleteAndViceVersa(cur realm, t *testing.T) {
	reset()
	register(cur, carol, "Research Bot", "research", RateHourly, 500000)
	ordinary := settleJob(cur, alice, carol, "Ordinary research", "This task has no commit hash.", "research", 2000000)
	urequire.AbortsWithMessage(t, cur, "this task does not use hash-commit settlement; call CompleteTask", func() {
		reveal(cur, carol, ordinary, knownPhrase)
	})

	hash := sha256Hex(knownPhrase)
	id := postHash(cur, alice, "Known answer task", "Reveal the phrase I already committed to.", "research", 1000000, hash, 3600)
	bidID := bid(cur, carol, id, 1000000, "ready")
	accept(cur, alice, id, bidID)
	urequire.AbortsWithMessage(t, cur, "this task requires a hash reveal: call RevealAndComplete", func() {
		complete(cur, carol, id)
	})
}

func TestHashCommitTimeoutRefund(cur realm, t *testing.T) {
	reset()
	register(cur, carol, "Research Bot", "research", RateHourly, 500000)
	hash := sha256Hex(knownPhrase)
	id := postHash(cur, alice, "Known answer task", "Reveal the phrase I already committed to.", "research", 2000000, hash, minRevealSecs)
	bidID := bid(cur, carol, id, 2000000, "ready")
	accept(cur, alice, id, bidID)

	urequire.AbortsWithMessage(t, cur, "the reveal deadline has not passed", func() {
		timeoutHash(cur, bob, id)
	})

	// min reveal is 60s; each height is 5s, so 13 heights is past the deadline.
	testing.SkipHeights(13)
	urequire.AbortsWithMessage(t, cur, "the reveal deadline has passed; the poster can be refunded with TimeoutHashTask", func() {
		reveal(cur, carol, id, knownPhrase)
	})

	timeoutHash(cur, bob, id) // anyone may time it out
	tk := mustGetTask(id)
	uassert.Equal(t, StatusCancelled, tk.Status)
	uassert.True(t, tk.Settled)

	urequire.AbortsWithMessage(t, cur, "only an in-progress hash task can time out", func() {
		timeoutHash(cur, alice, id)
	})
	urequire.AbortsWithMessage(t, cur, "only a settled, completed task can be rated", func() {
		rate(cur, alice, id, 5, "timed out")
	})
}

func TestHashCommitValidation(cur realm, t *testing.T) {
	reset()
	urequire.AbortsWithMessage(t, cur, "commit hash must be a 64-character hex SHA-256 digest", func() {
		postHash(cur, alice, "Known answer task", "Reveal the phrase I already committed to.", "research", 1000000, "abc", 3600)
	})
	urequire.AbortsWithMessage(t, cur, "commit hash must be a 64-character hex SHA-256 digest", func() {
		postHash(cur, alice, "Known answer task", "Reveal the phrase I already committed to.", "research", 1000000, "gg"+sha256Hex(knownPhrase)[2:], 3600)
	})
	urequire.AbortsWithMessage(t, cur, "reveal deadline must be between 60 seconds and 30 days", func() {
		postHash(cur, alice, "Known answer task", "Reveal the phrase I already committed to.", "research", 1000000, sha256Hex(knownPhrase), 59)
	})
	// uppercase hex is accepted and stored in lowercase
	lower := sha256Hex(knownPhrase)
	upper := toUpperHex(lower)
	id := postHash(cur, alice, "Known answer task", "Reveal the phrase I already committed to.", "research", 1000000, upper, 3600)
	uassert.Equal(t, lower, mustGetTask(id).CommitHash)
}

func TestHashCommitOpenCancelStillWorks(cur realm, t *testing.T) {
	reset()
	id := postHash(cur, alice, "Known answer task", "Reveal the phrase I already committed to.", "research", 2000000, sha256Hex(knownPhrase), 3600)
	cancel(cur, alice, id)
	uassert.Equal(t, StatusCancelled, mustGetTask(id).Status)
	uassert.True(t, mustGetTask(id).Settled)
}

func toUpperHex(s string) string {
	out := ""
	for _, c := range s {
		if c >= 'a' && c <= 'f' {
			out += string(c - ('a' - 'A'))
		} else {
			out += string(c)
		}
	}
	return out
}
