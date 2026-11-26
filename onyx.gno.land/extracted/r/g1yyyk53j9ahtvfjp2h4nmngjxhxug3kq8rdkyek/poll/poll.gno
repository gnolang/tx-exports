// Package poll is a simple on-chain voting realm: anyone can create a poll,
// each address gets exactly one vote per poll, and only the poll creator
// can close it. Built for the Gnome Tavern Hackathon.
package poll

import (
	"errors"
	"strconv"
	"strings"

	"gno.land/p/nt/markdown/sanitize/v0"
)

// Limits keep on-chain state bounded.
const (
	maxQuestionLen = 200
	maxOptionLen   = 100
	maxOptions     = 10
	minOptions     = 2
)

type poll struct {
	question string
	options  []string
	creator  address
	closed   bool
	votes    []int
	voters   map[address]bool
}

var polls []poll

// CreatePoll creates a new poll and returns its ID. The caller becomes the
// poll creator and is the only one who can close it. Options are given as a
// single "|" separated string (e.g. "Poll|Token|Bounty") because gnokey and
// gnoweb can only pass scalar arguments to realm functions — a []string
// argument cannot be supplied from the CLI.
func CreatePoll(cur realm, question string, options string) (int, error) {
	question = strings.TrimSpace(question)
	if question == "" {
		return -1, errors.New("question must not be empty")
	}
	if len(question) > maxQuestionLen {
		return -1, errors.New("question too long")
	}
	opts := strings.Split(options, "|")
	if len(opts) < minOptions || len(opts) > maxOptions {
		return -1, errors.New("poll needs 2 to 10 options")
	}
	for i, opt := range opts {
		opts[i] = strings.TrimSpace(opt)
		if opts[i] == "" {
			return -1, errors.New("options must not be empty")
		}
		if len(opts[i]) > maxOptionLen {
			return -1, errors.New("option too long")
		}
	}
	creator := cur.Previous().Address()
	p := poll{
		question: question,
		options:  opts,
		creator:  creator,
		votes:    make([]int, len(opts)),
		voters:   make(map[address]bool),
	}
	polls = append(polls, p)
	return len(polls) - 1, nil
}

// Vote casts one vote for an option in a poll. Each address may vote only
// once per poll, and closed polls reject votes.
func Vote(cur realm, pollID int, optionIndex int) error {
	if pollID < 0 || pollID >= len(polls) {
		return errors.New("poll not found")
	}
	p := &polls[pollID]
	if p.closed {
		return errors.New("poll is closed")
	}
	if optionIndex < 0 || optionIndex >= len(p.options) {
		return errors.New("option out of range")
	}
	caller := cur.Previous().Address()
	if p.voters[caller] {
		return errors.New("address has already voted in this poll")
	}
	p.voters[caller] = true
	p.votes[optionIndex]++
	return nil
}

// ClosePoll closes a poll. Only the poll creator may close it.
func ClosePoll(cur realm, pollID int) error {
	if pollID < 0 || pollID >= len(polls) {
		return errors.New("poll not found")
	}
	p := &polls[pollID]
	if p.closed {
		return errors.New("poll is already closed")
	}
	if cur.Previous().Address() != p.creator {
		return errors.New("only the poll creator can close it")
	}
	p.closed = true
	return nil
}

// PollCount returns how many polls exist.
func PollCount() int {
	return len(polls)
}

// Tally returns a copy of the vote counts per option for a poll.
func Tally(pollID int) ([]int, error) {
	if pollID < 0 || pollID >= len(polls) {
		return nil, errors.New("poll not found")
	}
	return append([]int(nil), polls[pollID].votes...), nil
}

// GetPoll returns a poll's question, options, creator and closed status.
func GetPoll(pollID int) (question string, options []string, creator address, closed bool, err error) {
	if pollID < 0 || pollID >= len(polls) {
		return "", nil, address(""), false, errors.New("poll not found")
	}
	p := polls[pollID]
	return p.question, append([]string(nil), p.options...), p.creator, p.closed, nil
}

// Render shows all polls and their current tallies as markdown.
// User-supplied text is escaped so it cannot break out of the markdown.
func Render(_ string) string {
	out := "# Polls\n\n"
	if len(polls) == 0 {
		out += "No polls yet. Create one with CreatePoll.\n"
		return out
	}
	for i, p := range polls {
		status := "open"
		if p.closed {
			status = "closed"
		}
		out += "## " + strconv.Itoa(i+1) + ". " + sanitize.InlineText(p.question) + " (" + status + ")\n\n"
		for j, opt := range p.options {
			out += "- " + sanitize.InlineText(opt) + ": " + strconv.Itoa(p.votes[j]) + " vote(s)\n"
		}
		out += "\n"
	}
	return out
}
