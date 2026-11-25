// Package sealedpoll runs sealed polls: anyone opens a question with 2 to 8 options, voters
// seal a choice (only its hash goes on chain), then open it in the reveal window. The tally
// counts opened votes only, and the realm reports how many sealed votes were never opened.
//
// It is a second realm built on the commitreveal package: the session handles the windows,
// one vote per address, reveal checks and who never opened. This realm holds no coins.
package sealedpoll

import (
	"chain/runtime/unsafe"
	"strconv"
	"strings"
	"time"
	"unicode/utf8"

	"gno.land/p/g1vxsg6ht4nklaud70yaszcgkhc9ttancr9nlzzq/commitreveal/v0"
	"gno.land/p/nt/avl/v0"
)

const (
	maxOptions     = 8
	maxQuestionLen = 140
	maxOptionLen   = 40
	minWindow      = int64(60)     // 1 minute
	maxWindow      = int64(604800) // 7 days
	minSaltLen     = 16            // shorter salts let anyone guess a vote from its hash
	pageSize       = 10            // polls per Render page
)

type Poll struct {
	ID       int
	Creator  address
	Question string
	Options  []string
	Seal     *commitreveal.Session
}

var (
	polls     = avl.NewTree() // pollKey(id) -> *Poll
	pollCount int
)

// pollKey pads poll IDs so the tree keeps them in numeric order.
func pollKey(id int) string {
	s := strconv.Itoa(id)
	for len(s) < 10 {
		s = "0" + s
	}
	return s
}

// mustUser returns the caller, who must be a wallet calling directly (not another realm or a script).
func mustUser(cur realm) address {
	if !cur.Previous().IsUserCall() {
		panic("direct user call required")
	}
	return cur.Previous().Address()
}

// nowOverride lets tests control time; zero means use the block time.
var nowOverride int64

func now() int64 {
	if nowOverride != 0 {
		return nowOverride
	}
	return time.Now().Unix()
}

// NewPoll opens a poll. options is a comma-separated list of 2 to 8 distinct choices (no ':', which
// separates the option from the salt in a vote's hash); commitSecs and revealSecs are the voting and
// opening windows in seconds, each 1 minute to 7 days.
func NewPoll(cur realm, question, options string, commitSecs, revealSecs int64) int {
	creator := mustUser(cur)
	if commitSecs < minWindow || revealSecs < minWindow || commitSecs > maxWindow || revealSecs > maxWindow {
		panic("windows must be 1 minute to 7 days")
	}
	question = strings.TrimSpace(question)
	if question == "" || len(question) > maxQuestionLen || !printable(question) {
		panic("question must be 1 to 140 printable characters")
	}
	var opts []string
	for _, o := range strings.Split(options, ",") {
		o = strings.TrimSpace(o)
		if o == "" || len(o) > maxOptionLen || !printable(o) || strings.Contains(o, ":") {
			panic("each option must be 1 to 40 printable characters, without ':'")
		}
		for _, seen := range opts {
			if seen == o {
				panic("options must be different")
			}
		}
		opts = append(opts, o)
	}
	if len(opts) < 2 || len(opts) > maxOptions {
		panic("a poll needs 2 to 8 options")
	}
	p := &Poll{
		ID:       pollCount,
		Creator:  creator,
		Question: question,
		Options:  opts,
		Seal:     commitreveal.New(now(), commitSecs, revealSecs),
	}
	polls.Set(pollKey(p.ID), p)
	pollCount++
	return p.ID
}

// Vote seals a choice: hash is commitreveal.Hash(option, salt), computed by the voter's client.
func Vote(cur realm, id int, hash string) {
	voter := mustUser(cur)
	p := getPoll(id)
	if err := p.Seal.Commit(now(), voter, hash); err != nil {
		panic(voteError(err))
	}
}

// Open reveals a sealed vote with its option and salt during the opening window. The salt must be
// at least 16 characters; voters' clients should use a random one.
func Open(cur realm, id int, option, salt string) {
	voter := mustUser(cur)
	p := getPoll(id)
	if !p.hasOption(option) {
		panic("unknown option")
	}
	if len(salt) < minSaltLen {
		panic("salt must be at least 16 characters")
	}
	if err := p.Seal.Reveal(now(), voter, option, salt); err != nil {
		panic(voteError(err))
	}
}

// PollCount is the number of polls.
func PollCount() int { return pollCount }

// Tally returns a poll's state as JSON: phase (vote, open or closed), sealed votes, opened votes,
// counts per option in option order, and votes sealed but never opened.
func Tally(id int) string {
	p := getPoll(id)
	counts := p.counts()
	opened := p.Seal.Revealed()
	var sb strings.Builder
	sb.WriteString(`{"id":` + strconv.Itoa(p.ID) + `,"question":` + strconv.Quote(p.Question))
	sb.WriteString(`,"phase":"` + phaseName(p.Seal.Phase(now())) + `","votes":` + strconv.Itoa(p.Seal.Count()))
	sb.WriteString(`,"opened":` + strconv.Itoa(len(opened)) + `,"counts":{`)
	for i, o := range p.Options {
		if i > 0 {
			sb.WriteString(",")
		}
		sb.WriteString(strconv.Quote(o) + ":" + strconv.Itoa(counts[i]))
	}
	sb.WriteString(`},"unopened":` + strconv.Itoa(p.Seal.Count()-len(opened)) + "}")
	return sb.String()
}

