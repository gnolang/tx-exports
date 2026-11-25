// Package grantround runs agent-evaluated grant rounds. Evaluators agree on an
// evaluation rule before the applications are revealed, each posts a refundable
// bond for submitting their own scores on time, and the realm computes and pays
// the winner by the adopted rule.
package grantround

import (
	"chain/runtime"
	"chain/runtime/unsafe"
	"strconv"
	"strings"

	"gno.land/p/g1dxg6leh2vsde83qxcpprvj2xljqz6fg2jp2t08/rulecalc/v1"
	"gno.land/p/nt/avl/v0"
)

// Phase is derived from the round state and the current height; it is never stored.
type Phase int

const (
	PhaseJoin Phase = iota + 1
	PhaseRule
	PhaseReveal
	PhaseScore
	PhaseSheetReveal
	PhaseAwaitingFinalize
	PhaseDone
	PhaseCancelled
)

func (p Phase) String() string {
	switch p {
	case PhaseJoin:
		return "join"
	case PhaseRule:
		return "rule"
	case PhaseReveal:
		return "reveal"
	case PhaseScore:
		return "score"
	case PhaseSheetReveal:
		return "sheet reveal"
	case PhaseAwaitingFinalize:
		return "awaiting finalize"
	case PhaseDone:
		return "done"
	case PhaseCancelled:
		return "cancelled"
	}
	return "unknown"
}

// Round is one grant round. Per-evaluator data lives in slices aligned with
// Evaluators. Designated holds the sponsor the customer named for each
// evaluator; Sponsors is set when that sponsor joins (empty = not joined).
type Round struct {
	ID       int
	Customer address
	Goal     string
	Grant    int64
	AppsHash string

	Evaluators []address
	Designated []address
	Sponsors   []address
	Bond       int64
	Slash      int64

	HJoin, HRule, HReveal, HScore, HSheetReveal int64

	Proposal    *rulecalc.Rule
	ProposalSeq int
	Votes       []bool
	Rule        *rulecalc.Rule

	Apps    []rulecalc.App
	Commits []string // SheetDigest per evaluator, "" = none
	Sheets  []*rulecalc.Sheet

	Finalized bool
	Cancelled bool
	Paid      bool
	Winner    int
}

var (
	rounds  avl.Tree // roundKey(id) -> *Round
	counter int
)

// roundKey pads the id to 10 digits so that keys sort in numeric order.
func roundKey(id int) string {
	s := strconv.Itoa(id)
	if len(s) < 10 {
		s = strings.Repeat("0", 10-len(s)) + s
	}
	return s
}

func mustGet(id int) *Round {
	v := rounds.Get(roundKey(id))
	if v == nil {
		panic("grantround: round " + strconv.Itoa(id) + " not found")
	}
	return v.(*Round)
}

func (r *Round) joined() int {
	n := 0
	for _, s := range r.Sponsors {
		if s != "" {
			n++
		}
	}
	return n
}

func (r *Round) evaluatorIndex(a address) int {
	for i, e := range r.Evaluators {
		if e == a {
			return i
		}
	}
	return -1
}

// PhaseOf derives the phase of r at height h.
func PhaseOf(r *Round, h int64) Phase {
	switch {
	case r.Finalized && r.Cancelled:
		return PhaseCancelled
	case r.Finalized:
		return PhaseDone
	case h <= r.HJoin:
		return PhaseJoin
	case r.Rule == nil:
		if h <= r.HRule {
			return PhaseRule
		}
		return PhaseAwaitingFinalize
	case r.Apps == nil:
		if h <= r.HReveal {
			return PhaseReveal
		}
		return PhaseAwaitingFinalize
	case h <= r.HScore:
		return PhaseScore
	case h <= r.HSheetReveal:
		return PhaseSheetReveal
	}
	return PhaseAwaitingFinalize
}

