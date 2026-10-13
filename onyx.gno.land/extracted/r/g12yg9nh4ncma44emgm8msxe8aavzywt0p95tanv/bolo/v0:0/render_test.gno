package bolo

import (
	"chain"
	"math"
	"strconv"
	"strings"
	"testing"

	"gno.land/p/nt/markdown/sanitize/v0"
	"gno.land/p/nt/seqid/v0"
	"gno.land/p/nt/testutils/v0"
)

func TestGnot(t *testing.T) {
	for ugnot, want := range map[int64]string{
		0: "0 GNOT", 1: "0.000001 GNOT", 1_500_000: "1.5 GNOT", 5_000_000: "5 GNOT",
		1_234_567: "1.234567 GNOT", 10_000_010: "10.00001 GNOT", -2_500_000: "-2.5 GNOT",
	} {
		if got := gnot(ugnot); got != want {
			t.Errorf("gnot(%d) = %q, want %q", ugnot, got, want)
		}
	}
	if got := when(0); got != "1970-01-01 00:00 UTC" {
		t.Errorf("when(0) = %q", got)
	}
	for n, want := range map[int]string{0: "0 donors", 1: "1 donor", 2: "2 donors"} {
		if got := count(n, "donor", "donors"); got != want {
			t.Errorf("count(%d) = %q, want %q", n, got, want)
		}
	}
}

func TestParsers(t *testing.T) {
	for s, want := range map[string]int{"1": 1, "20": 20, "999999999": 999999999} {
		if n, ok := parsePage(s); !ok || n != want {
			t.Errorf("parsePage(%q) = %d, %t", s, n, ok)
		}
	}
	for _, s := range []string{"", "0", "01", "-1", "+1", "1x", " 1", "1000000000"} {
		if _, ok := parsePage(s); ok {
			t.Errorf("parsePage(%q) accepted", s)
		}
	}
	good := testutils.TestAddress("renderer").String()
	if _, ok := parseAddress(good); !ok {
		t.Errorf("parseAddress refused %s", good)
	}
	last := "q"
	if good[39:] == "q" {
		last = "p"
	}
	badSum := good[:39] + last // 40 characters, a lowercase "g", a wrong checksum
	for _, s := range []string{"", "notanaddress", strings.ToUpper(good), good[:39], good + "x", badSum} {
		if _, ok := parseAddress(s); ok {
			t.Errorf("parseAddress(%q) accepted", s)
		}
	}
	if q, ok := parseQuery("page=2&&size=1000000&x"); !ok || q["page"] != "2" || q["size"] != "1000000" {
		t.Errorf("parseQuery: %v, %t", q, ok)
	}
	if _, ok := parseQuery("page=1&page=2"); ok {
		t.Errorf("parseQuery accepted a key twice")
	}
}

// TestRenderNotFound: every path that fails gets the one not-found page, which echoes
// nothing from the request (API §5).
func TestRenderNotFound(t *testing.T) {
	c := testCampaign(9961, modeEscrow, 0)
	id, unstore := storeCampaign(c)
	defer unstore()
	c.receipts.Set(seqid.ID(1).Binary(), &receipt{seq: 1, donor: testutils.TestAddress("donor"), amount: 5})
	bad := []string{
		"c/0" + id, "c/x", "c/" + id + "/", "c/" + id + "/r/x", "c/" + id + "/r/0", "c/" + id + "/r/2",
		"c/" + id + "/donations?page=-1", "c/" + id + "/donations?page=0", "c/" + id + "/ledger?page=x",
		"c/" + id + "/updates?page=1&page=2", "c/" + id + "/nope", "c/99999", "c/", "c/" + id + "/r/1/x",
		"u/notanaddress", "u/" + strings.ToUpper(testutils.TestAddress("renderer").String()),
		"u/" + testutils.TestAddress("renderer").String() + "/nope",
		"u/" + testutils.TestAddress("renderer").String() + "/gave?after=0x",
		"?after=x", "?after=", "?cat=nope", "?cat=", "c?cat=nope", "c/" + id + "/r?page=0", "u/", "u?address=a&address=b",
		"about/x", "x", "/", "//", strings.Repeat("c/", 200),
	}
	for _, path := range bad {
		if got := Render(path); got != notFound {
			t.Errorf("Render(%q) isn't the not-found page:\n%s", path, got)
		}
	}
	// A key the route doesn't take is ignored.
	if Render("c/"+id+"/donations?size=1000000") == notFound || Render("?page=-1") == notFound {
		t.Errorf("an ignored key made the page fail")
	}
}

// injection is what a stranger, a moderator or an organizer might write to pass for
// Bolo, plant a link, an image, raw HTML or a mention, open an alert or one of
// gnoweb's blocks, hide characters, or break out of their slot — shapes the writes'
// own checks let through, the hidden characters stripped (API §2.3).
const injection = "[!WARNING] [Verify](https://evil.example) **BOLO** # x | y ] ) ! <b>raw</b> ![i](https://evil.example/i.png) \u200b\u202e @bolo_help </gno-columns> <gno-columns-sep> <gno-form path=\"u\">"

// mention reports whether s holds what gnoweb makes a link of on its own: an "@" no
// backslash escapes, or an address after a space or opening a line's text.
func mention(s string) bool {
	for i := 0; i < len(s); i++ {
		if s[i] == '@' && (i == 0 || s[i-1] != '\\') {
			return true
		}
	}
	for _, line := range strings.Split(s, "\n") {
		if strings.HasPrefix(strings.TrimLeft(line, "#>- "), "g1") {
			return true
		}
	}
	return strings.Contains(s, " g1")
}

// ownTags reports whether every tag of gnoweb's blocks in s that isn't escaped stands
// on a line of its own, as Bolo writes them — the only place gnoweb reads one — and the
// columns open as often as they close.
func ownTags(s string) bool {
	lines := map[string]bool{"<gno-columns>": true, "<gno-columns-sep />": true, "</gno-columns>": true,
		"<gno-form path=\"u\">": true, "  <gno-input name=\"address\" placeholder=\"g1…\" />": true, "</gno-form>": true}
	for _, line := range strings.Split(s, "\n") {
		own := lines[line] || line == "  <gno-input name=\"amount\" placeholder=\"7.5\" />" ||
			strings.HasPrefix(line, "<gno-form path=\"c/") && strings.HasSuffix(line, "/give\">") && isDigits(line[len("<gno-form path=\"c/"):len(line)-len("/give\">")])
		for i := 0; i+5 <= len(line); i++ {
			if (line[i:i+5] == "<gno-" || line[i:i+5] == "</gno") && (i == 0 || line[i-1] != '\\') && !own {
				return false
			}
		}
	}
	return strings.Count(s, "\n<gno-columns>\n") == strings.Count(s, "\n</gno-columns>\n")
}

