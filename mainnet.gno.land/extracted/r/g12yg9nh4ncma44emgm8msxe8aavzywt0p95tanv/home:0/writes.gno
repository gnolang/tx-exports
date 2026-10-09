package home

import (
	"chain"
	"chain/banker"
	"chain/runtime"
	"chain/runtime/unsafe"
	"strconv"
	"strings"
	"time"
	"unicode"
	"unicode/utf8"
)

// Every write function calls runtime.AssertOriginCall() first, in its own
// body: from inside a helper it refuses every call.

const maxSignBytes = 560

func invalid(field string) string { return errInvalidInput + field }

// checkLine enforces valid UTF-8, a rune count in [min, max], and no control
// characters (so no newline either): the text may end up inside an SVG,
// where they would break the XML.
func checkLine(field, s string, min, max int) {
	if !utf8.ValidString(s) {
		panic(invalid(field))
	}
	n := 0
	for _, r := range s {
		if r < 0x20 || r == 0x7f || r == 0xfffe || r == 0xffff {
			panic(invalid(field))
		}
		n++
	}
	if n < min || n > max {
		panic(invalid(field))
	}
}

// assertMasterKey refuses a transaction signed by a session key. Delegated
// keys may edit content, but not move ownership or hide an entry for good.
func assertMasterKey() {
	if _, _, _, isSession := runtime.GetSessionInfo(); isSession {
		panic(errMasterKey)
	}
}

// checkBadgeURL wants a printable-ASCII https:// URL (non-ASCII must be
// percent-encoded) with no quotes, backslashes, backticks, parentheses,
// square brackets, < or >, so the markdown link can't end early or become
// javascript:.
func checkBadgeURL(u string) {
	if !strings.HasPrefix(u, "https://") {
		panic(invalid("url"))
	}
	for i := 0; i < len(u); i++ {
		c := u[i]
		if c <= 0x20 || c >= 0x7f || strings.IndexByte("\"'\\`()[]<>", c) >= 0 {
			panic(invalid("url"))
		}
	}
}

// parseBadges reads one badge per line, "label | value | url". Blank lines
// between two badges start a new row; other blank lines are skipped.
func parseBadges(spec string) []badge {
	var out []badge
	row := false
	for _, line := range strings.Split(spec, "\n") {
		line = strings.TrimSpace(line)
		if line == "" {
			row = len(out) > 0
			continue
		}
		parts := strings.Split(line, "|")
		if len(parts) != 3 || len(out) == maxBadges {
			panic(invalid("spec"))
		}
		b := badge{
			label: strings.TrimSpace(parts[0]),
			value: strings.TrimSpace(parts[1]),
			url:   strings.TrimSpace(parts[2]),
			row:   row,
		}
		row = false
		checkLine("label", b.label, 1, 24)
		checkLine("value", b.value, 1, 24)
		checkBadgeURL(b.url)
		out = append(out, b)
	}
	return out
}

// hasVisible reports whether s has a character that draws something: not a
// space, a format character (zero-width, bidi), a combining mark, or one of
// the blank-looking fillers (Hangul fillers, braille blank).
func hasVisible(s string) bool {
	for _, r := range s {
		switch {
		case unicode.IsSpace(r), unicode.In(r, unicode.Cf, unicode.Mn, unicode.Me):
		case r == 0x115f, r == 0x1160, r == 0x3164, r == 0xffa0, r == 0x2800:
		default:
			return true
		}
	}
	return false
}

// validName wants 1 to max characters from a-z, 0-9 and "-": safe in a
// link, a tab label, and a path gnoweb passes to Render.
func validName(s string, max int) bool {
	if len(s) < 1 || len(s) > max {
		return false
	}
	for _, c := range s {
		if !(c >= 'a' && c <= 'z' || c >= '0' && c <= '9' || c == '-') {
			return false
		}
	}
	return true
}

// checkPage enforces the tab name, the page size, and the tab count.
func checkPage(tab, md string) {
	if !validName(tab, maxTabName) {
		panic(invalid("tab"))
	}
	if len(md) > maxPageBytes || !utf8.ValidString(md) {
		panic(invalid("md"))
	}
	if _, exists := pages[tab]; !exists && len(tabs) >= maxTabs {
		panic(invalid("tab"))
	}
}

