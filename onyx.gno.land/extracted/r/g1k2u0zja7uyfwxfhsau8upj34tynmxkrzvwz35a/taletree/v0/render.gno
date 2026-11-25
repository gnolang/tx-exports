package taletree

import (
	"chain/runtime"
	"chain/runtime/unsafe"
	"strconv"
	"strings"

	"gno.land/p/moul/txlink/v0"
	"gno.land/p/nt/avl/pager/v0"
	"gno.land/p/nt/markdown/sanitize/v0"
	"gno.land/p/nt/mux/v0"
	"gno.land/p/nt/seqid/v0"
	"gno.land/p/nt/ufmt/v0"
	"gno.land/r/sys/users"
)

const (
	talesPerPage    = 10
	outlineDepth    = 3 // levels shown in a tale outline
	breadcrumbTail  = 3 // last passages shown in a long breadcrumb
	bardPassageList = 10
	fameListSize    = 20
	tipButtonUgnot  = 1_000_000
)

var (
	router *mux.Router
	base   string       // realm path as gnoweb links it, e.g. /r/<ns>/taletree/v0
	tx     txlink.Realm // action links always point at this realm
)

func init() {
	pkgPath := unsafe.CurrentRealm().PkgPath()
	base = strings.TrimPrefix(pkgPath, runtime.ChainDomain())
	tx = txlink.Realm(pkgPath)

	router = mux.NewRouter()
	router.HandleFunc("", renderHome)
	router.HandleFunc("tale/{id}", renderTale)
	router.HandleFunc("tale/{id}/canon", renderCanon)
	router.HandleFunc("p/{id}", renderPassage)
	router.HandleFunc("bard/{addr}", renderBard)
	router.HandleFunc("bards", renderFame)
	router.SetNotFoundHandler(func(res *mux.ResponseWriter, req *mux.Request) {
		res.Write("# Page not found\n\nNo page at `" + sanitize.InlineText(req.Path) + "`. [Back to Taletree](" + base + ")\n")
	})
}

// Render serves every Taletree page; see the package doc for routes.
func Render(path string) string {
	return router.Render(path)
}

// ----- pages -----

func renderHome(res *mux.ResponseWriter, req *mux.Request) {
	res.Write("# 🌳 Taletree\n\n")
	res.Write("*Stories that branch. You write what happens next.*\n\n")
	res.Write("Taletree is a library of choose-your-own-adventure tales written together, on-chain. " +
		"Start a tale, add a new choice under any passage, or close a path with an ending. " +
		"Cheer the passages you love: the most-cheered choice at each step becomes the tale's **canon**. " +
		"Tips go straight to the author.\n\n")

	if paused {
		res.Write("> [!WARNING]\n> Writing is paused by the keeper. Reading, cheering and tipping still work.\n\n")
	}

	res.Write(count(tales.Size(), "tale") + " · " + count(passages.Size(), "passage") + " · " +
		count(bards.Size(), "bard") + " · **" + gnot(totalTips) + "** tipped to authors\n\n")

	res.Write(button(tx.Call("StartTale"), "✍️ Start a tale", "") + " " +
		button(base+":bards", "🏆 Hall of fame", "outline") + "\n\n")

	res.Write("## Tales\n\n")
	if tales.Size() == 0 {
		res.Write("No tale yet. Be the first to [start one](" + tx.Call("StartTale") + ").\n\n")
	} else {
		pg := pager.NewPager(&tales, talesPerPage, true)
		page, err := pg.GetPageByPath(req.RawPath)
		if err != nil {
			res.Write("Invalid page.\n")
			return
		}
		for _, item := range page.Items {
			t := item.Value.(*Tale)
			lock := ""
			if t.Locked {
				lock = " 🔒"
			}
			title := sanitize.InlineText(t.Title)
			if root, ok := getPassage(t.Root); !ok || root.Hidden {
				title = "Hidden tale"
			}
			res.Write(ufmt.Sprintf("- **[%s](%s:tale/%d)**%s by %s · %s · %s · 🍻 %d · updated %s\n",
				title, base, uint64(t.ID), lock, bardLink(t.Narrator),
				plural(t.Passages, "passage"), plural(t.Endings, "ending"), t.Cheers, t.UpdatedAt.UTC().Format("2006-01-02")))
		}
		if picker := page.Picker(req.Path); picker != "" {
			res.Write("\n" + picker + "\n")
		}
		res.Write("\n")
	}

	res.Write("## How it works\n\n")
	res.Write("1. **Read**: open a tale, follow the choices, or read its canon in one go.\n")
	res.Write("2. **Write**: under any passage, add a choice and what happens next (20 to 1,500 characters), or write an ending.\n")
	res.Write("3. **Cheer**: one cheer per passage per account. The most-cheered choice at each step is the canon.\n")
	res.Write("4. **Tip**: send GNOT to a passage you liked; all of it goes to the author in the same transaction.\n\n")
	res.Write(ufmt.Sprintf("Each passage has up to %d choices and a tale goes up to %d passages deep. "+
		"Narrators can hide passages in their tale and lock it when it is finished.\n", MaxChoices, MaxDepth))
}