// isDigits reports whether s is one or more decimal digits.
func isDigits(s string) bool {
	for i := 0; i < len(s); i++ {
		if s[i] < '0' || s[i] > '9' {
			return false
		}
	}
	return s != ""
}

// TestRenderEscapes: every text slot is escaped by who wrote it. Strangers' and
// moderators' text can carry no link, no image, no mention and none of gnoweb's
// blocks; the organizer's story and updates stay inside their quote, below Bolo's own
// blocks; the alerts are Bolo's — the notice on the campaign's page, the refund banner
// on a refunded gift's receipt — which no user text can open; addresses sit in code
// spans (API §5).
func TestRenderEscapes(t *testing.T) {
	phisher := testutils.TestAddress("phisher").String()
	inj := phisher + " " + injection + " " + phisher
	story := "[!WARNING] Notice from Bolo's moderator\nHelp us.\n## Check it yourself\n- Escrow: `g1fake`\n| a | b |\n[ok](https://ok.example) @bolo_help"
	body := "## Act\n[Give 5 GNOT](https://evil.example)"
	donor := testutils.TestAddress("donor")
	c := testCampaign(9962, modeEscrow, 0)
	c.text.title, c.text.description = inj, story
	c.text.imageCID, c.text.imageAlt = "QmYwAPJzv5CZsnA625s3Xf2nemtYgPpHdWEz79ojWnPbdG", inj
	c.state.notice = inj
	id, unstore := storeCampaign(c)
	defer unstore()
	c.receipts.Set(seqid.ID(1).Binary(), &receipt{seq: 1, donor: donor, amount: 5, message: inj})
	c.state.donationCount, c.state.recent[0], c.state.recentNext = 1, 1, 1
	c.updates.Set(seqid.ID(1).Binary(), &update{seq: 1, body: body})
	c.state.updateCount = 1
	c.contributions.Set(donor.String(), &contribution{amount: 5, refunded: 1, public: true})
	c.refunds.Set(seqid.ID(1).Binary(), &refund{seq: 1, amount: 1, donor: donor, kind: "open"})
	c.withdrawals.Set(seqid.ID(1).Binary(), &withdrawal{seq: 1, amount: 1, to: c.beneficiary})
	byOrganizer.Set(c.organizer.String()+"/"+c.id.Binary(), true)
	defer byOrganizer.Remove(c.organizer.String() + "/" + c.id.Binary())

	org := "u/" + c.organizer.String()
	for _, path := range []string{"c/" + id, "c/" + id + "/r/1", "c/" + id + "/donations", "c/" + id + "/updates", "c/" + id + "/ledger", "c/" + id + "/give", "c/" + id + "/give?amount=5", "?cat=water", org, org + "/organized"} {
		out := Render(path)
		// The organizer's own text, quoted, keeps its links and mentions: without it,
		// nothing on the page may carry one.
		rest := strings.ReplaceAll(strings.ReplaceAll(out, sanitize.Blockquote(story), ""), sanitize.Blockquote(body), "")
		if strings.Contains(rest, "](https://") || mention(rest) {
			t.Errorf("%s: a link, an image or a mention outside the organizer's quote:\n%s", path, rest)
		}
		if strings.Contains(strings.ReplaceAll(rest, `\<`, ""), "<b>") || strings.ContainsAny(rest, "\u200b\u202e") {
			t.Errorf("%s: raw HTML or a hidden character outside the organizer's quote:\n%s", path, rest)
		}
		if !ownTags(rest) {
			t.Errorf("%s: a block's tag Bolo didn't write:\n%s", path, rest)
		}
		alerts, entities := 0, 0
		switch path {
		case "c/" + id:
			alerts, entities = 1, 2
			if !strings.HasPrefix(out, "> [!WARNING] Notice from Bolo's moderator\n> ") {
				t.Errorf("the notice isn't the alert at the top of the page:\n%s", out)
			}
		case "c/" + id + "/r/1":
			alerts = 1
			if !strings.HasPrefix(out, "> [!CAUTION] Refunded since\n> 0.000001 GNOT went back to this donor after this gift.\n\n# Gift receipt") {
				t.Errorf("the refund banner isn't the alert at the top of the receipt:\n%s", out)
			}
		}
		if n := strings.Count("\n"+out, "\n> [!"); n != alerts {
			t.Errorf("%s: %d alerts, want %d", path, n, alerts)
		}
		// The title's heading and the notice's line open with an address; nothing
		// else may write its "g" as an entity, which a table of contents shows as is.
		if n := strings.Count(out, "&#103;"); n != entities {
			t.Errorf("%s: %d entities, want %d", path, n, entities)
		}
	}
	page := Render("c/" + id)
	verifyAt, storyAt := strings.Index(page, "## Check it yourself\n\n- **Escrow** `g1"), strings.Index(page, "## In the organizer's words")
	if verifyAt < 0 || storyAt < 0 || verifyAt > storyAt {
		t.Errorf("the verification block isn't before the story: %d, %d", verifyAt, storyAt)
	}
	if !strings.Contains(page, "## In the organizer's words\n"+sanitize.Blockquote(story)) {
		t.Errorf("the story isn't quoted under its heading:\n%s", page)
	}
	if !strings.Contains(page, "](ipfs://QmYwAPJzv5CZsnA625s3Xf2nemtYgPpHdWEz79ojWnPbdG)") {
		t.Errorf("the photo is missing:\n%s", page)
	}
}

// TestRenderHiddenPhoto: a hidden photo is gone from the campaign's page, its
// description with it (API §3.1, §3.5, §5).
func TestRenderHiddenPhoto(t *testing.T) {
	c := testCampaign(9968, modeEscrow, 0)
	c.text.imageCID, c.text.imageAlt = "QmYwAPJzv5CZsnA625s3Xf2nemtYgPpHdWEz79ojWnPbdG", "The village well"
	id, unstore := storeCampaign(c)
	defer unstore()
	if page := Render("c/" + id); !strings.Contains(page, "![The village well](ipfs://") {
		t.Errorf("the photo is missing:\n%s", page)
	}
	c.state.imageHidden = true
	if page := Render("c/" + id); strings.Contains(page, "ipfs://") || strings.Contains(page, "The village well") {
		t.Errorf("a hidden photo is still on the page:\n%s", page)
	}
}