// exactUgnot returns the ugnot attached to a direct user call, rejecting any
// other denomination and any non-user-call caller (see effective-gno:
// verifying inbound coin payments).
func exactUgnot(cur realm) int64 {
	if !cur.Previous().IsUserCall() {
		panic("grantround: only direct user calls may attach coins")
	}
	sent := unsafe.OriginSend()
	for _, c := range sent {
		if c.Denom != "ugnot" && c.Amount != 0 {
			panic("grantround: only ugnot is accepted")
		}
	}
	return sent.AmountOf("ugnot")
}

// CreateRound opens a round funded by the ugnot sent with the call.
// evaluators is "evaluator:sponsor,..." — only the named sponsor may later
// post the bond for that evaluator. appsHash is
// rulecalc.AppsDigest of the applications to be revealed later.
func CreateRound(cur realm, goal string, appsHash string, evaluators string,
	bond, slash int64, hJoin, hRule, hReveal, hScore, hSheetReveal int64) int {
	grant := exactUgnot(cur)
	if grant <= 0 {
		panic("grantround: the grant must be funded with ugnot")
	}
	if bond <= 0 {
		panic("grantround: bond must be positive")
	}
	if slash < 0 || slash > bond {
		panic("grantround: slash must be between 0 and bond")
	}
	if !(runtime.ChainHeight() < hJoin && hJoin < hRule && hRule < hReveal && hReveal < hScore && hScore < hSheetReveal) {
		panic("grantround: deadlines must be in the future and strictly increasing")
	}
	if !isHexDigest(appsHash) {
		panic("grantround: apps hash must be 64 lowercase hex characters")
	}
	evs, designated, err := parseEvaluators(evaluators)
	if err != nil {
		panic("grantround: " + err.Error())
	}

	counter++
	r := &Round{
		ID:           counter,
		Customer:     cur.Previous().Address(),
		Goal:         goal,
		Grant:        grant,
		AppsHash:     appsHash,
		Evaluators:   evs,
		Designated:   designated,
		Sponsors:     make([]address, len(evs)),
		Votes:        make([]bool, len(evs)),
		Commits:      make([]string, len(evs)),
		Sheets:       make([]*rulecalc.Sheet, len(evs)),
		Bond:         bond,
		Slash:        slash,
		HJoin:        hJoin,
		HRule:        hRule,
		HReveal:      hReveal,
		HScore:       hScore,
		HSheetReveal: hSheetReveal,
	}
	rounds.Set(roundKey(r.ID), r)
	return r.ID
}

// Join is called by the evaluator's designated sponsor, attaching exactly the
// bond. It opens empty reputation records for both if they have none.
func Join(cur realm, roundID int, evaluator address) {
	r := mustGet(roundID)
	sent := exactUgnot(cur)
	if PhaseOf(r, runtime.ChainHeight()) != PhaseJoin {
		panic("grantround: join phase is over")
	}
	if sent != r.Bond {
		panic("grantround: attach exactly the bond of " + strconv.FormatInt(r.Bond, 10) + "ugnot")
	}
	i := r.evaluatorIndex(evaluator)
	if i < 0 {
		panic("grantround: not an evaluator of this round")
	}
	caller := cur.Previous().Address()
	if caller != r.Designated[i] {
		panic("grantround: only the designated sponsor can join this evaluator")
	}
	if r.Sponsors[i] != "" {
		panic("grantround: evaluator already joined")
	}
	r.Sponsors[i] = caller
	openTrack(evaluator)
	openTrack(caller)
}

// minSaltLen is the shortest salt accepted when a commitment is opened. Length
// is all the realm can check; `openssl rand -hex 32` gives 64 characters.
const minSaltLen = 32

func mustLongSalt(salt string) {
	if len(salt) < minSaltLen {
		panic("grantround: salt too short")
	}
}

func isHexDigest(s string) bool {
	if len(s) != 64 {
		return false
	}
	for _, c := range s {
		if !(c >= '0' && c <= '9' || c >= 'a' && c <= 'f') {
			return false
		}
	}
	return true
}