func renderTale(res *mux.ResponseWriter, req *mux.Request) {
	t, ok := taleFromVar(req.GetVar("id"))
	if !ok {
		notFound(res, "tale")
		return
	}
	root, _ := getPassage(t.Root)

	res.Write(crumbs(link("Taletree", base)) + "\n\n")
	res.Write("# " + sanitize.InlineText(t.Title) + "\n\n")
	res.Write(ufmt.Sprintf("Narrated by %s · %s · %s · 🍻 %s",
		bardLink(t.Narrator), plural(t.Passages, "passage"), plural(t.Endings, "ending"), plural(t.Cheers, "cheer")))
	if t.Locked {
		res.Write(" · 🔒 locked")
	}
	res.Write("\n\n")

	if root.Hidden {
		res.Write("> [!CAUTION]\n> This tale was hidden by a moderator.\n")
		return
	}

	res.Write(sanitize.Block(root.Body))
	res.Write(button(ufmt.Sprintf("%s:p/%d", base, uint64(root.ID)), "📖 Start reading", "") + " " +
		button(ufmt.Sprintf("%s:tale/%d/canon", base, uint64(t.ID)), "✨ Read the canon", "outline") + "\n\n")

	res.Write("## Map of the tale\n\n")
	if len(root.Children) == 0 {
		res.Write("No choice yet. [Write the first one](" + branchLink(root) + ").\n")
		return
	}
	res.Write("Every branch, " + strconv.Itoa(outlineDepth) + " levels deep. ✨ marks the canon, 🏁 an ending.\n\n")
	canon := map[seqid.ID]bool{}
	for _, p := range canonPath(t) {
		canon[p.ID] = true
	}
	writeOutline(res, root, 0, canon)
}

func writeOutline(res *mux.ResponseWriter, p *Passage, level int, canon map[seqid.ID]bool) {
	indent := strings.Repeat("  ", level)
	for _, cid := range p.Children {
		c, ok := getPassage(cid)
		if !ok || c.Hidden {
			continue
		}
		marks := ""
		if canon[c.ID] {
			marks += " ✨"
		}
		if c.Ending {
			marks += " 🏁"
		}
		res.Write(ufmt.Sprintf("%s- [%s](%s:p/%d) · 🍻 %d%s",
			indent, sanitize.InlineText(c.Choice), base, uint64(c.ID), c.Cheers, marks))
		if level+1 >= outlineDepth {
			if n := len(visibleChildren(c)); n > 0 {
				res.Write(ufmt.Sprintf(" · *%d more choices below*", n))
			}
			res.Write("\n")
			continue
		}
		res.Write("\n")
		writeOutline(res, c, level+1, canon)
	}
}