// TestRenderDelisted: a delisted campaign shows its notice and no donate links, and is
// on no list that promotes (API §5).
func TestRenderDelisted(t *testing.T) {
	org := testutils.TestAddress("renderorg")
	cs, unindex := indexCampaigns(9963, 2, org, org)
	defer unindex()
	off := cs[0]
	off.state.listed, off.state.notice = false, "Under review"
	dropActive(off)
	defer addActive(off)
	if page := Render("c/9963"); !strings.Contains(page, "Under review") || strings.Contains(page, "## Give") || strings.Contains(page, "func=Donate&id=9963&tip") {
		t.Errorf("a delisted campaign's page:\n%s", page)
	}
	if !strings.Contains(Render("c/9964"), "## Give") {
		t.Errorf("a listed campaign has no donate links")
	}
	for _, path := range []string{"u/" + org.String(), "u/" + org.String() + "/organized"} {
		if addr := Render(path); strings.Contains(addr, ":c/9963)") || !strings.Contains(addr, ":c/9964)") {
			t.Errorf("%s lists the delisted campaign, or misses the listed one:\n%s", path, addr)
		}
	}
	if home := Render("?cat=animals"); strings.Contains(home, ":c/9963)") || !strings.Contains(home, ":c/9964)") {
		t.Errorf("the home page:\n%s", home)
	}
}

// TestRenderBounds: a path longer than any valid one gets the not-found page before it
// is parsed, and a page's size never comes from the query: ?size= is ignored (API §5).
func TestRenderBounds(t *testing.T) {
	if got := Render("?pad=" + strings.Repeat("a", 300)); got != notFound {
		t.Errorf("a 305-byte path rendered")
	}
	c := testCampaign(9965, modeEscrow, 0)
	id, unstore := storeCampaign(c)
	defer unstore()
	for i := 1; i <= 25; i++ {
		c.receipts.Set(seqid.ID(i).Binary(), &receipt{seq: uint64(i), donor: testutils.TestAddress("donor"), amount: 5})
	}
	if n := strings.Count(Render("c/"+id+"/donations?size=50"), "[receipt]("); n != 20 {
		t.Errorf("?size=50: %d gifts on the page, want 20", n)
	}
	if n := strings.Count(Render("c/"+id+"/donations?page=2"), "[receipt]("); n != 5 {
		t.Errorf("page 2: %d gifts, want 5", n)
	}
}

// TestRenderGiveLinks: the one-click donate links appear only while the campaign is
// open, listed, and Bolo isn't paused (API §5).
func TestRenderGiveLinks(t *testing.T) {
	c := testCampaign(9966, modeEscrow, 0)
	id, unstore := storeCampaign(c)
	defer unstore()
	defer func() { paused = false }()
	give := func() bool { return strings.Contains(Render("c/"+id), "## Give") }
	if !give() {
		t.Errorf("an open, listed campaign has no donate links")
	}
	paused = true
	if give() {
		t.Errorf("donate links while Bolo is paused")
	}
	paused = false
	c.deadline = now() - 1
	if give() {
		t.Errorf("donate links past the deadline")
	}
	c.deadline = 0
	c.state.status = statusClosed
	if give() {
		t.Errorf("donate links on a closed campaign")
	}
}

// TestRenderActLinks: Withdraw is offered only while the escrow holds coins, and Close
// whenever someone could close: the organizer while the campaign is open, anyone once
// CanClose says so (API §5).
func TestRenderActLinks(t *testing.T) {
	c := testCampaign(9967, modeEscrow, 0)
	id, unstore := storeCampaign(c)
	defer unstore()
	page := func() string { return Render("c/" + id) }
	closeBy := func(who string) string { return "func=Close&id=" + id + "): " + who }
	if p := page(); strings.Contains(p, "[Withdraw](") || !strings.Contains(p, closeBy("the organizer")) {
		t.Errorf("an empty escrow offers Withdraw, or the organizer can't close:\n%s", p)
	}
	testing.IssueCoins(escrowAddr(c.id), chain.NewCoins(chain.NewCoin("ugnot", 5)))
	if p := page(); !strings.Contains(p, "[Withdraw](") {
		t.Errorf("an escrow holding coins offers no Withdraw:\n%s", p)
	}
	c.deadline = now() - 1 // passed, not recorded: anyone may close
	if p := page(); !strings.Contains(p, closeBy("anyone")) {
		t.Errorf("a passed deadline nobody recorded offers no Close to anyone:\n%s", p)
	}
	c.deadline, c.state.status = 0, statusClosed
	if p := page(); strings.Contains(p, "[Close](") {
		t.Errorf("a closed campaign offers Close:\n%s", p)
	}
	// Withdraw stops when the beneficiary's window ends; Finalize appears when it can.
	c.state.raised, c.state.withdrawn, c.state.everWithdrawn, c.state.closedAt = 7_000_000, 2_000_000, true, now()
	testing.IssueCoins(escrowAddr(c.id), chain.NewCoins(chain.NewCoin("ugnot", 5_000_000))) // the 5 GNOT the books hold
	if p := page(); !strings.Contains(p, "[Withdraw](") || strings.Contains(p, "[Finalize](") {
		t.Errorf("closed, the beneficiary's window running: no Withdraw, or a Finalize:\n%s", p)
	}
	c.state.closedAt = now() - c.params.ExitDelay
	if p := page(); strings.Contains(p, "[Withdraw](") || !strings.Contains(p, "func=Finalize&id="+id+"): anyone") {
		t.Errorf("closed, the beneficiary's window over: a Withdraw, or no Finalize:\n%s", p)
	}
}

// TestRenderEmptyPages: a page with nothing to show says so, and says "None on this
// page." on a later page or when a "More" follows — the home page once its read budget
// went on passed deadlines, an address list whose newest are all delisted, a campaign's
// own lists past their first page (API §5).
func TestRenderEmptyPages(t *testing.T) {
	org := testutils.TestAddress("emptyorg")
	if home := Render("?cat=animals"); !strings.Contains(home, "No campaigns here yet.") {
		t.Errorf("an empty category:\n%s", home)
	}
	if later := Render("?cat=animals&after=1"); !strings.Contains(later, "None on this page.") || strings.Contains(later, "[More](") {
		t.Errorf("a later page with nothing on it:\n%s", later)
	}
	cs, unindex := indexCampaigns(9600, 4*listPage+1, org, org)
	defer unindex()
	for _, c := range cs {
		c.deadline = now() - 1
	}
	if home := Render("?cat=animals"); !strings.Contains(home, "None on this page.") || !strings.Contains(home, "[More](") {
		t.Errorf("a page of passed deadlines, with more to read:\n%s", home)
	}
	for _, c := range cs {
		c.state.listed = false
	}
	for _, p := range []string{"u/" + org.String(), "u/" + org.String() + "/organized"} {
		if page := Render(p); !strings.Contains(page, "None on this page.") || !strings.Contains(page, "[More](") {
			t.Errorf("%s: a page of delisted campaigns, with more to come:\n%s", p, page)
		}
	}
	other := "u/" + testutils.TestAddress("nobody").String() + "/organized"
	if first, later := Render(other), Render(other+"?after=1"); !strings.Contains(first, "None.") || !strings.Contains(later, "None on this page.") {
		t.Errorf("an empty address list, first and later pages:\n%s\n%s", first, later)
	}
	c := testCampaign(9969, modeEscrow, 0)
	id, unstore := storeCampaign(c)
	defer unstore()
	for route, first := range map[string]string{"donations": "No gifts yet.", "ledger": "None.\n\n## Refunds\n\nNone.", "updates": "No updates yet."} {
		later := strings.ReplaceAll(strings.ReplaceAll(first, "yet.", "on this page."), "None.", "None on this page.")
		if p1, p2 := Render("c/"+id+"/"+route), Render("c/"+id+"/"+route+"?page=2"); !strings.Contains(p1, first) || !strings.Contains(p2, later) {
			t.Errorf("an empty %s list, pages 1 and 2:\n%s\n%s", route, p1, p2)
		}
	}
	var b strings.Builder
	writeListed(&b, []CampaignView{{Listed: false}}, true)
	if b.String() != "None on this page.\n\n" {
		t.Errorf("a list of delisted campaigns with more to come: %q", b.String())
	}
	b.Reset()
	writeListed(&b, nil, false)
	if b.String() != "None.\n\n" {
		t.Errorf("an empty list: %q", b.String())
	}
}

