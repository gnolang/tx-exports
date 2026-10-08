package memba_gov

import (
	"strconv"
	"time"
)

// Reads make no cross-realm call and never start or advance a clock. Ids and
// unix times are JSON strings (clients parse them as big integers). Stored
// text is printable ASCII, so the escapers work byte by byte.

// MaxListed is the most proposals ProposalsJSON and Render return at once.
const MaxListed = 20

// RosterJSON lists seated members and open invitations.
func RosterJSON() string {
	W, N := seatedTotals()
	b := []byte(`{"weight":` + strconv.Itoa(W) + `,"persons":` + strconv.Itoa(N) + `,"members":[`)
	for i, p := range seated {
		if i > 0 {
			b = append(b, ',')
		}
		b = append(b, `{"id":`...)
		b = q(b, p.id)
		b = append(b, `,"address":`...)
		b = q(b, string(p.addr))
		b = append(b, `,"weight":`+strconv.Itoa(p.weight)+`,"lastActive":"`+unix(p.lastActive)+`"}`...)
	}
	b = append(b, `],"invitations":[`...)
	n := 0
	for _, inv := range invites {
		if now() > inv.expires {
			continue
		}
		if n > 0 {
			b = append(b, ',')
		}
		n++
		b = append(b, `{"id":`...)
		b = q(b, inv.id)
		b = append(b, `,"address":`...)
		b = q(b, string(inv.addr))
		b = append(b, `,"weight":`+strconv.Itoa(inv.weight)+`,"expires":"`+unix(inv.expires)+`"}`...)
	}
	return string(append(b, `]}`...))
}

// ProposalJSON returns one proposal with its ballots and current status, or
// null for an unknown id.
func ProposalJSON(pid uint64) string {
	v, ok := proposals.Get(key(pid))
	if !ok {
		return "null"
	}
	return string(proposalJSON(nil, v.(*proposal)))
}

// ConstantsJSON returns the fixed policy: durations in seconds, roster bounds.
func ConstantsJSON() string {
	sec := func(d time.Duration) string { return unix(secs(d)) }
	return `{"votingPeriod":` + sec(VotingPeriod) + `,"executionWindow":` + sec(ExecutionWindow) +
		`,"criticalWeightDelay":` + sec(WeightedDelay) + `,"criticalHeadcountDelay":` + sec(HeadcountDelay) +
		`,"rosterDelay":` + sec(RosterDelay) + `,"inactiveDelay":` + sec(InactiveDelay) +
		`,"inactiveAfter":` + sec(InactiveAfter) + `,"minSeats":` + strconv.Itoa(MinSeats) +
		`,"maxSeats":` + strconv.Itoa(MaxSeats) + `,"maxListed":` + strconv.Itoa(MaxListed) + `}`
}

// ProposalsJSON lists up to limit proposals (at most MaxListed) with ids
// below before, newest first; before = 0 starts from the newest.
func ProposalsJSON(before uint64, limit int) string {
	if limit < 1 || limit > MaxListed {
		limit = MaxListed
	}
	b := []byte(`{"total":"` + strconv.FormatUint(lastID, 10) + `","proposals":[`)
	if before != 1 {
		end := "" // a descending range includes its end
		if before > 1 {
			end = key(before - 1)
		}
		n := 0
		proposals.ReverseIterate("", end, func(_ string, v any) bool {
			if n > 0 {
				b = append(b, ',')
			}
			b = proposalJSON(b, v.(*proposal))
			n++
			return n >= limit
		})
	}
	return string(append(b, `]}`...))
}

func proposalJSON(b []byte, p *proposal) []byte {
	st, readyAt := state(p)
	b = append(b, `{"id":"`+strconv.FormatUint(p.id, 10)+`","target":`...)
	b = q(b, p.target)
	b = append(b, `,"action":`...)
	b = q(b, p.action)
	b = append(b, `,"args":`...)
	b = q(b, p.args)
	b = append(b, `,"scope":`...)
	b = q(b, p.scope)
	b = append(b, `,"class":`+strconv.Itoa(p.class)+`,"proposer":`...)
	b = q(b, p.proposer)
	b = append(b, `,"note":`...)
	b = q(b, p.note)
	b = append(b, `,"created":"`+unix(p.created)+`","deadline":"`+unix(p.created+secs(VotingPeriod))+
		`","status":"`+st+`","readyAt":"`+unix(readyAt)+`","ballots":[`...)
	for i, bl := range p.ballots {
		if i > 0 {
			b = append(b, ',')
		}
		b = append(b, `{"person":`...)
		b = q(b, bl.person)
		b = append(b, `,"vote":"`+bl.vote+`","since":"`+unix(bl.since)+`"}`...)
	}
	return append(b, `]}`...)
}