func renderCanon(res *mux.ResponseWriter, req *mux.Request) {
	t, ok := taleFromVar(req.GetVar("id"))
	if !ok {
		notFound(res, "tale")
		return
	}
	path := canonPath(t)
	res.Write(crumbs(link("Taletree", base), link(sanitize.InlineText(t.Title), ufmt.Sprintf("%s:tale/%d", base, uint64(t.ID)))) + "\n\n")
	res.Write("# " + sanitize.InlineText(t.Title) + ": the canon\n\n")
	if len(path) == 0 {
		res.Write("> [!CAUTION]\n> This tale was hidden by a moderator.\n")
		return
	}
	res.Write("*The path readers cheered most, one passage after another.*\n\n")
	for i, p := range path {
		if i > 0 {
			res.Write(ufmt.Sprintf("### → [%s](%s:p/%d)\n", sanitize.InlineText(p.Choice), base, uint64(p.ID)))
		}
		res.Write(sanitize.Block(p.Body))
		res.Write(ufmt.Sprintf("*%s · 🍻 %d*\n\n", bardLink(p.Author), p.Cheers))
	}
	last := path[len(path)-1]
	if last.Ending {
		res.Write("## 🏁 The End\n\n")
		res.Write("Not your ending? [Explore the other branches](" + ufmt.Sprintf("%s:tale/%d", base, uint64(t.ID)) + ").\n")
		return
	}
	res.Write("---\n\n*The canon continues when someone writes what happens next.*\n\n")
	if !t.Locked {
		res.Write(button(branchLink(last), "✍️ Write what happens next", "") + "\n")
	}
}

func renderPassage(res *mux.ResponseWriter, req *mux.Request) {
	p, ok := passageFromVar(req.GetVar("id"))
	if !ok {
		notFound(res, "passage")
		return
	}
	t, _ := getTale(p.Tale)
	taleURL := ufmt.Sprintf("%s:tale/%d", base, uint64(t.ID))

	res.Write(breadcrumb(p, t) + "\n\n")
	if !isVisible(p) {
		res.Write("# Hidden passage\n\n")
		reason := ""
		if p.Hidden && p.HiddenReason != "" {
			reason = " Reason: " + sanitize.InlineText(p.HiddenReason)
		}
		res.Write("> [!CAUTION]\n> This passage, or one before it, was hidden by a moderator." + reason + "\n\n")
		res.Write("[Back to the tale](" + taleURL + ")\n")
		return
	}

	if p.Depth == 0 {
		res.Write("# " + sanitize.InlineText(t.Title) + "\n\n")
	} else {
		res.Write("# " + sanitize.InlineText(p.Choice) + "\n\n")
	}
	res.Write(sanitize.Block(p.Body))

	meta := ufmt.Sprintf("Written by %s · block %d · 🍻 %d", bardLink(p.Author), p.Height, p.Cheers)
	if p.Tips > 0 {
		meta += " · 💰 " + gnot(p.Tips)
	}
	res.Write("*" + meta + "*\n\n")

	if p.Ending {
		res.Write("## 🏁 The End\n\n")
		res.Write("This path ends here. [Read the canon](" + taleURL + "/canon) or [explore other branches](" + taleURL + ").\n\n")
	} else {
		res.Write("## What happens next?\n\n")
		kids := visibleChildren(p)
		if len(kids) == 0 {
			res.Write("*Nobody has written it yet. It could be you.*\n\n")
		}
		canon := map[seqid.ID]bool{}
		for _, c := range canonPath(t) {
			canon[c.ID] = true
		}
		for i, c := range kids {
			marks := ""
			if canon[c.ID] {
				marks += " · ✨ canon"
			}
			if c.Ending {
				marks += " · 🏁 ending"
			}
			res.Write(ufmt.Sprintf("%d. **[%s](%s:p/%d)** · 🍻 %d%s\n",
				i+1, sanitize.InlineText(c.Choice), base, uint64(c.ID), c.Cheers, marks))
		}
		res.Write("\n")
	}

	actions := []string{}
	if !p.Ending && !t.Locked && !paused && len(p.Children) < MaxChoices {
		actions = append(actions,
			button(branchLink(p), "✍️ Add a choice", ""),
			button(tx.NewLink("WriteEnding").AddArgs("parentID", strconv.Itoa(int(p.ID))).URL(), "🏁 Write an ending", "outline"))
	}
	actions = append(actions,
		button(tx.NewLink("Cheer").AddArgs("passageID", strconv.Itoa(int(p.ID))).URL(), "🍻 Cheer", "outline"),
		button(tx.NewLink("Tip").AddArgs("passageID", strconv.Itoa(int(p.ID))).SetSend(strconv.Itoa(tipButtonUgnot)+"ugnot").URL(), "💰 Tip 1 GNOT", "outline"))
	res.Write(strings.Join(actions, " ") + "\n\n")

	if p.Parent != 0 {
		res.Write(ufmt.Sprintf("[← Previous passage](%s:p/%d) · ", base, uint64(p.Parent)))
	}
	res.Write("[Map of the tale](" + taleURL + ")\n")
}

