package home

import (
	"strconv"
	"strings"

	"chain/runtime"
)

// Render is what gnoweb calls.
//
// The operator views (system, slots, edit, manifest) are always served here,
// never through the theme: a panic inside a foreign realm's code aborts the
// whole call and cannot be recovered from this side, so a theme that panics
// takes the page down until it is rolled back. These views are what the
// rollback is done from, and the routing keeps them out of the theme's reach.
// Every other path, the page itself included, goes to the live theme, or to
// the built-in renderer when none is accepted.
func Render(path string) string {
	if isOperatorPath(path) {
		return Fallback(path)
	}
	if t, ok := liveTheme(); ok {
		return t.Render(path)
	}
	return Fallback(path)
}

// operatorPaths are the render paths this realm keeps for itself.
var operatorPaths = []string{"system", "slots", "edit", "manifest"}

func isOperatorPath(path string) bool {
	path = cleanPath(path)
	for _, p := range operatorPaths {
		if path == p || strings.HasPrefix(path, p+"/") {
			return true
		}
	}
	return false
}

// cleanPath drops a query string from a render path.
func cleanPath(path string) string {
	if i := strings.Index(path, "?"); i >= 0 {
		return path[:i]
	}
	return path
}

// Fallback is the built-in renderer. Render routes the operator views here
// directly, and themes delegate to it for every other path they do not draw
// themselves, so these views exist under any theme:
//
//	""             the assembled page: the layout slot filled from the slots
//	"slots"        the slot index: name, size, revision, height of last write
//	"slots/<slug>" one slot's raw markdown, fenced
//	"edit"         forms that write slots (they build the gnokey command)
//	"edit/<slug>"  the same, prefilled with one slot
//	"system"       who may write, which theme is live, pending, history
//	"manifest"     Manifest() as plain text, for scripts
func Fallback(path string) string {
	path = cleanPath(path)
	switch {
	case path == "":
		return renderPage()
	case path == "slots":
		return renderIndex()
	case strings.HasPrefix(path, "slots/"):
		return renderSlot(strings.TrimPrefix(path, "slots/"))
	case path == "edit":
		return renderEdit("")
	case strings.HasPrefix(path, "edit/"):
		return renderEdit(strings.TrimPrefix(path, "edit/"))
	case path == "system":
		return renderSystem()
	case path == "manifest":
		return Manifest()
	}
	return "# Not found\n\nNo such path: " + strconv.Quote(path) +
		"\n\nTry [the slot index](" + Link("slots") + ").\n"
}

// ---------------------------------------------------------------------------
// Placeholder filling

// Filler substitutes :name: placeholders in a layout. It is lazy: a callback
// runs only when its placeholder occurs in the layout, so an unused slot is
// never even read. Substitution is single-pass and non-recursive, so a
// placeholder inside a slot body is left alone and no slot can expand into
// another. Names never contain ':', so no placeholder is a prefix of another
// and the result does not depend on registration order. A placeholder that
// nothing claims survives into the output verbatim: a missing section should
// be visible, not silently blank.
type Filler struct {
	names []string
	fns   map[string]func() string
}

// NewFiller returns a Filler with every slot and every computed placeholder
// registered. A theme adds its own widgets with Add before calling Fill.
func NewFiller() *Filler {
	f := &Filler{fns: map[string]func() string{}}
	slots.Iterate("", "", func(key string, value any) bool {
		s := value.(*Slot) // re-bound per iteration, so each closure sees its own
		f.Add(key, func() string { return s.Body })
		return false
	})
	f.Add("realm", func() string { return selfPath })
	f.Add("owner", Authority)
	f.Add("chainid", runtime.ChainID)
	f.Add("height", func() string { return strconv.FormatInt(runtime.ChainHeight(), 10) })
	f.Add("rev", func() string { return strconv.Itoa(rev) })
	f.Add("slots", slotLinks)
	f.Add("theme", func() string {
		if p := LivePath(); p != "" {
			return p
		}
		return "built-in"
	})
	f.Add("updated", updated)
	return f
}

// updated is the :updated: placeholder: when the slots last changed.
func updated() string {
	if lastHeight == 0 {
		return "never"
	}
	return "block " + strconv.FormatInt(lastHeight, 10) + " (rev " + strconv.Itoa(rev) + ")"
}

// Add registers the callback for :name:. A later Add for the same name wins,
// which is how a theme widget overrides a slot of the same name.
func (f *Filler) Add(name string, fn func() string) {
	if _, dup := f.fns[name]; !dup {
		f.names = append(f.names, name)
	}
	f.fns[name] = fn
}

// Fill returns layout with every present placeholder replaced.
func (f *Filler) Fill(layout string) string {
	pairs := []string{}
	for _, name := range f.names {
		ph := ":" + name + ":"
		if strings.Contains(layout, ph) {
			pairs = append(pairs, ph, f.fns[name]())
		}
	}
	if len(pairs) == 0 {
		return layout
	}
	return strings.NewReplacer(pairs...).Replace(layout)
}

// ---------------------------------------------------------------------------
// Views