// checkPost enforces the slug, a one-line title, and the body size. Title
// and body must each show something.
func checkPost(slug, title, body string) {
	if !validName(slug, maxSlugBytes) {
		panic(invalid("slug"))
	}
	checkLine("title", title, 1, maxTitleRunes)
	if !hasVisible(title) {
		panic(invalid("title"))
	}
	if len(body) > maxPageBytes || !utf8.ValidString(body) || !hasVisible(body) {
		panic(invalid("body"))
	}
}

// seqKey zero-pads n so that keys sort in number order.
func seqKey(n int) string {
	s := strconv.Itoa(n)
	return strings.Repeat("0", seqWidth-len(s)) + s
}

func touch() { updated = runtime.ChainHeight() }

// ----- owner only -----

// SetNow sets the one-line status shown on Home; empty clears it.
func SetNow(cur realm, text string) {
	runtime.AssertOriginCall()
	assertOwner(cur)
	checkLine("text", text, 0, maxLineRunes)
	now = nowLine{text: text, height: runtime.ChainHeight()}
	touch()
	chain.Emit("NowSet", "text", text)
}

// SetProfile sets the name and tagline drawn on the banner.
func SetProfile(cur realm, name, tagline string) {
	runtime.AssertOriginCall()
	assertOwner(cur)
	checkLine("name", name, 1, 24)
	checkLine("tagline", tagline, 0, 60)
	profile = profileData{name: name, tagline: tagline}
	touch()
	chain.Emit("ProfileSet", "name", name, "tagline", tagline)
}

// SetBadges replaces every badge. One badge per line: "label | value | url";
// a blank line starts a new row.
func SetBadges(cur realm, spec string) {
	runtime.AssertOriginCall()
	assertOwner(cur)
	badges = parseBadges(spec)
	touch()
	chain.Emit("BadgesSet", "count", strconv.Itoa(len(badges)))
}

// SetPage creates or replaces any tab's markdown, Blog and Guestbook
// included. A new tab goes just before Guestbook, which stays last.
func SetPage(cur realm, tab, md string) {
	runtime.AssertOriginCall()
	assertOwner(cur)
	checkPage(tab, md)
	if _, exists := pages[tab]; !exists {
		tabs = append(tabs[:len(tabs)-1], tab, guestbookTab) // guestbook stays last
	}
	pages[tab] = md
	touch()
	chain.Emit("PageSet", "tab", tab)
}

// RemovePage removes any tab except home, blog and guestbook.
func RemovePage(cur realm, tab string) {
	runtime.AssertOriginCall()
	assertOwner(cur)
	if tab == homeTab || tab == blogTab || tab == guestbookTab {
		panic(errTabsRequired)
	}
	if _, ok := pages[tab]; !ok {
		panic(errNoTab)
	}
	delete(pages, tab)
	kept := make([]string, 0, len(tabs)-1)
	for _, t := range tabs {
		if t != tab {
			kept = append(kept, t)
		}
	}
	tabs = kept
	touch()
	chain.Emit("PageRemoved", "tab", tab)
}

// SetPost publishes a post, or edits the post at slug. An edit keeps the
// post's place in the list and its publish date.
func SetPost(cur realm, slug, title, body string) {
	runtime.AssertOriginCall()
	assertOwner(cur)
	checkPost(slug, title, body)
	today := time.Now().UTC().Format("2006-01-02")
	touch()
	if p, ok := posts.Get(slug).(*post); ok {
		p.title, p.body, p.edited = title, body, today
		chain.Emit("PostEdited", "slug", slug)
		return
	}
	postSeq++
	seq := seqKey(postSeq)
	posts.Set(slug, &post{title: title, body: body, published: today, seq: seq})
	postOrder.Set(seq, slug)
	chain.Emit("PostPublished", "slug", slug)
}