func renderBard(res *mux.ResponseWriter, req *mux.Request) {
	addr := address(req.GetVar("addr"))
	if !addr.IsValid() {
		notFound(res, "bard")
		return
	}
	res.Write(crumbs(link("Taletree", base), link("Hall of fame", base+":bards")) + "\n\n")
	res.Write("# " + bardName(addr) + "\n\n")
	if name := bardName(addr); name != addr.String() {
		res.Write("`" + addr.String() + "`\n\n")
	}
	b, ok := getBard(addr)
	if !ok {
		res.Write("This address has not written anything yet.\n")
		return
	}
	res.Write(count(b.Passages, "passage") + " · " + count(b.Tales, "tale") + " started · 🍻 " +
		count(b.Cheers, "cheer") + " received · 💰 **" + gnot(b.Tips) + "** received in tips\n\n")

	res.Write("## Latest passages\n\n")
	prefix := addr.String() + "/"
	n := 0
	// "0" sorts right after "/" so [prefix, addr+"0") holds this bard's keys only.
	bardPassages.ReverseIterate(prefix, addr.String()+"0", func(_ string, v any) bool {
		p, ok := getPassage(v.(seqid.ID))
		if !ok || !isVisible(p) {
			return false
		}
		t, _ := getTale(p.Tale)
		label := sanitize.InlineText(p.Choice)
		if p.Depth == 0 {
			label = "Opening of " + sanitize.InlineText(t.Title)
		}
		res.Write(ufmt.Sprintf("- [%s](%s:p/%d) in *%s* · 🍻 %d\n",
			label, base, uint64(p.ID), sanitize.InlineText(t.Title), p.Cheers))
		n++
		return n >= bardPassageList
	})
	if n == 0 {
		res.Write("Nothing to show.\n")
	}
}

func renderFame(res *mux.ResponseWriter, req *mux.Request) {
	res.Write(crumbs(link("Taletree", base)) + "\n\n")
	res.Write("# 🏆 Hall of fame\n\n")
	res.Write("Bards ranked by cheers received on their passages.\n\n")
	if fame.Size() == 0 {
		res.Write("No bard yet.\n")
		return
	}
	res.Write("| # | Bard | Cheers | Passages | Tips received |\n|---:|---|---:|---:|---:|\n")
	rank := 0
	fame.Iterate("", "", func(_ string, v any) bool {
		b, _ := getBard(v.(address))
		rank++
		res.Write(ufmt.Sprintf("| %d | %s | %d | %d | %s |\n", rank, bardLink(b.Addr), b.Cheers, b.Passages, gnot(b.Tips)))
		return rank >= fameListSize
	})
}

