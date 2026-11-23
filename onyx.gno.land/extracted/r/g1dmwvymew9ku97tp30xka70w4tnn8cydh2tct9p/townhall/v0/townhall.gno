// Package townhall is a demo Barkeep realm that is both a consumer and a
// source: creating a poll requires renown, and every vote attests the voter
// in the governance category.
package townhall

import (
	"chain/runtime"
	"strconv"
	"strings"

	"gno.land/p/nt/avl/v0"
	"gno.land/p/nt/markdown/sanitize/v0"
	"gno.land/r/g1dmwvymew9ku97tp30xka70w4tnn8cydh2tct9p/barkeep/v0"
)

const (
	// MinScoreToCreatePoll is the Barkeep score (whole points) a caller
	// needs to open a poll. Voting is open to everyone.
	MinScoreToCreatePoll int64 = 20

	MaxQuestionLen = 140
	MaxOptionLen   = 40
	MinOptions     = 2
	MaxOptions     = 5
	OptionSep      = "|"
	PageSize       = 10
)

type poll struct {
	id       int
	author   address
	question string
	options  []string
	votes    []int64
	voters   *avl.Tree // address -> option index
	height   int64
}

var (
	polls  = avl.NewTree() // padded id -> *poll
	nextID = 1
)

func init(cur realm) {
	barkeep.RegisterSource(cross(cur), "governance", "Town hall polls: one attestation per vote")
}

// CreatePoll opens a poll. options is a "|"-separated list of 2 to 5
// choices, so the function stays callable from gnokey. It panics when the
// caller lacks renown or the input is invalid.
func CreatePoll(cur realm, question, options string) int {
	caller := cur.Previous().Address()
	if !barkeep.HasMinScore(caller, MinScoreToCreatePoll) {
		panic("townhall: need a Barkeep score of at least " + strconv.FormatInt(MinScoreToCreatePoll, 10))
	}
	question = strings.TrimSpace(question)
	if !validText(question, MaxQuestionLen) {
		panic("townhall: question must be 1-140 printable ASCII characters")
	}
	opts := strings.Split(options, OptionSep)
	if len(opts) < MinOptions || len(opts) > MaxOptions {
		panic("townhall: a poll needs 2 to 5 options separated by |")
	}
	for i, o := range opts {
		opts[i] = strings.TrimSpace(o)
		if !validText(opts[i], MaxOptionLen) {
			panic("townhall: each option must be 1-40 printable ASCII characters")
		}
	}
	id := nextID
	nextID++
	polls.Set(key(id), &poll{
		id:       id,
		author:   caller,
		question: question,
		options:  opts,
		votes:    make([]int64, len(opts)),
		voters:   avl.NewTree(),
		height:   runtime.ChainHeight(),
	})
	return id
}

// Vote records one vote per address per poll and attests the voter in
// Barkeep. It returns whether Barkeep accepted the attestation; the vote
// counts either way. It panics on an unknown poll, a bad option or a
// second vote.
func Vote(cur realm, pollID, option int) bool {
	voter := cur.Previous().Address()
	p := getPoll(pollID)
	if p == nil {
		panic("townhall: unknown poll")
	}
	if option < 0 || option >= len(p.options) {
		panic("townhall: option out of range")
	}
	if p.voters.Has(voter.String()) {
		panic("townhall: already voted")
	}
	p.voters.Set(voter.String(), option)
	p.votes[option]++
	return barkeep.Attest(cross(cur), voter, "vote.cast", 1)
}

// PollCount returns how many polls exist.
func PollCount() int { return polls.Size() }

// VotesOf returns the tally of one option, or -1 when it does not exist.
func VotesOf(pollID, option int) int64 {
	p := getPoll(pollID)
	if p == nil || option < 0 || option >= len(p.options) {
		return -1
	}
	return p.votes[option]
}

// HasVoted reports whether addr voted in a poll.
func HasVoted(pollID int, addr address) bool {
	p := getPoll(pollID)
	return p != nil && p.voters.Has(addr.String())
}