// Render shows the roster and the latest proposals. Each proposal's line
// holds only fields the realm sets (id, status, class, proposer id); every
// value a proposer wrote follows as its own labelled, escaped item, so none
// can forge a field.
func Render(_ string) string {
	W, N := seatedTotals()
	b := []byte("# Memba DAO governance\n\n## Members: " + strconv.Itoa(N) + " seated, weight " + strconv.Itoa(W) + "\n\n")
	for _, p := range seated {
		b = append(b, "- "...)
		b = md(b, p.id)
		b = append(b, " (weight "+strconv.Itoa(p.weight)+"): "...)
		b = md(b, string(p.addr))
		b = append(b, '\n')
	}
	b = append(b, "\n## Latest proposals\n\n"...)
	n := 0
	proposals.ReverseIterate("", "", func(_ string, v any) bool {
		p := v.(*proposal)
		st, _ := state(p)
		b = append(b, "- #"+strconv.FormatUint(p.id, 10)+" "+st+", class "+strconv.Itoa(p.class)+", by "...)
		b = md(b, p.proposer)
		b = append(b, '\n')
		for _, f := range [][2]string{{"target", p.target}, {"action", p.action}, {"args", p.args}, {"scope", p.scope}, {"proposer's note", p.note}} {
			if f[1] != "" {
				b = append(b, "  - "+f[0]+": "...)
				b = md(b, f[1])
				b = append(b, '\n')
			}
		}
		n++
		return n >= MaxListed
	})
	if n == 0 {
		b = append(b, "None yet.\n"...)
	}
	return string(b)
}

// unix formats a unix-second time (0 = none).
func unix(t int64) string { return strconv.FormatInt(t, 10) }

// grow makes room for n more bytes. The VM's append reallocates to the exact
// length, so appending byte by byte past capacity would copy the whole
// buffer each time; doubling keeps the escapers linear.
func grow(b []byte, n int) []byte {
	if cap(b)-len(b) >= n {
		return b
	}
	nb := make([]byte, len(b), 2*cap(b)+n)
	copy(nb, b)
	return nb
}

// Escaper classes of each ASCII byte, one table lookup per byte: '.' is
// copied, 'b' gets a backslash, 'u' becomes \u00XX, 'e' a numeric
// character reference. Stored text is printable ASCII (0x7f masks the
// index; no other byte reaches here).
const (
	qClass = "uuuuuuuuuuuuuuuuuuuuuuuuuuuuuuuu" +
		"..b...u.....................u.u." +
		"............................b..." +
		"...............................u"
	// Markdown punctuation is backslash-escaped; < > & and g become
	// references, so no HTML, entity or " g1..." address mention (a gnoweb
	// user link) can form.
	mdClass = "eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee" +
		".bbbb.ebbbbb.bbb..........b.ebe." +
		"b..........................bbbbb" +
		"b......e...................bbbbe"
	hexDigits = "0123456789abcdef"
)

// q appends s as a JSON string; < > & are escaped so the text stays inert
// in HTML.
func q(b []byte, s string) []byte {
	b = grow(b, 6*len(s)+2)
	b = append(b, '"')
	for i := 0; i < len(s); i++ {
		switch c := s[i]; qClass[c&0x7f] {
		case '.':
			b = append(b, c)
		case 'b':
			b = append(b, '\\', c)
		default:
			b = append(b, '\\', 'u', '0', '0', hexDigits[c>>4], hexDigits[c&0xf])
		}
	}
	return append(b, '"')
}

// md appends s with every character Markdown, HTML or gnoweb could act on
// made literal.
func md(b []byte, s string) []byte {
	b = grow(b, 6*len(s))
	for i := 0; i < len(s); i++ {
		switch c := s[i]; mdClass[c&0x7f] {
		case '.':
			b = append(b, c)
		case 'b':
			b = append(b, '\\', c)
		default: // &#NN; or &#NNN;
			b = append(b, '&', '#')
			if c >= 100 {
				b = append(b, '0'+c/100)
			}
			b = append(b, '0'+c/10%10, '0'+c%10, ';')
		}
	}
	return b
}
