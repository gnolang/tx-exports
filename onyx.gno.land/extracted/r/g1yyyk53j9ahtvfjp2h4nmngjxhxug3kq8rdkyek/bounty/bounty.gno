// Bounty is a simple on-chain bounty board realm: anyone can post a bounty,
// another address can claim it, and only the creator can mark it done.
// Submission for Gnome Tavern Hackathon | Gno.land.
package bounty

import (
	"errors"
	"strconv"

	"gno.land/p/nt/markdown/sanitize/v0"
)

// Status is the lifecycle state of a bounty.
type Status int

const (
	StatusOpen Status = iota
	StatusClaimed
	StatusDone
)

func (s Status) String() string {
	switch s {
	case StatusOpen:
		return "open"
	case StatusClaimed:
		return "claimed"
	case StatusDone:
		return "done"
	default:
		return "unknown"
	}
}

type bounty struct {
	id          int
	creator     address
	claimer     address
	title       string
	description string
	reward      string
	status      Status
}

var bounties []bounty

// PostBounty creates a new open bounty and returns its id.
// The reward is informational (e.g. "100ugnot"); no tokens are escrowed
// by this realm version — the on-chain record tracks who claimed it and
// whether the creator marked it done.
func PostBounty(cur realm, title, description, reward string) (int, error) {
	if title == "" {
		return -1, errors.New("title must not be empty")
	}
	if reward == "" {
		return -1, errors.New("reward must not be empty")
	}
	id := len(bounties)
	bounties = append(bounties, bounty{
		id:          id,
		creator:     cur.Previous().Address(),
		title:       title,
		description: description,
		reward:      reward,
		status:      StatusOpen,
	})
	return id, nil
}

// ClaimBounty lets an address claim an open bounty. The creator cannot
// claim their own bounty, and a bounty can only be claimed once.
func ClaimBounty(cur realm, id int) error {
	if id < 0 || id >= len(bounties) {
		return errors.New("bounty not found")
	}
	b := &bounties[id]
	if b.status != StatusOpen {
		return errors.New("bounty is not open")
	}
	caller := cur.Previous().Address()
	if caller == b.creator {
		return errors.New("creator cannot claim their own bounty")
	}
	b.claimer = caller
	b.status = StatusClaimed
	return nil
}

// CompleteBounty marks a claimed bounty as done. Only the bounty creator
// can do this, and only after someone has claimed it.
func CompleteBounty(cur realm, id int) error {
	if id < 0 || id >= len(bounties) {
		return errors.New("bounty not found")
	}
	b := &bounties[id]
	if cur.Previous().Address() != b.creator {
		return errors.New("only the creator can complete this bounty")
	}
	if b.status != StatusClaimed {
		return errors.New("bounty must be claimed before it can be completed")
	}
	b.status = StatusDone
	return nil
}

// BountyCount returns how many bounties have been posted.
func BountyCount() int {
	return len(bounties)
}

// GetBounty returns a human-readable summary of one bounty.
func GetBounty(id int) (string, error) {
	if id < 0 || id >= len(bounties) {
		return "", errors.New("bounty not found")
	}
	b := bounties[id]
	return formatBounty(b), nil
}

// ListBounties returns a one-line-per-bounty summary of all bounties.
func ListBounties() string {
	if len(bounties) == 0 {
		return "No bounties posted yet."
	}
	out := ""
	for _, b := range bounties {
		out += "#" + strconv.Itoa(b.id) + " [" + b.status.String() + "] " +
			sanitize.InlineText(b.title) + " — " + sanitize.InlineText(b.reward) + "\n"
	}
	return out
}

// Render shows the bounty board as markdown. User-supplied title and
// description are sanitized so they cannot break out of their markdown slot.
func Render(path string) string {
	open, claimed, done := 0, 0, 0
	for _, b := range bounties {
		switch b.status {
		case StatusOpen:
			open++
		case StatusClaimed:
			claimed++
		case StatusDone:
			done++
		}
	}
	out := "# Bounty Board\n\n"
	out += strconv.Itoa(len(bounties)) + " bount(y/ies): " +
		strconv.Itoa(open) + " open, " +
		strconv.Itoa(claimed) + " claimed, " +
		strconv.Itoa(done) + " done.\n\n"
	for _, b := range bounties {
		out += "## #" + strconv.Itoa(b.id) + " " + sanitize.InlineText(b.title) +
			" [" + b.status.String() + "]\n\n"
		out += formatBounty(b) + "\n\n"
	}
	return out
}

func formatBounty(b bounty) string {
	out := "Title: " + sanitize.InlineText(b.title) + "\n"
	if b.description != "" {
		out += "Description: " + sanitize.InlineText(b.description) + "\n"
	}
	out += "Reward: " + sanitize.InlineText(b.reward) + "\n"
	out += "Creator: " + b.creator.String() + "\n"
	if b.status != StatusOpen {
		out += "Claimer: " + b.claimer.String() + "\n"
	}
	out += "Status: " + b.status.String()
	return out
}