// defaultLayout renders before a layout slot exists and no theme is live,
// i.e. right after the very first deploy. It uses only computed placeholders,
// so it never shows an unresolved :slug: of its own.
func defaultLayout() string {
	return "# " + selfPath + "\n\n" +
		"No theme is live and no layout slot is set, so this is the built-in page. " +
		"Content arrives with `Set`, one slot per call, and a theme deployed under " +
		"`" + selfPath + "/theme/` goes live with `Accept`. " +
		"See [system](" + Link("system") + ") and [edit](" + Link("edit") + ").\n\n" +
		"## Slots\n\n:slots:\n\n---\n\n" +
		"rev :rev: · block :height: · :chainid: · theme :theme: · " +
		"[edit](" + Link("edit") + ") · [system](" + Link("system") + ")\n"
}

func renderPage() string {
	layout := Layout()
	if layout == "" {
		layout = defaultLayout()
	}
	return NewFiller().Fill(layout)
}

// slotLinks is the :slots: placeholder: a bullet list of every slot, linking
// to its raw view.
func slotLinks() string {
	if slots.Size() == 0 {
		return "_no slots yet_"
	}
	var b strings.Builder
	slots.Iterate("", "", func(key string, _ any) bool {
		b.WriteString("- [" + key + "](" + Link("slots/"+key) + ")\n")
		return false
	})
	return strings.TrimSuffix(b.String(), "\n")
}

func renderIndex() string {
	var b strings.Builder
	b.WriteString("# Slots\n\n")
	b.WriteString("rev " + strconv.Itoa(rev) + " · " + strconv.Itoa(slots.Size()) + " slot(s) · " +
		"[edit](" + Link("edit") + ") · [system](" + Link("system") + ")\n\n")
	if slots.Size() == 0 {
		b.WriteString("_no slots yet_\n")
		return b.String()
	}
	b.WriteString("| slot | bytes | rev | height | |\n")
	b.WriteString("| --- | ---: | ---: | ---: | --- |\n")
	slots.Iterate("", "", func(key string, value any) bool {
		s := value.(*Slot)
		b.WriteString("| [" + key + "](" + Link("slots/"+key) + ") | " +
			strconv.Itoa(len(s.Body)) + " | " +
			strconv.Itoa(s.Rev) + " | " +
			strconv.FormatInt(s.Height, 10) + " | " +
			"[edit](" + Link("edit/"+key) + ") |\n")
		return false
	})
	return b.String()
}

func renderSlot(slug string) string {
	s, ok := Lookup(slug)
	if !ok {
		return "# Not found\n\nNo slot named " + strconv.Quote(slug) +
			".\n\nTry [the slot index](" + Link("slots") + ").\n"
	}
	f := fence(s.Body)
	var b strings.Builder
	b.WriteString("# " + slug + "\n\n")
	b.WriteString(strconv.Itoa(len(s.Body)) + " bytes · rev " + strconv.Itoa(s.Rev) +
		" · written at block " + strconv.FormatInt(s.Height, 10) +
		" · [edit](" + Link("edit/"+slug) + ")\n\n")
	b.WriteString(f + "\n" + s.Body)
	if !strings.HasSuffix(s.Body, "\n") {
		b.WriteString("\n")
	}
	b.WriteString(f + "\n")
	return b.String()
}

// fence returns a code fence longer than any backtick run in body, so the
// body can never close it early.
func fence(body string) string {
	longest, run := 0, 0
	for i := 0; i < len(body); i++ {
		if body[i] != '`' {
			run = 0
			continue
		}
		run++
		if run > longest {
			longest = run
		}
	}
	n := 3
	if longest >= 3 {
		n = longest + 1
	}
	return strings.Repeat("`", n)
}

// renderEdit is the in-browser editor: gnoweb forms that build the gnokey
// command for Set and Delete. Anyone can see them; only the authority's
// signature makes the resulting transaction succeed.
func renderEdit(slug string) string {
	var b strings.Builder
	b.WriteString("# Edit\n\n")
	b.WriteString("Writes are restricted to `" + Authority() + "`. Each form assembles the " +
		"`gnokey` command; sign it with that key. Slots and style knobs are the same thing: " +
		"`style.accent` is a slot too. [Index](" + Link("slots") + ") · [system](" + Link("system") + ")\n\n")

	if slug != "" {
		s, ok := Lookup(slug)
		if !ok {
			b.WriteString("> [!WARNING]\n> No slot named " + strconv.Quote(slug) + " yet. Saving creates it.\n\n")
		}
		b.WriteString("## " + slug + "\n\n")
		b.WriteString("<gno-form exec=\"Set\">\n")
		b.WriteString("  <gno-input name=\"slug\" type=\"text\" value=\"" + attr(slug) + "\" placeholder=\"slot name\" />\n")
		b.WriteString("  <gno-textarea name=\"body\" rows=\"10\" value=\"" + attr(s.Body) + "\" placeholder=\"markdown\" />\n")
		b.WriteString("</gno-form>\n\n")
		if ok {
			b.WriteString("[Raw view](" + Link("slots/"+slug) + ") · " +
				"a body that itself contains the two characters `\\n` or `\\t` is unfolded here; " +
				"use `make push` for those.\n\n")
		}
	} else {
		b.WriteString("## New or replace\n\n")
		b.WriteString("<gno-form exec=\"Set\">\n")
		b.WriteString("  <gno-input name=\"slug\" type=\"text\" placeholder=\"slot name: [a-z0-9._-]\" />\n")
		b.WriteString("  <gno-textarea name=\"body\" rows=\"10\" placeholder=\"markdown\" />\n")
		b.WriteString("</gno-form>\n\n")
	}

	b.WriteString("## Delete\n\n")
	b.WriteString("<gno-form exec=\"Delete\">\n")
	b.WriteString("  <gno-input name=\"slug\" type=\"text\" placeholder=\"slot name\" />\n")
	b.WriteString("</gno-form>\n\n")

	b.WriteString("## Slots\n\n")
	if slots.Size() == 0 {
		b.WriteString("_no slots yet_\n")
		return b.String()
	}
	slots.Iterate("", "", func(key string, _ any) bool {
		b.WriteString("- " + key + " · [view](" + Link("slots/"+key) + ") · [edit](" + Link("edit/"+key) + ")\n")
		return false
	})
	return b.String()
}

