// Package builders is a public directory of people with proven, paid work.
//
// Anyone can list themselves, but only after finishing at least one paid task
// on Gild. The proof is not copied or claimed: the directory asks the Gild
// realm directly, at the moment you join and every time the page renders.
// No oracle, no admin, no off-chain list. This is the point of the Gild
// record: any realm can trust it with a single function call.
package builders

import (
	"strconv"
	"strings"
	"time"

	"gno.land/p/nt/avl/v0"
	"gno.land/r/g1jw2yrfqnd4fp90qadw88pnjgpden4vgagjvpe6/gild/v0"
)

const (
	// MinTasks is how many paid Gild tasks you need before you can join.
	MinTasks = 1
	MaxPitch = 160
	MaxLink  = 200
	MaxPage  = 50
)

const (
	ErrNoProof = "builders: finish a paid task on Gild first"
	ErrPitch   = "builders: pitch must be 1 to 160 characters"
	ErrLink    = "builders: link must start with https:// and have no spaces"
	ErrNotIn   = "builders: you are not in the directory"
)

// Entry is one person in the directory. Their work stats are not stored here:
// they are read from Gild so they are always current.
type Entry struct {
	Addr     address
	Pitch    string
	Link     string
	JoinedAt time.Time
}

var (
	entries avl.Tree // address string -> *Entry
	webPath string
)

func init(cur realm) {
	webPath = strings.TrimPrefix(cur.PkgPath(), "gno.land")
}

// Join adds the caller to the directory, or updates their pitch and link.
// It fails unless the caller has finished at least MinTasks paid Gild tasks.
func Join(cur realm, pitch, link string) {
	caller := cur.Previous().Address()
	if !gild.HasCompleted(caller, MinTasks) {
		panic(ErrNoProof)
	}
	pitch = strings.TrimSpace(pitch)
	link = strings.TrimSpace(link)
	if len(pitch) == 0 || len(pitch) > MaxPitch || hasControl(pitch) {
		panic(ErrPitch)
	}
	if link != "" && !isLink(link) {
		panic(ErrLink)
	}
	key := caller.String()
	if v := entries.Get(key); v != nil {
		e := v.(*Entry)
		e.Pitch, e.Link = pitch, link
		return
	}
	entries.Set(key, &Entry{Addr: caller, Pitch: pitch, Link: link, JoinedAt: time.Now()})
}

// Leave removes the caller from the directory.
func Leave(cur realm) {
	key := cur.Previous().Address().String()
	if _, removed := entries.Remove(key); !removed {
		panic(ErrNotIn)
	}
}

// IsListed reports whether addr is in the directory.
func IsListed(addr address) bool {
	return entries.Has(addr.String())
}

// Size returns how many people are listed.
func Size() int { return entries.Size() }

// BuildersJSON lists entries with their live Gild stats.
func BuildersJSON(offset, limit int) string {
	if offset < 0 {
		offset = 0
	}
	if limit <= 0 || limit > MaxPage {
		limit = MaxPage
	}
	var b strings.Builder
	b.WriteString(`{"total":`)
	b.WriteString(strconv.Itoa(entries.Size()))
	b.WriteString(`,"items":[`)
	first := true
	entries.IterateByOffset(offset, limit, func(_ string, v any) bool {
		e := v.(*Entry)
		if !first {
			b.WriteByte(',')
		}
		first = false
		b.WriteString(`{"address":`)
		b.WriteString(jsonStr(e.Addr.String()))
		b.WriteString(`,"pitch":`)
		b.WriteString(jsonStr(e.Pitch))
		b.WriteString(`,"link":`)
		b.WriteString(jsonStr(e.Link))
		b.WriteString(`,"completed":`)
		b.WriteString(strconv.Itoa(gild.Completed(e.Addr)))
		b.WriteString(`,"earned":`)
		b.WriteString(strconv.FormatInt(gild.Earned(e.Addr), 10))
		b.WriteString(`,"joinedAt":`)
		b.WriteString(strconv.FormatInt(e.JoinedAt.Unix(), 10))
		b.WriteByte('}')
		return false
	})
	b.WriteString("]}")
	return b.String()
}

// Render shows the directory on gno.land.
func Render(path string) string {
	var b strings.Builder
	b.WriteString("# Gild Builders\n\n")
	b.WriteString("People with proven, paid work on [Gild](/r/" + gildPath() + "). ")
	b.WriteString("To join, finish at least ")
	b.WriteString(strconv.Itoa(MinTasks))
	b.WriteString(" paid task, then call `Join`. Stats below are read live from Gild.\n\n")
	if entries.Size() == 0 {
		b.WriteString("_Nobody has joined yet._\n")
		return b.String()
	}
	b.WriteString("| Builder | Tasks done | Earned | Pitch |\n|---|---|---|---|\n")
	entries.Iterate("", "", func(_ string, v any) bool {
		e := v.(*Entry)
		addr := e.Addr.String()
		short := addr[:8] + "…" + addr[len(addr)-4:]
		b.WriteString("| [" + short + "](" + "/r/" + gildPath() + ":u/" + addr + ") | ")
		b.WriteString(strconv.Itoa(gild.Completed(e.Addr)))
		b.WriteString(" | ")
		b.WriteString(gnot(gild.Earned(e.Addr)))
		b.WriteString(" | ")
		b.WriteString(mdText(e.Pitch))
		if e.Link != "" {
			b.WriteString(" ([link](" + e.Link + "))")
		}
		b.WriteString(" |\n")
		return false
	})
	return b.String()
}

// gildPath is the Gild realm path without the gno.land/r/ prefix, derived from
// this realm's own namespace so it works wherever both are deployed.
func gildPath() string {
	p := strings.TrimPrefix(webPath, "/r/")
	if i := strings.Index(p, "/"); i >= 0 {
		return p[:i] + "/gild/v0"
	}
	return "gild/v0"
}

func hasControl(s string) bool {
	for _, r := range s {
		if r < 0x20 || r == 0x7f {
			return true
		}
	}
	return false
}

func isLink(s string) bool {
	if len(s) > MaxLink || !strings.HasPrefix(s, "https://") || len(s) <= len("https://") {
		return false
	}
	for _, r := range s {
		if r <= ' ' || r == 0x7f || strings.ContainsRune("\"<>`()[]|", r) {
			return false
		}
	}
	return true
}

func gnot(u int64) string {
	whole := u / 1_000_000
	frac := u % 1_000_000
	s := strconv.FormatInt(whole, 10)
	if frac != 0 {
		f := strconv.FormatInt(frac+1_000_000, 10)[1:]
		s += "." + strings.TrimRight(f, "0")
	}
	return s + " GNOT"
}

// mdText escapes characters that would change markdown or table layout.
func mdText(s string) string {
	var b strings.Builder
	for _, r := range s {
		if strings.ContainsRune("\\`*_[]()<>#|!~", r) {
			b.WriteByte('\\')
		}
		b.WriteRune(r)
	}
	return b.String()
}

func jsonStr(s string) string {
	var b strings.Builder
	b.WriteByte('"')
	for _, r := range s {
		switch {
		case r == '"':
			b.WriteString(`\"`)
		case r == '\\':
			b.WriteString(`\\`)
		case r < 0x20 || r == '<' || r == '>' || r == '&' || r == 0x2028 || r == 0x2029:
			h := strconv.FormatInt(int64(r), 16)
			b.WriteString(`\u` + strings.Repeat("0", 4-len(h)) + h)
		default:
			b.WriteRune(r)
		}
	}
	b.WriteByte('"')
	return b.String()
}
