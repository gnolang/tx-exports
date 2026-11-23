// Tavern Poll — chain-on-chain voting realm
// Path: gno.land/r/g1rkauqxnulyry8h4p7epqmxr3a744gg4hchhvz2/tavernpoll
package tavernpoll

import (
	"sort"
	"strconv"
	"strings"
)

type PollOption struct {
	Option string
	Votes  int
}

type pollOptSorter []PollOption
func (s pollOptSorter) Len() int           { return len(s) }
func (s pollOptSorter) Less(i, j int) bool { return s[i].Votes > s[j].Votes }
func (s pollOptSorter) Swap(i, j int)      { s[i], s[j] = s[j], s[i] }

type Poll struct {
	ID        string
	Question  string
	Options   []PollOption
	Voters    []string
	Creator   string
	CreatedAt string
	Active    bool
}

var (
	polls []Poll
	seq   int
)

func findIdx(id string) int {
	for i := range polls {
		if polls[i].ID == id {
			return i
		}
	}
	return -1
}

// CreatePoll(cur realm, question, opts) string — opts is comma-separated
func CreatePoll(cur realm, question string, opts string) string {
	if question == "" {
		return "error: empty question"
	}
	raw := strings.Split(opts, ",")
	if len(raw) < 2 {
		return "error: need 2+ comma-separated options"
	}
	seq++
	id := "poll_" + strconv.Itoa(seq)
	options := make([]PollOption, 0, len(raw))
	for _, o := range raw {
		t := strings.TrimSpace(o)
		if t != "" {
			options = append(options, PollOption{Option: t, Votes: 0})
		}
	}
	if len(options) < 2 {
		return "error: need 2+ non-empty options"
	}
	creator := string(cur.Address())
	polls = append(polls, Poll{
		ID: id, Question: question, Options: options,
		Voters: nil, Creator: creator, CreatedAt: "block #0", Active: true,
	})
	return id
}

// Vote(cur realm, pollID, optionIndex) string
func Vote(cur realm, pollID string, optionIndex int) string {
	idx := findIdx(pollID)
	if idx < 0 {
		return "error: poll not found: " + pollID
	}
	if !polls[idx].Active {
		return "error: poll closed"
	}
	if optionIndex < 0 || optionIndex >= len(polls[idx].Options) {
		return "error: bad option index"
	}
	voter := string(cur.Address())
	for _, v := range polls[idx].Voters {
		if v == voter {
			return "error: already voted"
		}
	}
	polls[idx].Options[optionIndex].Votes++
	polls[idx].Voters = append(polls[idx].Voters, voter)
	return "voted!"
}

// ClosePoll(cur realm, pollID) string
func ClosePoll(cur realm, pollID string) string {
	idx := findIdx(pollID)
	if idx < 0 {
		return "error: poll not found"
	}
	if polls[idx].Creator != string(cur.Address()) {
		return "error: not creator"
	}
	polls[idx].Active = false
	return "closed: " + pollID
}

// GetPollJSON(pollID) string — hand-written JSON, because Gno stdlib 1.8.0 has no encoding/json
func GetPollJSON(pollID string) string {
	idx := findIdx(pollID)
	if idx < 0 {
		return "{\"error\":\"poll not found\"}"
	}
	p := &polls[idx]
	var sb strings.Builder
	sb.WriteString("{\"id\":\"")
	sb.WriteString(p.ID)
	sb.WriteString("\",\"question\":\"")
	sb.WriteString(p.Question)
	sb.WriteString("\",\"creator\":\"")
	sb.WriteString(p.Creator)
	sb.WriteString("\",\"active\":")
	sb.WriteString(strconv.FormatBool(p.Active))
	sb.WriteString(",\"options\":[")
	for i, o := range p.Options {
		if i > 0 {
			sb.WriteString(",")
		}
		sb.WriteString("{\"option\":\"")
		sb.WriteString(o.Option)
		sb.WriteString("\",\"votes\":")
		sb.WriteString(strconv.Itoa(o.Votes))
		sb.WriteString("}")
	}
	sb.WriteString("]}")
	return sb.String()
}

// ListPollsJSON() string
func ListPollsJSON() string {
	var sb strings.Builder
	sb.WriteString("[")
	first := true
	for i := range polls {
		if !first {
			sb.WriteString(",")
		}
		first = false
		p := &polls[i]
		sb.WriteString("{\"id\":\"")
		sb.WriteString(p.ID)
		sb.WriteString("\",\"question\":\"")
		sb.WriteString(p.Question)
		sb.WriteString("\",\"creator\":\"")
		sb.WriteString(p.Creator)
		sb.WriteString("\",\"active\":")
		sb.WriteString(strconv.FormatBool(p.Active))
		sb.WriteString(",\"options\":[")
		for j, o := range p.Options {
			if j > 0 {
				sb.WriteString(",")
			}
			sb.WriteString("{\"option\":\"")
			sb.WriteString(o.Option)
			sb.WriteString("\",\"votes\":")
			sb.WriteString(strconv.Itoa(o.Votes))
			sb.WriteString("}")
		}
		sb.WriteString("]}")
	}
	sb.WriteString("]")
	return sb.String()
}

// GetPoll(pollID) string — plain text
func GetPoll(pollID string) string {
	idx := findIdx(pollID)
	if idx < 0 {
		return "not found"
	}
	p := &polls[idx]
	var sb strings.Builder
	sb.WriteString(p.ID)
	sb.WriteString(": ")
	sb.WriteString(p.Question)
	sb.WriteString(" [")
	sb.WriteString(p.Creator)
	sb.WriteString("]")
	return sb.String()
}

// ListPolls() string — plain text
func ListPolls() string {
	if len(polls) == 0 {
		return "No polls yet."
	}
	var sb strings.Builder
	for _, p := range polls {
		sb.WriteString("[")
		sb.WriteString(p.ID)
		sb.WriteString("] ")
		sb.WriteString(p.Question)
		sb.WriteString("\n")
	}
	return sb.String()
}

// Render(path) string — gnoweb
func Render(path string) string {
	var sb strings.Builder
	sb.WriteString("<!doctype html><html><head><title>Tavern Poll</title></head><body>")
	sb.WriteString("<h1>🍺 Tavern Poll</h1>")
	sb.WriteString("<p>On-chain voting at the Gnome Tavern.</p>")
	if len(polls) == 0 {
		sb.WriteString("<p>No polls yet.</p>")
	} else {
		sb.WriteString("<ul>")
		for _, p := range polls {
			sorted := make([]PollOption, len(p.Options))
			copy(sorted, p.Options)
			sort.Sort(pollOptSorter(sorted))
			status := "open"
			if !p.Active {
				status = "closed"
			}
			sb.WriteString("<li><b>")
			sb.WriteString(p.Question)
			sb.WriteString("</b> (")
			sb.WriteString(status)
			sb.WriteString(") by ")
			sb.WriteString(p.Creator)
			sb.WriteString("<ul>")
			for _, o := range sorted {
				sb.WriteString("<li>")
				sb.WriteString(o.Option)
				sb.WriteString(" - ")
				sb.WriteString(strconv.Itoa(o.Votes))
				sb.WriteString("</li>")
			}
			sb.WriteString("</ul></li>")
		}
		sb.WriteString("</ul>")
	}
	sb.WriteString("</body></html>")
	return sb.String()
}