// giveTo records a public gift of amount ugnot from donor to c, as Donate would for
// the pages to show: its receipt, the recent gifts, the counts, the donor's
// contribution, and the donor's list.
func giveTo(c *campaign, seq uint64, donor address, amount int64) {
	s := c.state
	c.receipts.Set(seqid.ID(seq).Binary(), &receipt{seq: seq, donor: donor, amount: amount, at: now(), message: "Courage"})
	s.recent[s.recentNext%recentSize] = seq
	s.recentNext++
	s.donationCount++
	s.donorCount++
	s.raised += amount
	c.contributions.Set(donor.String(), &contribution{amount: amount, public: true})
	byDonor.Set(donor.String()+"/"+c.id.Binary(), true)
}

// pageLinks returns the paths of a page's links to Bolo's own pages, and the
// functions its transaction links call.
func pageLinks(page string) (paths, funcs []string) {
	at := "](" + webPath
	for i := strings.Index(page, at); i >= 0; i = strings.Index(page, at) {
		page = page[i+len(at):]
		end := strings.Index(page, ")")
		target := page[:end]
		switch {
		case target == "":
			paths = append(paths, "")
		case target[0] == ':':
			paths = append(paths, target[1:])
		case strings.HasPrefix(target, "$help&func="):
			name, _, _ := strings.Cut(strings.TrimPrefix(target, "$help&func="), "&")
			funcs = append(funcs, name)
		}
	}
	return paths, funcs
}

// TestRenderLinks: every link a page writes leads to a page, every transaction link
// calls one of Bolo's writes, and every prefix of every path renders a page too, as
// gnoweb's header links each one (UI spec §4.13) — on campaigns of each kind.
func TestRenderLinks(t *testing.T) {
	org, ben, donor := testutils.TestAddress("linkorg"), testutils.TestAddress("linkben"), testutils.TestAddress("linkdonor")
	cs, unindex := indexCampaigns(9700, 4, org, ben)
	defer unindex()
	open, direct, closed, settled := cs[0], cs[1], cs[2], cs[3]
	direct.mode = modeDirect
	closed.state.status, closed.state.closedAt, closed.state.closeReason = statusClosed, now(), reasonOrganizer
	settled.state.status, settled.state.closedAt, settled.state.closeReason = statusSettled, now(), reasonOrganizer
	dropActive(closed)
	dropActive(settled)
	for _, c := range cs {
		giveTo(c, 1, donor, 5_000_000)
		defer byDonor.Remove(donor.String() + "/" + c.id.Binary())
	}
	open.updates.Set(seqid.ID(1).Binary(), &update{seq: 1, at: now(), body: "Started."})
	open.state.updateCount = 1
	open.withdrawals.Set(seqid.ID(1).Binary(), &withdrawal{seq: 1, amount: 1_000_000, at: now(), to: ben})
	open.state.withdrawn, open.state.everWithdrawn = 1_000_000, true
	closed.refunds.Set(seqid.ID(1).Binary(), &refund{seq: 1, amount: 1_000_000, at: now(), donor: donor, kind: windowOpen})
	closed.state.refunded = 1_000_000
	for _, c := range cs { // the bank holds what the books say
		if held := trackedBalance(c); held > 0 {
			testing.IssueCoins(escrowAddr(c.id), chain.NewCoins(chain.NewCoin("ugnot", held)))
		}
	}

	writes := map[string]bool{"Donate": true, "Refund": true, "Withdraw": true, "Close": true, "Finalize": true, "PostUpdate": true, "CreateCampaign": true}
	seen := map[string]bool{}
	queue := []string{"", "about", "params", "u", "u?address=" + donor.String(), "u?address=nope", "c/9700/give?amount=7.5", "c/9700/give?amount=nope"}
	for _, c := range cs {
		queue = append(queue, "c/"+idString(c.id)+"/r/1")
	}
	for len(queue) > 0 {
		path := queue[0]
		queue = queue[1:]
		if seen[path] {
			continue
		}
		seen[path] = true
		page := Render(path)
		if page == notFound {
			t.Errorf("%q: not found", path)
			continue
		}
		paths, funcs := pageLinks(page)
		for _, f := range funcs {
			if !writes[f] {
				t.Errorf("%q links to a transaction calling %q", path, f)
			}
		}
		route, _, _ := strings.Cut(path, "?")
		segs := strings.Split(route, "/")
		for i := 1; i < len(segs); i++ {
			paths = append(paths, strings.Join(segs[:i], "/"))
		}
		queue = append(queue, paths...)
	}
	for _, want := range []string{"c", "c/9700", "c/9700/r", "c/9700/give", "c/9700/donations", "c/9700/ledger", "c/9700/updates", "u", "u/" + org.String(), "u/" + ben.String(), "u/" + donor.String()} {
		if !seen[want] {
			t.Errorf("no link or prefix reaches %q", want)
		}
	}
}

// TestRenderPrefixes: the prefixes gnoweb's header links render the pages they stand
// for: "c" the home page, "c/{id}/r" the campaign's gifts (UI spec §4.13).
func TestRenderPrefixes(t *testing.T) {
	c := testCampaign(9971, modeEscrow, 0)
	id, unstore := storeCampaign(c)
	defer unstore()
	if Render("c") != Render("") || Render("c?cat=water") != Render("?cat=water") {
		t.Errorf("c isn't the home page")
	}
	if Render("c/"+id+"/r") != Render("c/"+id+"/donations") || Render("c/"+id+"/r?page=2") != Render("c/"+id+"/donations?page=2") {
		t.Errorf("c/%s/r isn't the gifts page", id)
	}
}