// RemovePost deletes a post for good; its slug can be used again.
func RemovePost(cur realm, slug string) {
	runtime.AssertOriginCall()
	assertOwner(cur)
	v, ok := posts.Remove(slug)
	if !ok {
		panic(errNoPost)
	}
	postOrder.Remove(v.(*post).seq)
	touch()
	chain.Emit("PostRemoved", "slug", slug)
}

// Hide hides an author's guestbook entry for good. The entry stays stored,
// so the author can't sign again, and nobody's deposit is refunded. Hiding
// a hidden entry does nothing.
func Hide(cur realm, author address) {
	runtime.AssertOriginCall()
	assertOwner(cur)
	assertMasterKey()
	e, ok := entries.Get(author.String()).(*entry)
	if !ok {
		panic(errNoEntry)
	}
	if e.hidden {
		return
	}
	e.hidden = true
	touch()
	chain.Emit("EntryHidden", "author", author.String())
}

// TransferOwnership records newOwner as pending; nothing changes until that
// address calls AcceptOwnership. Naming the current owner cancels.
func TransferOwnership(cur realm, newOwner address) {
	runtime.AssertOriginCall()
	assertOwner(cur)
	assertMasterKey()
	if !newOwner.IsValid() {
		panic(invalid("newOwner"))
	}
	touch()
	if newOwner == owner {
		pendingOwner = ""
		chain.Emit("OwnershipTransferCanceled", "owner", owner.String())
		return
	}
	pendingOwner = newOwner
	chain.Emit("OwnershipTransferStarted", "from", owner.String(), "to", newOwner.String())
}

// AcceptOwnership completes a transfer. Only the pending owner may call it,
// and a realm address can't pass the account guard, so it never can.
func AcceptOwnership(cur realm) {
	runtime.AssertOriginCall()
	caller := callerOf(cur)
	if pendingOwner == "" || caller != pendingOwner {
		panic(errPendingOnly)
	}
	prev := owner
	owner = caller
	pendingOwner = ""
	touch()
	chain.Emit("OwnershipTransferred", "from", prev.String(), "to", caller.String())
}

// ----- visitors -----

// Wave adds one to the wave count. It's a plain counter: anyone can wave
// again, and a wave stores nothing but the count.
func Wave(cur realm) {
	runtime.AssertOriginCall()
	from := callerOf(cur).String()
	waves++
	chain.Emit("Waved", "from", from)
}

// Sign leaves one guestbook entry per address. The message is stored trimmed
// and sanitized when rendered, and must contain a visible character.
func Sign(cur realm, msg string) {
	runtime.AssertOriginCall()
	caller := callerOf(cur)
	if len(msg) > maxSignBytes {
		panic(invalid("msg"))
	}
	msg = strings.TrimSpace(msg)
	checkLine("msg", msg, 1, maxLineRunes)
	if !hasVisible(msg) {
		panic(invalid("msg")) // the entry would show up blank
	}
	key := caller.String()
	if entries.Has(key) {
		panic(errSigned)
	}
	entries.Set(key, &entry{msg: msg, height: runtime.ChainHeight()})
	order.Set(seqKey(order.Size()+1), caller)
	chain.Emit("Signed", "from", key)
}

// Tip forwards exactly the ugnot sent with this call to the owner. The
// account guard is inlined so the audit harness sees it next to OriginSend.
// It forwards what was sent, never the realm's balance: the OriginSend
// banker refuses to spend more than was sent.
func Tip(cur realm) {
	runtime.AssertOriginCall()
	if !cur.IsCurrent() || !cur.Previous().IsUserCall() {
		panic(errUnauthorized)
	}
	sent := unsafe.OriginSend()
	if len(sent) != 1 || sent[0].Denom != "ugnot" || sent[0].Amount <= 0 {
		panic(errUgnotOnly)
	}
	banker.NewBanker(banker.BankerTypeOriginSend, cur).SendCoins(cur.Address(), owner, sent)
	tips.count++
	tips.total += sent[0].Amount
	chain.Emit("Tipped", "from", cur.Previous().Address().String(), "amount", strconv.FormatInt(sent[0].Amount, 10))
}