// attr escapes s for a double-quoted attribute of a gnoweb form tag, which
// must sit on one line: newlines and tabs become the \n and \t sequences the
// textarea unfolds.
func attr(s string) string {
	return strings.NewReplacer(
		"&", "&amp;",
		"\"", "&quot;",
		"<", "&lt;",
		">", "&gt;",
		"\r", "",
		"\n", "\\n",
		"\t", "\\t",
	).Replace(s)
}

// renderSystem shows the upgrade wiring and offers the Accept form.
func renderSystem() string {
	var b strings.Builder
	b.WriteString("# System\n\n")
	b.WriteString("| | |\n| --- | --- |\n")
	b.WriteString("| realm | `" + selfPath + "` |\n")
	b.WriteString("| authority | `" + Authority() + "` |\n")
	if p := LivePath(); p != "" {
		b.WriteString("| theme | [" + p + "](" + sourceLink(p) + ") |\n")
	} else {
		b.WriteString("| theme | built-in fallback (nothing accepted yet) |\n")
	}
	b.WriteString("| revision | " + strconv.Itoa(rev) + " |\n")
	b.WriteString("| last write | " + updated() + " |\n")
	if Frozen() {
		b.WriteString("| upgrades | **frozen** |\n")
	} else {
		b.WriteString("| upgrades | open |\n")
	}
	b.WriteString("\n")

	pending := PendingPaths()
	if len(pending) > 0 {
		b.WriteString("## Awaiting acceptance\n\n")
		b.WriteString("A theme registered itself by being deployed. Accepting is a separate transaction, " +
			"naming code you can [read first](" + sourceLink(pending[0]) + ").\n\n")
		for _, p := range pending {
			b.WriteString("<gno-form exec=\"Accept\">\n")
			b.WriteString("  <gno-input name=\"pkgPath\" type=\"text\" value=\"" + attr(p) + "\" placeholder=\"theme realm path\" />\n")
			b.WriteString("</gno-form>\n\n")
		}
	}

	if past := HistoryPaths(); len(past) > 0 {
		b.WriteString("## Previously\n\n")
		for _, p := range past {
			b.WriteString("- [" + p + "](" + sourceLink(p) + ")\n")
		}
		b.WriteString("\n")
	}

	if !Frozen() {
		b.WriteString("## Operations\n\n")
		b.WriteString("- [Rollback](" + helpLink("Rollback") + ") to the previous theme\n")
		b.WriteString("- [Accept](" + helpLink("Accept") + ") a theme by path\n")
		b.WriteString("- [Withdraw](" + helpLink("Withdraw") + ") a candidate\n")
		b.WriteString("- [Forget](" + helpLink("Forget") + ") the rollback history\n")
		b.WriteString("- [Transfer authority](" + helpLink("TransferAuthority") + ")\n")
		b.WriteString("- [Freeze](" + helpLink("Freeze") + "): no more theme upgrades, ever\n\n")
	}

	b.WriteString("## How an upgrade works\n\n")
	b.WriteString("1. Copy `theme/v0` to `theme/v1`, change what you like, keep `Render`.\n")
	b.WriteString("2. Deploy it at `" + selfPath + "/theme/v1`. Its init registers it here.\n")
	b.WriteString("3. Accept that path. The slots never moved; only the code reading them changed.\n")
	b.WriteString("4. If it misbehaves, Rollback. A theme that panics takes the page down until then, " +
		"but this view and the other built-in ones never go through the theme, so the rollback is always reachable.\n")
	return b.String()
}

func helpLink(fn string) string {
	return Link("") + "$help&func=" + fn
}

func sourceLink(pkgPath string) string {
	if i := strings.Index(pkgPath, "/"); i >= 0 {
		pkgPath = pkgPath[i:]
	}
	return pkgPath + "$source"
}