// TestRenderLookup: "u" is a form to find an address, which submits back as
// ?address=: a valid address gets its page, anything else the form again with one
// fixed line, echoing nothing (API §5).
func TestRenderLookup(t *testing.T) {
	form := Render("u")
	if !strings.Contains(form, "# Find an address") || !strings.Contains(form, "\n<gno-form path=\"u\">\n  <gno-input name=\"address\" placeholder=\"g1…\" />\n</gno-form>\n") || strings.Contains(form, "isn't") {
		t.Errorf("the lookup page:\n%s", form)
	}
	good := testutils.TestAddress("lookedup").String()
	if got := Render("u?address=" + good); got != Render("u/"+good) {
		t.Errorf("a valid address doesn't get its page:\n%s", got)
	}
	for _, bad := range []string{"", "notanaddress", strings.ToUpper(good), good + "x", "%3Cb%3Eecho%3C/b%3E", "<b>echo</b>"} {
		got := Render("u?address=" + bad)
		if !strings.Contains(got, "That isn't a gno.land address.") || !strings.Contains(got, "<gno-form") {
			t.Errorf("u?address=%s: no form, or no line saying why:\n%s", bad, got)
		}
		if bad != "" && strings.Contains(got, bad) {
			t.Errorf("u?address=%s: the page echoes it:\n%s", bad, got)
		}
	}
}

// TestRenderGiveRoom: the donate links offer only what Donate would take — the presets
// within the room the escrow cap leaves, and the room said — and none, with a banner,
// when not even the smallest gift fits (API §5).
func TestRenderGiveRoom(t *testing.T) {
	c := testCampaign(9972, modeEscrow, 0)
	id, unstore := storeCampaign(c)
	defer unstore()
	saved := escrowCap
	defer func() { escrowCap = saved }()
	presetLink := func(page string, ugnot int64) bool {
		return strings.Contains(page, "&.send="+strconv.FormatInt(ugnot, 10)+"ugnot&")
	}
	escrowCap = 30_000_000
	c.state.raised = 12_000_000 // 18 GNOT of room
	page := Render("c/" + id)
	if !presetLink(page, 5_000_000) || !presetLink(page, 10_000_000) || presetLink(page, 20_000_000) || presetLink(page, 50_000_000) {
		t.Errorf("presets past the room, or none within it:\n%s", page)
	}
	if !strings.Contains(page, "[Another amount](/r/g12yg9nh4ncma44emgm8msxe8aavzywt0p95tanv/bolo/v0:c/"+id+"/give)") || !strings.Contains(page, "It can take 18 GNOT more for now") {
		t.Errorf("no other amount, or the room isn't said:\n%s", page)
	}
	c.state.raised = 29_500_000 // half a GNOT: less than the smallest gift
	page = Render("c/" + id)
	if strings.Contains(page, "## Give") || !strings.Contains(page, "> [!NOTE] Full for now\n") {
		t.Errorf("donate links with no room, or no banner:\n%s", page)
	}
	escrowCap = 0
	if page = Render("c/" + id); !presetLink(page, 50_000_000) || strings.Contains(page, "It can take") {
		t.Errorf("no cap, yet a preset left out or a room said:\n%s", page)
	}
	escrowCap = 30_000_000
	c.mode = modeDirect // the cap is escrow's
	if page = Render("c/" + id); !presetLink(page, 50_000_000) || strings.Contains(page, "Full for now") {
		t.Errorf("a direct campaign held to the escrow cap:\n%s", page)
	}
	// The room is the cap less the tracked balance, never the bank's, and a preset
	// under the smallest gift is left out too.
	c.mode = modeEscrow
	c.state.raised, c.state.withdrawn, c.state.refunded, c.state.everWithdrawn = 40_000_000, 20_000_000, 2_000_000, true // 18 GNOT tracked
	testing.IssueCoins(escrowAddr(c.id), chain.NewCoins(chain.NewCoin("ugnot", 27_000_000)))                             // and 9 sent outside Bolo
	page = Render("c/" + id)
	if !presetLink(page, 5_000_000) || !presetLink(page, 10_000_000) || presetLink(page, 20_000_000) || !strings.Contains(page, "It can take 12 GNOT more for now") {
		t.Errorf("the room isn't the cap less the tracked balance:\n%s", page)
	}
	savedMin := minDonation
	minDonation = 7_000_000
	if page = Render("c/" + id); presetLink(page, 5_000_000) || !presetLink(page, 10_000_000) {
		t.Errorf("a preset under the smallest gift:\n%s", page)
	}
	minDonation = savedMin
	escrowCap = 23_000_000 // exactly 5 GNOT of room
	if page = Render("c/" + id); !presetLink(page, 5_000_000) || presetLink(page, 10_000_000) {
		t.Errorf("a preset equal to the room left out:\n%s", page)
	}
	escrowCap = 19_000_000 // room for exactly the smallest gift
	if page = Render("c/" + id); !strings.Contains(page, "## Give") || presetLink(page, 5_000_000) || !strings.Contains(page, "It can take 1 GNOT more for now") {
		t.Errorf("room for exactly the smallest gift:\n%s", page)
	}
}