// Render serves "" (polls, newest first, "?page=N") and "poll/<id>".
func Render(path string) string {
	route, query, _ := strings.Cut(path, "?")
	if rest, ok := strings.CutPrefix(route, "poll/"); ok {
		id, err := strconv.Atoi(rest)
		if err != nil {
			return notFound()
		}
		p := getPoll(id)
		if p == nil {
			return notFound()
		}
		return renderPoll(p)
	}
	if route != "" {
		return notFound()
	}
	return renderList(pageParam(query))
}

func renderList(pg int) string {
	var b strings.Builder
	b.WriteString("# Town Hall\n\nPolls by patrons of the tavern. Opening a poll needs a [Barkeep](/r/g1dmwvymew9ku97tp30xka70w4tnn8cydh2tct9p/barkeep/v0) score of ")
	b.WriteString(strconv.FormatInt(MinScoreToCreatePoll, 10))
	b.WriteString("; every vote earns governance renown.\n\n")
	total := polls.Size()
	if total == 0 {
		b.WriteString("_No polls yet._\n")
		return b.String()
	}
	pages := (total + PageSize - 1) / PageSize
	if pg > pages {
		pg = pages
	}
	b.WriteString("| # | Question | Votes |\n|---|---|---|\n")
	// Newest first: index total-1 is the latest poll.
	start := total - pg*PageSize
	count := PageSize
	if start < 0 {
		count += start
		start = 0
	}
	rows := make([]*poll, 0, count)
	polls.IterateByOffset(start, count, func(_ string, v any) bool {
		rows = append(rows, v.(*poll))
		return false
	})
	for i := len(rows) - 1; i >= 0; i-- {
		p := rows[i]
		id := strconv.Itoa(p.id)
		b.WriteString("| [" + id + "](:poll/" + id + ") | " + sanitize.TableCell(p.question) + " | " + strconv.FormatInt(int64(p.voters.Size()), 10) + " |\n")
	}
	if pages > 1 {
		b.WriteString("\nPage " + strconv.Itoa(pg) + " of " + strconv.Itoa(pages))
		if pg > 1 {
			b.WriteString(" · [Newer](:?page=" + strconv.Itoa(pg-1) + ")")
		}
		if pg < pages {
			b.WriteString(" · [Older](:?page=" + strconv.Itoa(pg+1) + ")")
		}
		b.WriteString("\n")
	}
	return b.String()
}

func renderPoll(p *poll) string {
	var b strings.Builder
	b.WriteString("# Poll " + strconv.Itoa(p.id) + "\n\n")
	b.WriteString("**" + sanitize.InlineText(p.question) + "**\n\n")
	b.WriteString("Opened by [" + p.author.String() + "](/r/g1dmwvymew9ku97tp30xka70w4tnn8cydh2tct9p/barkeep/v0:u/" + p.author.String() + ") at block " + strconv.FormatInt(p.height, 10) + "\n\n")
	b.WriteString("| # | Option | Votes |\n|---|---|---|\n")
	for i, o := range p.options {
		b.WriteString("| " + strconv.Itoa(i) + " | " + sanitize.TableCell(o) + " | " + strconv.FormatInt(p.votes[i], 10) + " |\n")
	}
	b.WriteString("\n[All polls](:)\n")
	return b.String()
}

func notFound() string { return "# Not found\n\n[All polls](:)\n" }

func getPoll(id int) *poll {
	if id < 1 || id >= nextID {
		return nil
	}
	v := polls.Get(key(id))
	if v == nil {
		return nil
	}
	return v.(*poll)
}

// key zero-pads ids so the tree iterates in creation order.
func key(id int) string {
	s := strconv.Itoa(id)
	for len(s) < 10 {
		s = "0" + s
	}
	return s
}

func pageParam(query string) int {
	for _, kv := range strings.Split(query, "&") {
		if v, ok := strings.CutPrefix(kv, "page="); ok {
			if n, err := strconv.Atoi(v); err == nil && n > 0 && n < 1_000_000 {
				return n
			}
		}
	}
	return 1
}

// validText accepts 1..max printable ASCII characters.
func validText(s string, max int) bool {
	if len(s) == 0 || len(s) > max {
		return false
	}
	for i := 0; i < len(s); i++ {
		if s[i] < 0x20 || s[i] > 0x7e {
			return false
		}
	}
	return true
}
