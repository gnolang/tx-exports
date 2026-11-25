// Package receipts is a public ledger of sealed predictions.
//
// You seal a call today by publishing only a SHA-256 commitment of it,
// plus a public topic and a date by which you promise to reveal it.
// Later you reveal the exact text and salt; the realm re-hashes them and
// stamps the call as verified, with the block height and time it was
// sealed. Nobody can see the call early, and nobody (you included) can
// change it after the fact.
//
// The twist that makes the record honest: a call that is not revealed by
// its own deadline is publicly marked "ducked" on the author's track
// record, so you cannot seal ten guesses and only reveal the one that
// landed. Once revealed, other accounts give a verdict (held / missed).
package receipts

import (
	"chain"
	"chain/runtime"
	"crypto/sha256"
	"encoding/hex"
	"strconv"
	"strings"
	"time"

	"gno.land/p/nt/avl/v0"
	"gno.land/p/nt/seqid/v0"
)

const (
	MaxTopicLen      = 120
	MaxPredictionLen = 560
	MinSaltLen       = 8
	MaxSaltLen       = 64
	MinRevealDays    = 1
	MaxRevealDays    = 3650
	Separator        = "|"
)

// Call is one sealed prediction.
type Call struct {
	ID         int
	Author     address
	Topic      string
	Commitment string // lowercase hex sha256(salt + "|" + prediction)

	SealedHeight int64
	SealedAt     time.Time
	RevealBy     time.Time

	Revealed       bool
	Prediction     string
	Salt           string
	RevealedHeight int64
	RevealedAt     time.Time

	Held   int
	Missed int
	votes  *avl.Tree // voter address -> "held" | "missed"
}

type author struct {
	calls []int
}

var (
	ids     seqid.ID
	calls   avl.Tree // seqid binary -> *Call
	authors avl.Tree // address string -> *author
)

// Commit returns the commitment for a prediction and salt:
// lowercase hex of sha256(salt + "|" + prediction).
// It is a plain read helper; compute it off-chain if the text is secret.
func Commit(prediction, salt string) string {
	sum := sha256.Sum256([]byte(salt + Separator + prediction))
	return hex.EncodeToString(sum[:])
}

// Seal publishes a commitment. topic is public (e.g. "BTC close on Dec 31"),
// commitment is the 64-char hex hash, revealByDays is the deadline you
// promise to reveal by. Returns the new call ID.
func Seal(cur realm, topic, commitment string, revealByDays int) int {
	caller := cur.Previous().Address()
	topic = strings.TrimSpace(topic)
	if topic == "" {
		panic("topic is required")
	}
	if len(topic) > MaxTopicLen {
		panic("topic is longer than " + strconv.Itoa(MaxTopicLen) + " bytes")
	}
	commitment = strings.ToLower(strings.TrimSpace(commitment))
	if !isHex64(commitment) {
		panic("commitment must be 64 hex characters (sha256)")
	}
	if revealByDays < MinRevealDays || revealByDays > MaxRevealDays {
		panic("revealByDays must be between 1 and 3650")
	}

	now := time.Now()
	id := int(ids.Next())
	c := &Call{
		ID:           id,
		Author:       caller,
		Topic:        topic,
		Commitment:   commitment,
		SealedHeight: chainHeight(),
		SealedAt:     now,
		RevealBy:     now.Add(time.Duration(revealByDays) * 24 * time.Hour),
		votes:        avl.NewTree(),
	}
	calls.Set(key(id), c)

	a := getAuthor(caller)
	if a == nil {
		a = &author{}
		authors.Set(caller.String(), a)
	}
	a.calls = append(a.calls, id)

	chain.Emit("Sealed",
		"id", strconv.Itoa(id),
		"author", caller.String(),
		"commitment", commitment,
	)
	return id
}