// TestRenderBanner: the campaign's page shows the one state banner the UI spec's state
// matrix gives its state (§6), and none while nothing is out of the ordinary.
func TestRenderBanner(t *testing.T) {
	c := testCampaign(9973, modeEscrow, 0)
	id, unstore := storeCampaign(c)
	defer unstore()
	defer func() { paused = false }()
	banner := func() string {
		page := Render("c/" + id)
		if n := strings.Count("\n"+page, "\n> [!"); n > 1 {
			t.Errorf("%d banners:\n%s", n, page)
		}
		i := strings.Index(page, "> [!")
		if i < 0 {
			return ""
		}
		return page[i : i+strings.Index(page[i:], "\n\n")]
	}
	if b := banner(); b != "" {
		t.Errorf("an open campaign shows a banner: %q", b)
	}
	paused = true
	if b := banner(); !strings.HasPrefix(b, "> [!CAUTION] Bolo is paused\n") {
		t.Errorf("paused: %q", b)
	}
	paused = false
	saved, savedMin := escrowCap, minDonation
	escrowCap = 500_000 // below the smallest gift: no withdrawal makes room
	if b := banner(); b != "> [!NOTE] Full for now\n> Bolo's escrow cap is set below its smallest gift, so no campaign in escrow can take a gift for now." {
		t.Errorf("a cap below the smallest gift: %q", b)
	}
	escrowCap, c.state.raised = 2_000_000, 1_500_000 // half a GNOT of room, under the smallest gift
	if b := banner(); b != "> [!NOTE] Full for now\n> This campaign can't take more until the beneficiary withdraws." {
		t.Errorf("a full escrow: %q", b)
	}
	escrowCap = minDonation // a cap of exactly the smallest gift: a withdrawal makes room
	if b := banner(); b != "> [!NOTE] Full for now\n> This campaign can't take more until the beneficiary withdraws." {
		t.Errorf("a full escrow, its cap the smallest gift: %q", b)
	}
	escrowCap, minDonation, c.state.raised = saved, savedMin, 0
	c.params.DormancyPeriod = 30 * secondsPerDay // the campaign's own, not the live setting's 90
	c.createdAt = now() - c.params.DormancyPeriod
	if b := banner(); b != "> [!NOTE] Inactive\n> No gift and no update for 30 days: anyone can close it now." {
		t.Errorf("dormant: %q", b)
	}
	c.createdAt = now()
	s := c.state
	s.status, s.closedAt, s.closeReason, s.raised = statusClosed, now(), reasonOrganizer, 7_000_000
	if b := banner(); !strings.HasPrefix(b, "> [!NOTE] Closed to new donations\n> Closed by its organizer on ") || !strings.Contains(b, "The beneficiary can withdraw the 7 GNOT held until ") || !strings.Contains(b, ", 60 days left; after that, donors can reclaim their share.") {
		t.Errorf("closed, before the exit window: %q", b)
	}
	s.closedAt, s.everWithdrawn = now()-c.params.ExitDelay, true
	if b := banner(); !strings.Contains(b, "The beneficiary didn't collect in time: a donor who hasn't reclaimed their share yet can, at any time.") {
		t.Errorf("closed, the exit window open: %q", b)
	}
	s.closeReason = reasonDormant
	if b := banner(); !strings.Contains(b, "after 30 days with no gift and no update.") {
		t.Errorf("closed as dormant: %q", b)
	}
	s.closeReason, s.raised = reasonDeadline, 0
	if b := banner(); !strings.HasSuffix(b, "It ended at its deadline, on "+when(s.closedAt)+".") {
		t.Errorf("ended at its deadline, nothing held: %q", b)
	}
	s.status = statusSettled
	if b := banner(); b != "> [!SUCCESS] Completed\n> Closed to new donations on "+when(s.closedAt)+", then settled: the organizer's deposit went back to them." {
		t.Errorf("settled: %q", b)
	}
}

// TestRenderMode: the mode in words says what it means now, with the refund link
// while a refund window is open to some donor (UI spec §4.3).
func TestRenderMode(t *testing.T) {
	c := testCampaign(9974, modeEscrow, 0)
	id, unstore := storeCampaign(c)
	defer unstore()
	mode := func() string {
		page := Render("c/" + id)
		i := strings.Index(page, "\n**Escrow**: ")
		if i < 0 {
			i = strings.Index(page, "\n**Direct**: ")
		}
		if i < 0 {
			t.Fatalf("no mode line:\n%s", page)
		}
		return page[i+1 : i+1+strings.Index(page[i+1:], "\n")]
	}
	refund := " [Refund](/r/g12yg9nh4ncma44emgm8msxe8aavzywt0p95tanv/bolo/v0$help&func=Refund&id=" + id + ")"
	if m := mode(); m != "**Escrow**: the gifts stay in escrow until the beneficiary withdraws them. Until then, a donor can take their gift back." {
		t.Errorf("escrow, nothing given: %q", m)
	}
	c.state.raised = 5_000_000
	testing.IssueCoins(escrowAddr(c.id), chain.NewCoins(chain.NewCoin("ugnot", 5_000_000))) // the bank holds what the books say
	if m := mode(); !strings.HasSuffix(m, "a donor can take their gift back."+refund) {
		t.Errorf("escrow, gifts held, nothing withdrawn: %q", m)
	}
	c.state.status, c.state.closedAt = statusClosed, now() // closed, the beneficiary's window running
	if m := mode(); !strings.HasSuffix(m, "a donor can take their gift back."+refund) {
		t.Errorf("escrow, closed, nothing withdrawn, the window running: %q", m)
	}
	c.state.closedAt = now() - c.params.ExitDelay // never withdrawn, the window passed
	if m := mode(); m != "**Escrow**: "+"the beneficiary didn't collect in time, so a donor who hasn't reclaimed their share yet can, at any time."+refund {
		t.Errorf("escrow, the beneficiary's window passed with nothing withdrawn: %q", m)
	}
	c.state.status = statusSettled
	if m := mode(); m != "**Escrow**: "+"the beneficiary didn't collect in time, so a donor who hasn't reclaimed their share yet can, at any time."+refund {
		t.Errorf("escrow, settled with nothing withdrawn and coins held: %q", m)
	}
	c.state.refunded = 5_000_000 // every gift back: nothing held
	if m := mode(); m != "**Escrow**: no gift is held any more." {
		t.Errorf("escrow, settled, nothing held: %q", m)
	}
	c.state.status, c.state.closedAt = statusClosed, now()
	if m := mode(); m != "**Escrow**: no gift is held any more." {
		t.Errorf("escrow, closed, nothing held: %q", m)
	}
	c.state.status, c.state.closedAt, c.state.refunded = statusOpen, 0, 0
	c.state.withdrawn, c.state.everWithdrawn = 2_000_000, true
	if m := mode(); m != "**Escrow**: the beneficiary has withdrawn funds, so gifts can't be refunded now." {
		t.Errorf("escrow, after a withdrawal: %q", m)
	}
	c.state.status, c.state.closedAt = statusClosed, now()
	if m := mode(); m != "**Escrow**: the beneficiary has withdrawn funds, so gifts can't be refunded now." {
		t.Errorf("escrow, closed after a withdrawal, the window running: %q", m)
	}
	c.state.closedAt = now() - c.params.ExitDelay
	if m := mode(); m != "**Escrow**: "+"the beneficiary didn't collect in time, so a donor who hasn't reclaimed their share yet can, at any time."+refund {
		t.Errorf("escrow, the exit window open: %q", m)
	}
	c.mode = modeDirect
	if m := mode(); m != "**Direct**: each gift goes straight to the beneficiary, in the same transaction. Gifts can't be refunded." {
		t.Errorf("direct: %q", m)
	}
}

