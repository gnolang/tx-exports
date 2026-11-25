package taletree

import (
	"strconv"
	"strings"
	"time"

	"gno.land/p/nt/avl/v0"
	"gno.land/p/nt/seqid/v0"
)

// Limits. They keep every transaction and every Render bounded.
const (
	MaxChoices   = 8    // choices under one passage
	MaxDepth     = 64   // passages from the opening to the deepest page
	MinTitleLen  = 3    // bytes
	MaxTitleLen  = 80   // bytes
	MinChoiceLen = 3    // bytes
	MaxChoiceLen = 80   // bytes
	MinBodyLen   = 20   // bytes
	MaxBodyLen   = 1500 // bytes
	MaxReasonLen = 140  // bytes
)

// Tale is one story: an opening passage and every branch grown from it.
type Tale struct {
	ID        seqid.ID
	Title     string
	Narrator  address // who started it; can hide passages and lock the tale
	Root      seqid.ID
	Passages  int // including the opening
	Endings   int
	Cheers    int
	Locked    bool
	Height    int64
	CreatedAt time.Time
	UpdatedAt time.Time // last passage written
}

// Passage is one page of a tale.
type Passage struct {
	ID           seqid.ID
	Tale         seqid.ID
	Parent       seqid.ID // 0 for the opening
	Author       address
	Choice       string // link text that leads here; empty for the opening
	Body         string
	Depth        int // 0 for the opening
	Children     []seqid.ID
	Cheers       int
	Tips         int64 // ugnot forwarded to the author
	Ending       bool
	Hidden       bool
	HiddenReason string
	Height       int64
	CreatedAt    time.Time
}

// Bard holds the totals of one writer.
type Bard struct {
	Addr     address
	Passages int
	Tales    int   // tales started
	Cheers   int   // cheers received
	Tips     int64 // ugnot received
}

var (
	taleSeq    seqid.ID
	passageSeq seqid.ID

	tales        avl.Tree // tale id (binary) -> *Tale
	passages     avl.Tree // passage id (binary) -> *Passage
	cheers       avl.Tree // passage id (binary) + address -> true
	bards        avl.Tree // address -> *Bard
	bardPassages avl.Tree // address + "/" + passage id (binary) -> seqid.ID
	fame         avl.Tree // fameKey(cheers, address) -> address

	totalTips int64 // ugnot forwarded to authors, all time
	paused    bool
)

func getTale(id seqid.ID) (*Tale, bool) {
	v := tales.Get(id.Binary())
	if v == nil {
		return nil, false
	}
	return v.(*Tale), true
}

func getPassage(id seqid.ID) (*Passage, bool) {
	v := passages.Get(id.Binary())
	if v == nil {
		return nil, false
	}
	return v.(*Passage), true
}

func mustGetTale(id int) *Tale {
	if id <= 0 {
		panic(ErrTaleNotFound)
	}
	t, ok := getTale(seqidOf(id))
	if !ok {
		panic(ErrTaleNotFound)
	}
	return t
}

func mustGetPassage(id int) *Passage {
	if id <= 0 {
		panic(ErrPassageNotFound)
	}
	p, ok := getPassage(seqidOf(id))
	if !ok {
		panic(ErrPassageNotFound)
	}
	return p
}

// mustGetVisiblePassage returns a passage that is neither hidden nor
// under a hidden passage.
func mustGetVisiblePassage(id int) *Passage {
	p := mustGetPassage(id)
	if !isVisible(p) {
		panic(ErrPassageHidden)
	}
	return p
}

// isVisible reports whether p and all its ancestors are not hidden.
// The walk is bounded by MaxDepth.
func isVisible(p *Passage) bool {
	for p != nil {
		if p.Hidden {
			return false
		}
		if p.Parent == 0 {
			return true
		}
		parent, ok := getPassage(p.Parent)
		if !ok {
			return false
		}
		p = parent
	}
	return false
}

// bardOf returns the record of addr, creating it if needed.
func bardOf(addr address) *Bard {
	if v := bards.Get(addr.String()); v != nil {
		return v.(*Bard)
	}
	b := &Bard{Addr: addr}
	bards.Set(addr.String(), b)
	setFame(b, 0)
	return b
}

func getBard(addr address) (*Bard, bool) {
	v := bards.Get(addr.String())
	if v == nil {
		return nil, false
	}
	return v.(*Bard), true
}

// fameKey sorts bards by cheers received, most first, then by address.
// Cheers are inverted and zero-padded so a forward iteration of the
// fame tree is the hall of fame.
func fameKey(cheers int, addr address) string {
	inv := strconv.Itoa(999999999 - cheers)
	return strings.Repeat("0", 9-len(inv)) + inv + "/" + addr.String()
}

// setFame moves b to its new place in the fame index.
func setFame(b *Bard, newCheers int) {
	fame.Remove(fameKey(b.Cheers, b.Addr))
	b.Cheers = newCheers
	fame.Set(fameKey(b.Cheers, b.Addr), b.Addr)
}

func bardPassageKey(addr address, id seqid.ID) string {
	return addr.String() + "/" + id.Binary()
}

// cleanLine trims a one-line field (title, choice) and folds inner
// newlines and tabs to spaces.
func cleanLine(s string) string {
	s = strings.TrimSpace(s)
	s = strings.NewReplacer("\r\n", " ", "\n", " ", "\r", " ", "\t", " ").Replace(s)
	for strings.Contains(s, "  ") {
		s = strings.ReplaceAll(s, "  ", " ")
	}
	return s
}

// cleanBody trims a passage body. Gnokey and the gnoweb Actions form
// send newlines as the two characters `\n`, so they are turned back
// into real line breaks.
func cleanBody(s string) string {
	s = strings.ReplaceAll(s, `\n`, "\n")
	s = strings.ReplaceAll(s, "\r\n", "\n")
	return strings.TrimSpace(s)
}

func checkLen(s string, min, max int, err error) {
	if len(s) < min || len(s) > max {
		panic(err)
	}
}

// sameChoice compares two choice texts, ignoring case.
func sameChoice(a, b string) bool {
	return strings.ToLower(a) == strings.ToLower(b)
}

// canonPath walks from the opening of t along the most-cheered visible
// child at each step (ties go to the earliest passage) and returns the
// passages on the way. It is bounded by MaxDepth and MaxChoices.
func canonPath(t *Tale) []*Passage {
	root, ok := getPassage(t.Root)
	if !ok || root.Hidden {
		return nil
	}
	path := []*Passage{root}
	cur := root
	for !cur.Ending && len(path) <= MaxDepth {
		var best *Passage
		for _, cid := range cur.Children {
			c, ok := getPassage(cid)
			if !ok || c.Hidden {
				continue
			}
			if best == nil || c.Cheers > best.Cheers {
				best = c
			}
		}
		if best == nil {
			break
		}
		path = append(path, best)
		cur = best
	}
	return path
}

// ancestors returns the passages from the opening down to p, p included.
func ancestors(p *Passage) []*Passage {
	chain := make([]*Passage, p.Depth+1)
	for cur := p; cur != nil; {
		if cur.Depth < len(chain) {
			chain[cur.Depth] = cur
		}
		if cur.Parent == 0 {
			break
		}
		parent, ok := getPassage(cur.Parent)
		if !ok {
			break
		}
		cur = parent
	}
	return chain
}

func seqidOf(id int) seqid.ID {
	return seqid.ID(id)
}