// Render lists polls newest first, 10 per page ("" is page 1, "page/2" the next); counts appear
// once votes start opening. Poll text is escaped, so it cannot add links or headings to the page.
func Render(path string) string {
	page := 1
	if strings.HasPrefix(path, "page/") {
		n, err := strconv.Atoi(strings.TrimPrefix(path, "page/"))
		if err != nil || n < 1 {
			return "# Not found\n"
		}
		page = n
	}
	var sb strings.Builder
	sb.WriteString("# Sealed polls\n\nVotes stay sealed until their owners open them. Built on commitreveal.\n\n")
	if pollCount == 0 {
		sb.WriteString("No polls yet.\n")
		return sb.String()
	}
	t := now()
	first := pollCount - 1 - (page-1)*pageSize
	for i := first; i >= 0 && i > first-pageSize; i-- {
		p := getPoll(i)
		phase := p.Seal.Phase(t)
		opened := len(p.Seal.Revealed())
		sb.WriteString("## " + strconv.Itoa(p.ID) + ". " + escape(p.Question) + "\n\n")
		switch phase {
		case commitreveal.CommitPhase:
			sb.WriteString("Voting is open: " + strconv.Itoa(p.Seal.Count()) + " sealed votes. Options: " + escape(strings.Join(p.Options, ", ")) + ".\n\n")
			continue
		case commitreveal.RevealPhase:
			sb.WriteString("Opening votes: " + strconv.Itoa(opened) + " of " + strconv.Itoa(p.Seal.Count()) + " opened so far.\n\n")
		default:
			sb.WriteString("Closed: " + strconv.Itoa(p.Seal.Count()) + " sealed votes, " + strconv.Itoa(opened) + " opened.\n\n")
		}
		for j, c := range p.counts() {
			sb.WriteString("- " + escape(p.Options[j]) + ": " + strconv.Itoa(c) + "\n")
		}
		if phase == commitreveal.ClosedPhase {
			if n := p.Seal.Count() - opened; n > 0 {
				noun := "votes"
				if n == 1 {
					noun = "vote"
				}
				sb.WriteString("\n" + strconv.Itoa(n) + " sealed " + noun + " never opened.\n")
			}
		}
		sb.WriteString("\n")
	}
	if first < 0 {
		sb.WriteString("No polls on this page.\n")
	}
	if first-pageSize >= 0 {
		sb.WriteString("[Older polls](" + link("page/"+strconv.Itoa(page+1)) + ")\n")
	}
	return sb.String()
}

// link points at a page of this realm in gnoweb.
func link(sub string) string {
	return "/" + strings.TrimPrefix(unsafe.CurrentRealm().PkgPath(), "gno.land/") + ":" + sub
}

// escape backslash-escapes markdown punctuation so user text shows as typed.
func escape(s string) string {
	var sb strings.Builder
	for _, r := range s {
		if strings.ContainsRune("\\`*_{}[]()<>#+-.!|~", r) {
			sb.WriteByte('\\')
		}
		sb.WriteRune(r)
	}
	return sb.String()
}

func getPoll(id int) *Poll {
	if id < 0 || id >= pollCount {
		panic("unknown poll")
	}
	return polls.Get(pollKey(id)).(*Poll)
}

func (p *Poll) hasOption(o string) bool {
	for _, x := range p.Options {
		if x == o {
			return true
		}
	}
	return false
}

// counts returns opened votes per option, in option order.
func (p *Poll) counts() []int {
	counts := make([]int, len(p.Options))
	for _, o := range p.Seal.Revealed() {
		for i, x := range p.Options {
			if x == o.Value {
				counts[i]++
			}
		}
	}
	return counts
}

// voteError words the session's errors for voters.
func voteError(err error) string {
	switch err {
	case commitreveal.ErrCommitClosed:
		return "voting is closed"
	case commitreveal.ErrAlreadyCommitted:
		return "already voted"
	case commitreveal.ErrNotCommitted:
		return "you did not vote in this poll"
	case commitreveal.ErrAlreadyRevealed:
		return "already opened"
	}
	return err.Error()
}

func phaseName(ph commitreveal.Phase) string {
	switch ph {
	case commitreveal.CommitPhase:
		return "vote"
	case commitreveal.RevealPhase:
		return "open"
	}
	return "closed"
}

// printable rejects invalid UTF-8 and control characters, so Tally's JSON stays valid.
func printable(s string) bool {
	if !utf8.ValidString(s) {
		return false
	}
	for _, r := range s {
		if r < 0x20 || r == 0x7f {
			return false
		}
	}
	return true
}