// TestProgressBar: the bar fills min(net, goal) of its width, its text the uncapped
// percentage; with no goal there is none; a share never overflows (UI spec §5).
func TestProgressBar(t *testing.T) {
	fill := func(bar string) string {
		i := strings.LastIndex(bar, "%3Crect%20width='")
		rest := bar[i+len("%3Crect%20width='"):]
		return rest[:strings.Index(rest, "'")]
	}
	for _, tc := range []struct {
		net, goal   int64
		width       int
		alt, filled string
	}{
		{0, 400, barWide, "0%", "0"},
		{90_000_000, 400_000_000, barWide, "22%", "225"},
		{90_000_000, 400_000_000, barCard, "22%", "90"},
		{496_000_000, 400_000_000, barWide, "124%", "1000"},
		{1, 3, barWide, "33%", "333"},
	} {
		bar := progressBar(tc.net, tc.goal, tc.width)
		if !strings.HasPrefix(bar, "!["+tc.alt+" of the goal](data:image/svg+xml;utf8,%3Csvg%20") || fill(bar) != tc.filled || !strings.Contains(bar, "width='"+strconv.Itoa(tc.width)+"'%20height='10'") {
			t.Errorf("progressBar(%d, %d, %d) = %s", tc.net, tc.goal, tc.width, bar)
		}
	}
	if bar := progressBar(5, 0, barWide); bar != "" {
		t.Errorf("a bar with no goal: %s", bar)
	}
	if got := share(math.MaxInt64, 1, 1000); got <= 0 {
		t.Errorf("share overflowed: %d", got)
	}
	if got := share(-5, 10, 100); got != 0 {
		t.Errorf("share of a negative part: %d", got)
	}
}

// TestRenderCards: campaigns are cards two to a row, a lone last one in a row of its
// own with an empty column; a card says what a donor weighs (UI spec §4.13).
func TestRenderCards(t *testing.T) {
	var b strings.Builder
	v := CampaignView{ID: "1", Title: "Well", Category: "water", Mode: modeEscrow, Status: statusOpen, NetRaised: 3_000_000, Goal: 10_000_000, DonorCount: 1, Bond: 5_000_000, Notice: "Under review"}
	writeCards(&b, []CampaignView{v, v, v})
	out := b.String()
	if strings.Count(out, "<gno-columns>\n") != 2 || strings.Count(out, "</gno-columns>\n\n") != 2 || strings.Count(out, "\n<gno-columns-sep />\n") != 2 ||
		strings.Contains(out, "<gno-columns-sep>") || !strings.HasSuffix(out, "<gno-columns-sep />\n</gno-columns>\n\n") {
		t.Errorf("not two to a row:\n%s", out)
	}
	if !strings.Contains(out, "**3 GNOT** of 10 GNOT · 1 donor  \nEscrow · water · no deadline · bond 5 GNOT · **moderator's notice**\n") {
		t.Errorf("a card's lines:\n%s", out)
	}
	b.Reset()
	v.Goal, v.Deadline, v.Bond, v.Notice, v.Status = 0, now()+3*secondsPerDay+60, 0, "", statusOpen
	writeCards(&b, []CampaignView{v, v})
	if out = b.String(); strings.Contains(out, "data:image") || !strings.Contains(out, "**3 GNOT** raised · 1 donor  \nEscrow · water · 3 days left\n") || strings.HasSuffix(out, "<gno-columns-sep />\n</gno-columns>\n\n") {
		t.Errorf("two cards with no goal:\n%s", out)
	}
	for status, word := range map[string]string{statusClosed: "closed to new donations", statusSettled: "completed"} {
		v.Status = status
		if got := timeWord(v); got != word {
			t.Errorf("timeWord(%s) = %q", status, got)
		}
	}
	if got := left(now() + secondsPerDay - 1); got != "less than a day left" {
		t.Errorf("left, under a day: %q", got)
	}
}

// TestRenderLedgerDirect: a direct campaign's money out says nothing goes out, and
// its page doesn't link there (API §5).
func TestRenderLedgerDirect(t *testing.T) {
	c := testCampaign(9975, modeDirect, 0)
	id, unstore := storeCampaign(c)
	defer unstore()
	if page := Render("c/" + id + "/ledger"); strings.Contains(page, "## Withdrawals") || !strings.Contains(page, "**Direct**: each gift went straight to the beneficiary, `"+c.beneficiary.String()+"`") {
		t.Errorf("a direct campaign's money out:\n%s", page)
	}
	if page := Render("c/" + id); strings.Contains(page, "/ledger)") || strings.Contains(page, "| Held in escrow |") {
		t.Errorf("a direct campaign's page links to money out, or shows an escrow:\n%s", page)
	}
}

// TestRenderStart: the home page links to CreateCampaign's form, the deposit attached,
// only while this version takes new campaigns; paused or sunset, it says why, and a
// sunset version points to the registry, where new campaigns start (UI spec §4.13).
func TestRenderStart(t *testing.T) {
	defer func() { paused, sunset = false, false }()
	start := "[Start a campaign](/r/g12yg9nh4ncma44emgm8msxe8aavzywt0p95tanv/bolo/v0$help&func=CreateCampaign&.send=" + strconv.FormatInt(params.CreationDeposit, 10) + "ugnot) — a " + gnot(params.CreationDeposit) + " deposit, returned when it completes · [Find an address](/r/g12yg9nh4ncma44emgm8msxe8aavzywt0p95tanv/bolo/v0:u)\n"
	if home := Render(""); !strings.Contains(home, start) {
		t.Errorf("no link to start a campaign:\n%s", home)
	}
	paused = true
	if home := Render(""); strings.Contains(home, "func=CreateCampaign") || !strings.Contains(home, "Bolo is paused: new campaigns and gifts wait until it resumes · [Find an address]") {
		t.Errorf("paused:\n%s", home)
	}
	paused, sunset = false, true
	if home := Render(""); strings.Contains(home, "func=CreateCampaign") || !strings.Contains(home, "This version of Bolo takes no new campaigns: [see where they start](/r/g12yg9nh4ncma44emgm8msxe8aavzywt0p95tanv/bolo) · [Find an address]") {
		t.Errorf("sunset:\n%s", home)
	}
	paused = true // and sunset, which is for good
	if home, params := Render(""), Render("params"); !strings.Contains(home, "This version of Bolo takes no new campaigns") || !strings.Contains(params, "- New campaigns: not on this version\n") {
		t.Errorf("paused and sunset:\n%s\n%s", home, params)
	}
}

// TestParseGNOT: an amount in GNOT parses only in its one grammar (API §5).
func TestParseGNOT(t *testing.T) {
	for s, want := range map[string]int64{"1": 1_000_000, "7.5": 7_500_000, "7%2C5": 7_500_000, "0.000001": 1, "0.5": 500_000, "999999999999": 999_999_999_999_000_000, "10.25": 10_250_000,
		"+7.5+": 7_500_000, "++7.5": 7_500_000, "1%2C00": 1_000_000, "1%2C0000": 1_000_000, "1.000": 1_000_000} {
		if got, ok := parseGNOT(s); !ok || got != want {
			t.Errorf("parseGNOT(%q) = %d, %t; want %d", s, got, ok, want)
		}
	}
	for _, s := range []string{"", ".5", "1.", "01", "00.5", "-1", "1e3", "1.1234567", "1,5", "7%2c5", "1 ", " 1", "1..5", "7.5.1", "1234567890123", "%2C5", "1%2C",
		"1%2C000", "12%2C500", "+", "+-1", "7+5"} {
		if got, ok := parseGNOT(s); ok {
			t.Errorf("parseGNOT(%q) accepted: %d", s, got)
		}
	}
}

