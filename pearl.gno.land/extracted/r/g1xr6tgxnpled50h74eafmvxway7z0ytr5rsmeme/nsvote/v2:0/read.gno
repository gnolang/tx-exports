package nsvote

import (
	"strings"

	"gno.land/p/nt/ufmt/v0"
	"gno.land/r/g1xr6tgxnpled50h74eafmvxway7z0ytr5rsmeme/nsdata/v2"
)

// Everything a caller needs about one request, on one line. Fields are
// separated by "|" rather than "," because a reason may well contain a
// comma; it may not contain "|" or a newline, which Propose enforces.
func row(id int64, p *Proposal) string {
	kind := p.kind
	if kind == "" {
		kind = "domain" // anything written before kinds existed
	}
	return ufmt.Sprintf("%d|%s|%s|%s|%s|%d|%d|%d|%s|%d",
		id, kind, p.label, p.proposer.String(), p.reason,
		p.created, p.yes, p.no, p.status, p.decided)
}

// ListProposals pages newest first, which is the order anybody actually
// wants to read them in.
func ListProposals(after string, limit int) (rows, next string) {
	if limit <= 0 || limit > maxPage {
		limit = maxPage
	}
	var keys []string
	proposals.Iterate("", "", func(k string, _ any) bool {
		keys = append(keys, k)
		return false
	})

	var b strings.Builder
	n := 0
	last := ""
	started := after == ""
	// Walk backwards for newest-first; `after` is the last key returned.
	for i := len(keys) - 1; i >= 0; i-- {
		k := keys[i]
		if !started {
			if k == after {
				started = true
			}
			continue
		}
		if n >= limit {
			return b.String(), last
		}
		v := proposals.Get(k)
		if v == nil {
			continue
		}
		if b.Len() > 0 {
			b.WriteString("\n")
		}
		p := v.(*Proposal)
		b.WriteString(row(parseKey(k), p))
		last = k
		n++
	}
	return b.String(), ""
}

func parseKey(k string) int64 {
	var out int64
	for i := 0; i < len(k); i++ {
		if k[i] < '0' || k[i] > '9' {
			return 0
		}
		out = out*10 + int64(k[i]-'0')
	}
	return out
}

func GetProposal(id int64) string {
	v := proposals.Get(key(id))
	if v == nil {
		return ""
	}
	return row(id, v.(*Proposal))
}

func CountProposals() int64 { return int64(proposals.Size()) }

// HasVoted lets the page grey out a button instead of letting somebody
// sign a transaction that is certain to be rejected.
func HasVoted(id int64, voter address) string {
	v := votes.Get(voteKey(id, voter))
	if v == nil {
		return ""
	}
	return v.(string)
}

// CanTakePart answers the one question the page needs before it offers
// any of this: does this address hold a name.
func CanTakePart(who address) bool { return nsdata.BalanceOf(who) > 0 }

// Roster is the raw material for the leaderboards: one line per name,
// owner first, so the caller can aggregate however it likes.
//
// It lives here rather than in nslogic because this realm is being
// deployed anyway and nslogic is not — adding it there would have cost
// a fresh deployment of the largest realm we have, for a read.
//
// Paged, and the page walks every name in it. That is fine at the scale
// this registry is at and it will not be fine at fifty thousand names;
// at that point the aggregate belongs somewhere it is kept as it
// changes rather than recomputed on every read.
func Roster(after string, limit int) (rows, next string) {
	if limit <= 0 || limit > maxPage {
		limit = maxPage
	}
	keys, nxt := nsdata.ExportNames("", after, limit)

	var b strings.Builder
	for _, k := range strings.Split(keys, ",") {
		if k == "" {
			continue
		}
		at := strings.Index(k, "*")
		if at < 0 {
			continue
		}
		domainLabel, label := k[:at], k[at+1:]
		owner, registered, expires, streak, frozen, _ := nsdata.GetNameInfo(label, domainLabel)
		if b.Len() > 0 {
			b.WriteString("\n")
		}
		b.WriteString(ufmt.Sprintf("%s|%s*%s|%d|%d|%d|%t",
			owner.String(), label, domainLabel, registered, expires, streak, frozen))
	}
	return b.String(), nxt
}

// Version lets a caller find out what it is talking to BEFORE it sends a
// transaction that would be rejected for having the wrong number of
// arguments.
//
// v1 has no such function, so a nil answer is itself the answer: an
// older realm. That is cheaper and more honest than the site assuming
// the newest shape and failing at signing time, which is exactly what
// happened when Propose grew a `kind`.
func Version() string { return "v2" }
