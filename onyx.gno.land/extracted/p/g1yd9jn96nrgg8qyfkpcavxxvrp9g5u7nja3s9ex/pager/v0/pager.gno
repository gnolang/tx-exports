// Package pager gives realms bounded, paginated iteration over an avl.Tree.
//
// Walking a whole tree inside Render or inside a transaction costs gas in
// proportion to the number of entries, so a realm that does it gets slower
// with every new entry until it no longer fits in the gas limit. pager caps
// every walk at MaxLimit entries and gives Render a ready-made "prev / next"
// navigation line.
//
//	func Render(path string) string {
//		offset, limit := pager.Parse(path)
//		page := pager.Of(posts, offset, limit, true)
//		out := ""
//		for _, it := range page.Items {
//			out += "- " + it.Value.(*Post).Body + "\n"
//		}
//		return out + page.Nav("")
//	}
//
// Assayer suggests this package as the fix for rules AS-G01 and AS-G02.
package pager

import (
	"strconv"
	"strings"

	"gno.land/p/nt/avl/v0"
)

const (
	// DefaultLimit is the page size used when the path names none.
	DefaultLimit = 20
	// MaxLimit is the largest page size Of will ever return.
	MaxLimit = 100
)

// Item is one tree entry on a page.
type Item struct {
	Key   string
	Value any
}

// Page is a bounded slice of a tree.
type Page struct {
	Items   []Item
	Offset  int
	Limit   int
	Total   int
	HasPrev bool
	HasNext bool
}

// Clamp returns offset and limit forced into a safe range:
// offset >= 0 and 1 <= limit <= MaxLimit.
func Clamp(offset, limit int) (int, int) {
	if offset < 0 {
		offset = 0
	}
	if limit <= 0 {
		limit = DefaultLimit
	}
	if limit > MaxLimit {
		limit = MaxLimit
	}
	return offset, limit
}

// Of returns at most limit entries of t starting at offset. With reverse
// set, entries come newest-key first. A nil tree gives an empty page.
func Of(t *avl.Tree, offset, limit int, reverse bool) Page {
	offset, limit = Clamp(offset, limit)
	p := Page{Offset: offset, Limit: limit}
	if t == nil {
		return p
	}
	p.Total = t.Size()
	collect := func(key string, value any) bool {
		p.Items = append(p.Items, Item{Key: key, Value: value})
		return false
	}
	if reverse {
		t.ReverseIterateByOffset(offset, limit, collect)
	} else {
		t.IterateByOffset(offset, limit, collect)
	}
	p.HasPrev = offset > 0
	p.HasNext = offset+len(p.Items) < p.Total
	return p
}

// Parse reads "page" (1-based) and "size" from the query part of a Render
// path, e.g. "posts?page=3&size=10". Missing or bad values fall back to the
// first page of DefaultLimit entries.
func Parse(path string) (offset, limit int) {
	page, size := 1, DefaultLimit
	if i := strings.Index(path, "?"); i >= 0 {
		for _, kv := range strings.Split(path[i+1:], "&") {
			parts := strings.SplitN(kv, "=", 2)
			if len(parts) != 2 {
				continue
			}
			n, err := strconv.Atoi(parts[1])
			if err != nil {
				continue
			}
			switch parts[0] {
			case "page":
				if n > 0 {
					page = n
				}
			case "size":
				size = n
			}
		}
	}
	_, size = Clamp(0, size)
	return (page - 1) * size, size
}

// Base strips the query part from a Render path.
func Base(path string) string {
	if i := strings.Index(path, "?"); i >= 0 {
		return path[:i]
	}
	return path
}

// PageNumber is the 1-based number of this page.
func (p Page) PageNumber() int {
	if p.Limit == 0 {
		return 1
	}
	return p.Offset/p.Limit + 1
}

// Nav renders a markdown "prev | page x/y | next" line whose links point at
// base with ?page= and &size= appended. It returns "" for a single page.
func (p Page) Nav(base string) string {
	if !p.HasPrev && !p.HasNext {
		return ""
	}
	pages := (p.Total + p.Limit - 1) / p.Limit
	cur := p.PageNumber()
	link := func(n int) string {
		return base + "?page=" + strconv.Itoa(n) + "&size=" + strconv.Itoa(p.Limit)
	}
	var b strings.Builder
	b.WriteString("\n")
	if p.HasPrev {
		b.WriteString("[« prev](" + link(cur-1) + ") | ")
	}
	b.WriteString("page " + strconv.Itoa(cur) + "/" + strconv.Itoa(pages))
	if p.HasNext {
		b.WriteString(" | [next »](" + link(cur+1) + ")")
	}
	b.WriteString("\n")
	return b.String()
}