// Reveal opens a sealed call. Only its author can reveal it. The realm
// re-computes sha256(salt + "|" + prediction) and refuses on mismatch.
func Reveal(cur realm, id int, prediction, salt string) {
	caller := cur.Previous().Address()
	c := mustGet(id)
	if c.Author != caller {
		panic("only the author can reveal this call")
	}
	if c.Revealed {
		panic("call already revealed")
	}
	if len(salt) < MinSaltLen || len(salt) > MaxSaltLen {
		panic("salt must be 8 to 64 bytes")
	}
	if len(prediction) == 0 || len(prediction) > MaxPredictionLen {
		panic("prediction must be 1 to " + strconv.Itoa(MaxPredictionLen) + " bytes")
	}
	if Commit(prediction, salt) != c.Commitment {
		panic("prediction and salt do not match the sealed commitment")
	}
	c.Revealed = true
	c.Prediction = prediction
	c.Salt = salt
	c.RevealedHeight = chainHeight()
	c.RevealedAt = time.Now()

	chain.Emit("Revealed",
		"id", strconv.Itoa(id),
		"author", caller.String(),
		"onTime", strconv.FormatBool(!c.RevealedAt.After(c.RevealBy)),
	)
}

// Verdict records whether a revealed call came true. verdict is "held" or
// "missed". One verdict per account per call; calling again changes it.
// Authors cannot judge their own calls.
func Verdict(cur realm, id int, verdict string) {
	caller := cur.Previous().Address()
	c := mustGet(id)
	if !c.Revealed {
		panic("call is still sealed")
	}
	if c.Author == caller {
		panic("authors cannot judge their own call")
	}
	verdict = strings.ToLower(strings.TrimSpace(verdict))
	if verdict != "held" && verdict != "missed" {
		panic(`verdict must be "held" or "missed"`)
	}
	k := caller.String()
	if prev := c.votes.Get(k); prev != nil {
		if prev.(string) == verdict {
			return
		}
		if prev.(string) == "held" {
			c.Held--
		} else {
			c.Missed--
		}
	}
	c.votes.Set(k, verdict)
	if verdict == "held" {
		c.Held++
	} else {
		c.Missed++
	}
	chain.Emit("Verdict", "id", strconv.Itoa(id), "voter", k, "verdict", verdict)
}

// Status values for a call at the current block time.
const (
	StatusSealed   = "sealed"
	StatusDucked   = "ducked"
	StatusRevealed = "revealed"
	StatusLate     = "revealed late"
)

// StatusOf returns the call's status at the current block time.
func StatusOf(id int) string {
	return mustGet(id).status(time.Now())
}

// GetCall returns a copy of a call's public fields, for clients (vm/qeval).
func GetCall(id int) (author address, topic, commitment, status, prediction string, sealedHeight int64, revealBy string, held, missed int) {
	c := mustGet(id)
	return c.Author, c.Topic, c.Commitment, c.status(time.Now()), c.Prediction,
		c.SealedHeight, c.RevealBy.UTC().Format(time.RFC3339), c.Held, c.Missed
}

// Count returns how many calls have been sealed.
func Count() int { return calls.Size() }

func (c *Call) status(now time.Time) string {
	if c.Revealed {
		if c.RevealedAt.After(c.RevealBy) {
			return StatusLate
		}
		return StatusRevealed
	}
	if now.After(c.RevealBy) {
		return StatusDucked
	}
	return StatusSealed
}

// Outcome is the crowd verdict on a revealed call: "held", "missed",
// "split" or "" (no verdicts yet).
func (c *Call) outcome() string {
	switch {
	case c.Held == 0 && c.Missed == 0:
		return ""
	case c.Held > c.Missed:
		return "held"
	case c.Missed > c.Held:
		return "missed"
	}
	return "split"
}

func mustGet(id int) *Call {
	v := calls.Get(key(id))
	if v == nil {
		panic("call " + strconv.Itoa(id) + " not found")
	}
	return v.(*Call)
}

func getCall(id int) *Call {
	v := calls.Get(key(id))
	if v == nil {
		return nil
	}
	return v.(*Call)
}

func getAuthor(a address) *author {
	v := authors.Get(a.String())
	if v == nil {
		return nil
	}
	return v.(*author)
}

func key(id int) string { return seqid.ID(id).Binary() }

func isHex64(s string) bool {
	if len(s) != 64 {
		return false
	}
	for i := 0; i < len(s); i++ {
		ch := s[i]
		if !(ch >= '0' && ch <= '9' || ch >= 'a' && ch <= 'f') {
			return false
		}
	}
	return true
}

func chainHeight() int64 { return runtime.ChainHeight() }
