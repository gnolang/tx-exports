package gnotif

import (
	"chain/runtime/unsafe"
	"strconv"
	"strings"

	"gno.land/p/nt/avl/v0"
	"gno.land/p/nt/markdown/sanitize/v0"
)

const pageSize = 50

// Render serves "" (the first page), "page/N", "trigger/<id>" and
// "target/<path>".
func Render(path string) string {
	switch {
	case path == "":
		return renderPage(1)
	case strings.HasPrefix(path, "page/"):
		n, err := strconv.Atoi(strings.TrimPrefix(path, "page/"))
		if err != nil || n < 1 {
			return "Not found."
		}
		return renderPage(n)
	case strings.HasPrefix(path, "trigger/"):
		v := triggers.Get(strings.TrimPrefix(path, "trigger/"))
		if v == nil {
			return "Not found."
		}
		return renderTrigger(v.(*Trigger))
	case strings.HasPrefix(path, "target/"):
		own := byTarget.Get(strings.TrimPrefix(path, "target/"))
		if own == nil {
			return "Not found."
		}
		return renderTarget(strings.TrimPrefix(path, "target/"), own.(*avl.Tree))
	}
	return "Not found."
}

// renderPage lists the triggers newest first, pageSize to a page.
func renderPage(n int) string {
	var b strings.Builder
	b.WriteString("# gnotif triggers\n\n")
	pages := (triggers.Size() + pageSize - 1) / pageSize
	if n > pages {
		b.WriteString("No triggers on this page.\n")
		return b.String()
	}
	triggers.ReverseIterateByOffset((n-1)*pageSize, pageSize, func(_ string, v any) bool {
		writeLine(&b, v.(*Trigger))
		return false
	})
	if n < pages {
		b.WriteString("\n[Next page](" + selfPath + ":page/" + strconv.Itoa(n+1) + ")\n")
	}
	return b.String()
}

// renderTarget lists a realm's verified triggers, newest first. The cap on
// them keeps the page to one screen, so it is not paged.
func renderTarget(target string, own *avl.Tree) string {
	var b strings.Builder
	b.WriteString("# gnotif triggers for " + sanitize.InlineText(target) + "\n\n")
	own.ReverseIterate("", "", func(_ string, v any) bool {
		writeLine(&b, v.(*Trigger))
		return false
	})
	b.WriteString("\n[All triggers](" + selfPath + ")\n")
	return b.String()
}

func writeLine(b *strings.Builder, tr *Trigger) {
	b.WriteString("- [**" + tr.ID + "**](" + selfPath + ":trigger/" + tr.ID + ") " +
		sanitize.InlineText(tr.Target) + " · " + sanitize.InlineText(tr.Event))
	if tr.Param != "" {
		b.WriteString(" · param " + sanitize.InlineText(tr.Param))
	}
	if tr.Verified {
		b.WriteString(" · ✓ verified")
	}
	b.WriteString(" · by " + tr.Declarer.String() + "\n")
}

func renderTrigger(tr *Trigger) string {
	var b strings.Builder
	b.WriteString("# Trigger " + tr.ID + "\n\n")
	b.WriteString("- Target: " + sanitize.InlineText(tr.Target) + "\n")
	b.WriteString("- Event: " + sanitize.InlineText(tr.Event) + "\n")
	b.WriteString("- Filter: " + sanitize.InlineText(tr.Filter) + "\n")
	b.WriteString("- Param: " + sanitize.InlineText(tr.Param) + "\n")
	b.WriteString("- Title: " + sanitize.InlineText(tr.Title) + "\n")
	b.WriteString("- Body: " + sanitize.InlineText(tr.Body) + "\n")
	b.WriteString("- Link: " + sanitize.InlineText(tr.Link) + "\n")
	b.WriteString("- Declarer: " + tr.Declarer.String() + "\n")
	if tr.Verified {
		b.WriteString("- ✓ verified\n")
	}
	b.WriteString("\n[All triggers](" + selfPath + ")\n")
	return b.String()
}

// selfPath is this realm's path on gnoweb. It is read at package init, where
// the realm itself is current; Render is not crossing, so reading it there
// would give the caller's path. It only builds links.
var selfPath = strings.TrimPrefix(unsafe.CurrentRealm().PkgPath(), "gno.land")