// ----- helpers -----

func taleFromVar(s string) (*Tale, bool) {
	id, err := strconv.ParseUint(s, 10, 64)
	if err != nil || id == 0 {
		return nil, false
	}
	return getTale(seqid.ID(id))
}

func passageFromVar(s string) (*Passage, bool) {
	id, err := strconv.ParseUint(s, 10, 64)
	if err != nil || id == 0 {
		return nil, false
	}
	return getPassage(seqid.ID(id))
}

func visibleChildren(p *Passage) []*Passage {
	var kids []*Passage
	for _, cid := range p.Children {
		if c, ok := getPassage(cid); ok && !c.Hidden {
			kids = append(kids, c)
		}
	}
	return kids
}

// breadcrumb shows the way from the opening to p. Long paths keep the
// opening and the last few steps.
func breadcrumb(p *Passage, t *Tale) string {
	items := []string{link("Taletree", base), link(sanitize.InlineText(t.Title), ufmt.Sprintf("%s:tale/%d", base, uint64(t.ID)))}
	path := ancestors(p)
	start := 1
	if len(path)-1 > breadcrumbTail {
		start = len(path) - breadcrumbTail
		items = append(items, "…")
	}
	for i := start; i < len(path); i++ {
		a := path[i]
		if a == nil {
			continue
		}
		if a.ID == p.ID {
			items = append(items, sanitize.InlineText(a.Choice))
		} else {
			items = append(items, link(sanitize.InlineText(a.Choice), ufmt.Sprintf("%s:p/%d", base, uint64(a.ID))))
		}
	}
	return crumbs(items...)
}

func crumbs(items ...string) string {
	return strings.Join(items, " › ")
}

func link(text, url string) string {
	return "[" + text + "](" + url + ")"
}

func button(href, label, variant string) string {
	if variant != "" {
		return `<gno-button href="` + href + `" label="` + label + `" variant="` + variant + `" />`
	}
	return `<gno-button href="` + href + `" label="` + label + `" />`
}

func branchLink(p *Passage) string {
	return tx.NewLink("Branch").AddArgs("parentID", strconv.Itoa(int(p.ID))).URL()
}

// plural writes "1 tale", "2 tales".
func plural(n int, word string) string {
	if n == 1 {
		return "1 " + word
	}
	return strconv.Itoa(n) + " " + word + "s"
}

// count is plural with the number in bold.
func count(n int, word string) string {
	p := plural(n, word)
	return "**" + strconv.Itoa(n) + "**" + p[len(strconv.Itoa(n)):]
}

func notFound(res *mux.ResponseWriter, what string) {
	res.Write("# Not found\n\nThere is no such " + what + ". [Back to Taletree](" + base + ")\n")
}

// bardName is the registered username of addr (from r/sys/users), or
// the address itself.
func bardName(addr address) string {
	if u := users.ResolveAddress(addr); u != nil && !u.IsDeleted() {
		return "@" + u.Name()
	}
	return addr.String()
}

func bardLink(addr address) string {
	name := bardName(addr)
	if !strings.HasPrefix(name, "@") {
		s := addr.String()
		if len(s) > 14 {
			name = s[:8] + "…" + s[len(s)-4:]
		}
	}
	return "[" + name + "](" + base + ":bard/" + addr.String() + ")"
}

// gnot formats an ugnot amount as GNOT with up to 2 decimals.
func gnot(ugnot int64) string {
	whole := ugnot / 1_000_000
	cents := (ugnot % 1_000_000) / 10_000
	if cents == 0 {
		return strconv.FormatInt(whole, 10) + " GNOT"
	}
	c := strconv.FormatInt(cents, 10)
	if cents < 10 {
		c = "0" + c
	}
	c = strings.TrimRight(c, "0")
	return strconv.FormatInt(whole, 10) + "." + c + " GNOT"
}