// TestRenderGive: another amount's page asks the amount in gnoweb's form and answers
// one Donate would take with its one-click link; any other gets the form again with
// what the campaign can take, echoing nothing; a campaign that takes no gift says so
// (API §5).
func TestRenderGive(t *testing.T) {
	c := testCampaign(9976, modeEscrow, 0)
	id, unstore := storeCampaign(c)
	defer unstore()
	saved := escrowCap
	defer func() { escrowCap, paused = saved, false }()
	escrowCap = 30_000_000
	c.state.raised = 12_000_000 // 18 GNOT of room
	page := func(q string) string { return Render("c/" + id + "/give" + q) }
	form := "\n<gno-form path=\"c/" + id + "/give\">\n  <gno-input name=\"amount\" placeholder=\"7.5\" />\n</gno-form>\n"
	if p := page(""); !strings.Contains(p, form) || !strings.Contains(p, "Any amount from 1 GNOT to 18 GNOT, in GNOT.") || strings.Contains(p, "isn't") {
		t.Errorf("the page for another amount:\n%s", p)
	}
	link := "**[Give 7.5 GNOT](/r/g12yg9nh4ncma44emgm8msxe8aavzywt0p95tanv/bolo/v0$help&func=Donate&.send=7500000ugnot&anonymous=false&id=" + id + "&message=&tip=0)**"
	for _, q := range []string{"?amount=7.5", "?amount=7%2C5"} {
		if p := page(q); !strings.Contains(p, link) || strings.Contains(p, "<gno-form") {
			t.Errorf("%s: no link for 7.5 GNOT, or the form again:\n%s", q, p)
		}
	}
	if p := page("?amount=18"); !strings.Contains(p, "&.send=18000000ugnot&") {
		t.Errorf("the whole room refused:\n%s", p)
	}
	for _, bad := range []string{"0.5", "18.000001", "50", "zz9", "7.5.1", "%3Cb%3Eecho", "1234567890123"} {
		p := page("?amount=" + bad)
		if !strings.Contains(p, "That isn't an amount this campaign can take.") || !strings.Contains(p, form) || strings.Contains(p, "func=Donate") {
			t.Errorf("?amount=%s: a link, or no form and line saying why:\n%s", bad, p)
		}
		if strings.Contains(p, bad) {
			t.Errorf("?amount=%s: the page echoes it:\n%s", bad, p)
		}
	}
	if p := page("?amount=1"); !strings.Contains(p, "&.send=1000000ugnot&") {
		t.Errorf("exactly the smallest gift refused:\n%s", p)
	}
	escrowCap = 0
	if p := page(""); !strings.Contains(p, "Any amount from 1 GNOT, in GNOT.") {
		t.Errorf("no cap, yet a most said:\n%s", p)
	}
	// No link while Bolo is paused, the campaign is hidden or closed, or the cap leaves
	// less room than the smallest gift: the page says so, and links back.
	none := func(why string) {
		if p := page("?amount=1"); strings.Contains(p, "func=Donate") || strings.Contains(p, "<gno-form") || !strings.Contains(p, "Bolo offers no gift link for this campaign now: its page says why.") {
			t.Errorf("%s: a link, or the form:\n%s", why, p)
		}
	}
	paused = true
	none("paused")
	paused = false
	c.state.listed = false
	none("hidden from listings")
	c.state.listed = true
	escrowCap = 12_500_000 // half a GNOT of room
	none("no room")
	escrowCap = 0
	c.state.status = statusClosed
	none("closed")
}

// TestRenderMoney: where the money is comes from the books — the escrow's coins sent
// outside Bolo said apart — and in direct mode all went straight through, with no money
// out on its receipt; the bond reads as at stake, its hold over, or slashed.
func TestRenderMoney(t *testing.T) {
	c := testCampaign(9977, modeEscrow, 0)
	id, unstore := storeCampaign(c)
	defer unstore()
	donor := testutils.TestAddress("moneydonor")
	giveTo(c, 1, donor, 40_000_000)
	defer byDonor.Remove(donor.String() + "/" + c.id.Binary())
	c.state.withdrawn, c.state.refunded, c.state.everWithdrawn = 20_000_000, 2_000_000, true
	testing.IssueCoins(escrowAddr(c.id), chain.NewCoins(chain.NewCoin("ugnot", 27_000_000))) // 18 held, and 9 sent outside Bolo
	page := Render("c/" + id)
	for _, want := range []string{"| Given: 1 gift from 1 donor | 40 |\n", "| Refunded to donors | 2 |\n", "| **Raised**, net of refunds | **38** |\n",
		"| Withdrawn by the beneficiary | 20 |\n", "| Held in escrow | 18 |\n", "its bank balance is the 18 GNOT held, plus 9 GNOT sent there outside Bolo"} {
		if !strings.Contains(page, want) {
			t.Errorf("missing %q:\n%s", want, page)
		}
	}
	c.state.bond = 5_000_000
	if p := Render("c/" + id); !strings.Contains(p, "; a 5 GNOT bond the organizer staked, lost if the campaign is delisted for fraud — not a guarantee\n") {
		t.Errorf("a bond at stake:\n%s", p)
	}
	c.state.status, c.state.closedAt, c.state.closeReason = statusClosed, now()-c.params.BondHold, reasonOrganizer
	if p := Render("c/" + id); !strings.Contains(p, "; a 5 GNOT bond the organizer staked, whose hold ended "+when(now())+": no longer at stake, it goes back to the organizer\n") {
		t.Errorf("a bond whose hold ended:\n%s", p)
	}
	c.state.bondSlashed = true
	if p := Render("c/" + id); !strings.Contains(p, "; a 5 GNOT bond, slashed\n") {
		t.Errorf("a slashed bond:\n%s", p)
	}

	d := testCampaign(9978, modeDirect, 0)
	did, undirect := storeCampaign(d)
	defer undirect()
	giveTo(d, 1, donor, 15_000_000)
	defer byDonor.Remove(donor.String() + "/" + d.id.Binary())
	if p := Render("c/" + did); !strings.Contains(p, "| Given: 1 gift from 1 donor | 15 |\n| Sent straight to the beneficiary | 15 |\n\n") || strings.Contains(p, "Held in escrow") {
		t.Errorf("a direct campaign's money:\n%s", p)
	}
	if r := Render("c/" + did + "/r/1"); strings.Contains(r, "/ledger)") || !strings.Contains(r, "Every gift went straight to the beneficiary, `"+d.beneficiary.String()+"`, in the same transaction.") {
		t.Errorf("a direct receipt:\n%s", r)
	}
}
