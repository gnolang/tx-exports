package gnotif

import (
	"chain"
	"chain/runtime/unsafe"
	"strconv"
	"strings"

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
		id := strings.TrimPrefix(path, "trigger/")
		v := triggers.Get(id)
		if v == nil {
			return "Not found."
		}
		return renderTrigger(id, decodeRecord(v))
	case strings.HasPrefix(path, "target/"):
		target := strings.TrimPrefix(path, "target/")
		ids, _ := activeOf(target)
		if len(ids) == 0 {
			return "Not found."
		}
		return renderTarget(target, ids)
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
	triggers.ReverseIterateByOffset((n-1)*pageSize, pageSize, func(id string, v any) bool {
		writeLine(&b, id, decodeRecord(v))
		return false
	})
	if n < pages {
		b.WriteString("\n[Next page](" + selfPath + ":page/" + strconv.Itoa(n+1) + ")\n")
	}
	return b.String()
}

// renderTarget lists a realm's triggers, newest first. The cap on them keeps
// the page to one screen, so it is not paged.
func renderTarget(target string, ids []string) string {
	var b strings.Builder
	b.WriteString("# gnotif triggers for " + sanitize.InlineText(target) + "\n\n")
	for i := len(ids) - 1; i >= 0; i-- {
		writeLine(&b, ids[i], decodeRecord(triggers.Get(ids[i])))
	}
	b.WriteString("\n[All triggers](" + selfPath + ")\n")
	return b.String()
}

func writeLine(b *strings.Builder, id string, r record) {
	b.WriteString("- [**" + id + "**](" + selfPath + ":trigger/" + id + ") " +
		sanitize.InlineText(r.Target) + " · " + sanitize.InlineText(r.T.Event))
	if r.T.Param != "" {
		b.WriteString(" · param " + sanitize.InlineText(r.T.Param))
	}
	b.WriteString(" · ✓ verified · by " + chain.PackageAddress(r.Target).String() + "\n")
}

func renderTrigger(id string, r record) string {
	var b strings.Builder
	b.WriteString("# Trigger " + id + "\n\n")
	b.WriteString("- Target: " + sanitize.InlineText(r.Target) + "\n")
	b.WriteString("- Event: " + sanitize.InlineText(r.T.Event) + "\n")
	b.WriteString("- Filter: " + sanitize.InlineText(r.T.Filter) + "\n")
	b.WriteString("- Param: " + sanitize.InlineText(r.T.Param) + "\n")
	b.WriteString("- Title: " + sanitize.InlineText(r.T.Title) + "\n")
	b.WriteString("- Body: " + sanitize.InlineText(r.T.Body) + "\n")
	b.WriteString("- Link: " + sanitize.InlineText(r.T.Link) + "\n")
	b.WriteString("- Declarer: " + chain.PackageAddress(r.Target).String() + "\n")
	b.WriteString("- ✓ verified\n")
	b.WriteString("\n[All triggers](" + selfPath + ")\n")
	return b.String()
}

// selfPath is this realm's path on gnoweb, read at package init: Render is not
// crossing, so reading it there would give the caller's path.
var selfPath = strings.TrimPrefix(unsafe.CurrentRealm().PkgPath(), "gno.land")
