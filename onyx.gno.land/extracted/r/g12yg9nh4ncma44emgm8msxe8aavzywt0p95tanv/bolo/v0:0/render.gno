package bolo

import (
	"math"
	"strconv"
	"strings"
	"time"

	"gno.land/p/moul/txlink/v0"
	"gno.land/p/nt/markdown/sanitize/v0"
)

// Render (API §5): gnoweb's pages, each laid out for who reads it (UI spec §4.13). The
// path is attacker-controlled: it is parsed into typed values, and anything that fails
// gets one fixed page that echoes nothing from the request. User text is escaped by
// who wrote it: strangers and moderators through inline, the organizer through
// Blockquote; addresses go into code spans, where gnoweb makes no link of them. Render
// writes nothing and reads balances only through views.

const (
	webPath        = "/r/g12yg9nh4ncma44emgm8msxe8aavzywt0p95tanv/bolo/v0" // this realm on gnoweb
	maxPathLen     = 256                 // longer than any valid path
	listPage       = 20                  // entries a list page shows
	updatesPage    = 5                   // updates a page shows: each can cost 0.18 billion gas to render
	addressSection = 10                  // entries each address-page section shows
	barWide        = 1000                // a progress bar's width across a page, scaled down to fit
	barCard        = 400                 // and in a card, half a row
	notFound       = "# Not found\n\nThere is nothing here. [Bolo](" + webPath + ")\n"
)

// Render returns the markdown page for path (API §5).
func Render(path string) string {
	if len(path) > maxPathLen {
		return notFound
	}
	route, rawQuery, _ := strings.Cut(path, "?")
	q, ok := parseQuery(rawQuery)
	if !ok {
		return notFound
	}
	if out, ok := route2page(route, q); ok {
		return out
	}
	return notFound
}

// route2page renders route, or reports false when route names nothing or a value in
// q doesn't parse. Every prefix of a route renders a page, as gnoweb's header links
// each one: "c" the home page, "c/{id}/r" the gifts, "u" the form to find an address.
func route2page(route string, q map[string]string) (string, bool) {
	switch route {
	case "", "c":
		return renderHome(q)
	case "u":
		return renderLookup(q), true
	case "about":
		return renderAbout(), true
	case "params":
		return renderParams(), true
	}
	segs := strings.Split(route, "/")
	switch {
	case segs[0] == "c" && len(segs) >= 2 && len(segs) <= 4:
		c, ok := lookup(segs[1])
		if !ok {
			return "", false
		}
		switch {
		case len(segs) == 2:
			return renderCampaign(c), true
		case len(segs) == 3 && (segs[2] == "donations" || segs[2] == "r"):
			return pageOf(q, func(page int) string { return renderDonations(c, page) })
		case len(segs) == 3 && segs[2] == "give":
			return renderGive(c, q), true
		case len(segs) == 3 && segs[2] == "ledger":
			return pageOf(q, func(page int) string { return renderLedger(c, page) })
		case len(segs) == 3 && segs[2] == "updates":
			return pageOf(q, func(page int) string { return renderUpdates(c, page) })
		case len(segs) == 4 && segs[2] == "r":
			seq, ok := parseID(segs[3])
			if !ok || c.receipts.Get(seq.Binary()) == nil {
				return "", false
			}
			return renderReceipt(c, int64(seq)), true
		}
	case segs[0] == "u" && (len(segs) == 2 || len(segs) == 3):
		addr, ok := parseAddress(segs[1])
		if !ok {
			return "", false
		}
		if len(segs) == 2 {
			return renderAddress(addr), true
		}
		list, heading := addressList(segs[2])
		if list == nil {
			return "", false
		}
		after, ok := q["after"]
		if ok {
			if _, canonical := parseID(after); !canonical {
				return "", false
			}
		}
		return renderAddressList(addr, segs[2], heading, list, after), true
	}
	return "", false
}

// parseQuery splits a query into its key=value pairs: an empty pair is skipped, a key
// given twice fails. Values are taken as they are: the routes parse them.
func parseQuery(raw string) (map[string]string, bool) {
	q := map[string]string{}
	if raw == "" {
		return q, true
	}
	for _, pair := range strings.Split(raw, "&") {
		if pair == "" {
			continue
		}
		k, v, _ := strings.Cut(pair, "=")
		if _, seen := q[k]; seen {
			return nil, false
		}
		q[k] = v
	}
	return q, true
}

// pageOf calls render with the page q asks for, 1 when it asks none, or fails when
// its page isn't a canonical number of at least 1.
func pageOf(q map[string]string, render func(page int) string) (string, bool) {
	page := 1
	if v, ok := q["page"]; ok {
		n, ok := parsePage(v)
		if !ok {
			return "", false
		}
		page = n
	}
	return render(page), true
}

// parsePage parses a page number: canonical decimal — no sign, no leading zero — from
// 1, at most nine digits.
func parsePage(s string) (int, bool) {
	if s == "" || len(s) > 9 || s[0] == '0' {
		return 0, false
	}
	n := 0
	for i := 0; i < len(s); i++ {
		if s[i] < '0' || s[i] > '9' {
			return 0, false
		}
		n = n*10 + int(s[i]-'0')
	}
	return n, true
}

// parseAddress checks an address from a path as C12 checks an argument: exactly 40
// characters, a lowercase "g" first, then IsValid.
func parseAddress(s string) (address, bool) {
	if len(s) != 40 || s[0] != 'g' || !address(s).IsValid() {
		return "", false
	}
	return address(s), true
}

// renderHome is the home page: the guarantees in one line, how it works, the links to
// start a campaign and to find an address, the newest active campaigns in a category
// or all, 20 at a time by cursor, and the categories.
func renderHome(q map[string]string) (string, bool) {
	after, ok := q["after"]
	if ok {
		if _, canonical := parseID(after); !canonical {
			return "", false
		}
	}
	cat, set := q["cat"]
	if set && !categories.Has(cat) {
		return "", false
	}
	var b strings.Builder
	b.WriteString("# Bolo\n\nGive together. See where it goes.\n\n")
	b.WriteString("**0% platform fee · every gift checkable · nothing in Bolo can freeze your gift** — [what Bolo guarantees, and what it doesn't](" + webPath + ":about)\n\n")
	b.WriteString("How it works: give from your wallet → get a receipt → check where the money went.\n\n")
	writeStart(&b)
	if cat == "" {
		b.WriteString("## Newest campaigns\n\n")
	} else {
		b.WriteString("## Newest campaigns in " + cat + "\n\n")
	}
	views, next := ListCampaigns(after, listPage, cat)
	writeCards(&b, views)
	switch {
	case len(views) > 0:
	case after == "" && next == "":
		b.WriteString("No campaigns here yet.\n\n")
	default:
		b.WriteString("None on this page.\n\n")
	}
	if next != "" {
		more := webPath + ":?after=" + next
		if cat != "" {
			more += "&cat=" + cat
		}
		b.WriteString("[More](" + more + ")\n\n")
	}
	b.WriteString("## Categories\n\n")
	for i, code := range categoryOrder {
		if i > 0 {
			b.WriteString(" · ")
		}
		b.WriteString("[" + code + "](" + webPath + ":?cat=" + code + ")")
	}
	b.WriteString("\n")
	return b.String(), true
}

// writeStart writes the link to start a campaign — CreateCampaign's form, the creation
// deposit attached — while this version takes new campaigns, or why it doesn't; then
// the link to find an address.
func writeStart(b *strings.Builder) {
	switch {
	case sunset:
		b.WriteString("This version of Bolo takes no new campaigns: [see where they start](/r/g12yg9nh4ncma44emgm8msxe8aavzywt0p95tanv/bolo)")
	case paused:
		b.WriteString("Bolo is paused: new campaigns and gifts wait until it resumes")
	default:
		link := txlink.Realm(pkgPath).NewLink("CreateCampaign").SetSend(strconv.FormatInt(params.CreationDeposit, 10) + "ugnot").URL()
		b.WriteString("[Start a campaign](" + link + ") — a " + gnot(params.CreationDeposit) + " deposit, returned when it completes")
	}
	b.WriteString(" · [Find an address](" + webPath + ":u)\n\n")
}

// writeCards writes campaigns as cards, two to a row in gnoweb's columns (UI spec
// §4.13): the title as a link, the progress bar, raised of the goal and donors, then
// the mode, the category, the time left or how it ended, and a bond or a moderator's
// notice when there is one. The one user text, the title, goes through inline, whose
// InlineText escapes "<": nothing in it can open, separate or close a block. A
// separator is written self-closing, the spelling every gnoweb reads as one.
func writeCards(b *strings.Builder, views []CampaignView) {
	for i, v := range views {
		if i%2 == 0 {
			b.WriteString("<gno-columns>\n")
		} else {
			b.WriteString("<gno-columns-sep />\n")
		}
		b.WriteString("### [" + inline(v.Title) + "](" + webPath + ":c/" + v.ID + ")\n\n")
		if bar := progressBar(v.NetRaised, v.Goal, barCard); bar != "" {
			b.WriteString(bar + "\n\n")
		}
		b.WriteString("**" + gnot(v.NetRaised) + "**")
		if v.Goal > 0 {
			b.WriteString(" of " + gnot(v.Goal))
		} else {
			b.WriteString(" raised")
		}
		b.WriteString(" · " + count(v.DonorCount, "donor", "donors") + "  \n")
		b.WriteString(modeWord(v.Mode) + " · " + v.Category + " · " + timeWord(v))
		if v.Bond > 0 {
			if v.BondSlashed {
				b.WriteString(" · bond slashed")
			} else {
				b.WriteString(" · bond " + gnot(v.Bond))
			}
		}
		if v.Notice != "" {
			b.WriteString(" · **moderator's notice**")
		}
		b.WriteString("\n")
		if i%2 == 1 || i == len(views)-1 {
			if i%2 == 0 { // a row's last card alone: an empty column keeps it half wide
				b.WriteString("<gno-columns-sep />\n")
			}
			b.WriteString("</gno-columns>\n\n")
		}
	}
}

// timeWord says where a campaign stands in time, on a card: the time left, no
// deadline, or how it ended.
func timeWord(v CampaignView) string {
	switch {
	case v.Status == statusSettled:
		return "completed"
	case v.Status != statusOpen:
		return "closed to new donations"
	case v.Deadline != 0:
		return left(v.Deadline)
	}
	return "no deadline"
}

// renderCampaign is a campaign's page (API §5, UI spec §4.13), Bolo's own blocks
// before the organizer's words: the notice, the photo, the title and byline, the
// figures, the mode, the state banner, the donate links, where the money is, the
// verification block; then the story as a quote; then the recent gifts, the latest
// update, and last the actions of the organizer, the beneficiary and anyone.
func renderCampaign(c *campaign) string {
	v := campaignView(c)
	space := room(v)
	anyone, reason := CanClose(v.ID, "")
	var b strings.Builder
	if v.Notice != "" {
		b.WriteString("> [!WARNING] Notice from Bolo's moderator\n> " + lineStart(v.Notice) + "\n\n")
	}
	if v.ImageCID != "" && !v.ImageHidden {
		b.WriteString("![" + inline(v.ImageAlt) + "](ipfs://" + v.ImageCID + ")\n\n")
	}
	b.WriteString("# " + lineStart(v.Title) + "\n\n")
	b.WriteString(v.Category + " · by " + addrLink(v.Organizer) + " · for " + addrLink(v.Beneficiary))
	if !v.Listed {
		b.WriteString(" · **hidden from listings**")
	}
	b.WriteString("\n\n")
	writeFigures(&b, v)
	writeMode(&b, v)
	writeBanner(&b, v, space, anyone && reason == reasonDormant)
	writeGive(&b, v, space)
	writeMoney(&b, v)
	writeVerify(&b, v)
	if v.Description != "" {
		b.WriteString("---\n\n## In the organizer's words\n")
		b.WriteString(sanitize.Blockquote(v.Description))
		b.WriteString("---\n\n")
	}
	b.WriteString("## Recent gifts\n\n")
	recent := ListRecent(v.ID)
	for _, r := range recent {
		writeGift(&b, r)
	}
	if len(recent) == 0 {
		b.WriteString("No gifts yet.\n")
	}
	b.WriteString("\n[All gifts](" + webPath + ":c/" + v.ID + "/donations)")
	if v.Mode == modeEscrow {
		b.WriteString(" · [Money out](" + webPath + ":c/" + v.ID + "/ledger)")
	}
	b.WriteString("\n\n")
	if v.UpdateCount > 0 {
		b.WriteString("## Latest update\n\n")
		u := ListUpdates(v.ID, 1, 1)[0]
		b.WriteString("**" + when(u.At) + "**\n")
		b.WriteString(sanitize.Blockquote(u.Body))
		b.WriteString("[All updates](" + webPath + ":c/" + v.ID + "/updates)\n\n")
	}
	writeManage(&b, v, anyone)
	return b.String()
}

// writeFigures writes the progress bar, then three figures, a short line each, which
// stay short on a phone: raised, of the goal; donors and gifts; the time left, or how
// it ended.
func writeFigures(b *strings.Builder, v CampaignView) {
	if bar := progressBar(v.NetRaised, v.Goal, barWide); bar != "" {
		b.WriteString(bar + "\n\n")
	}
	b.WriteString("**" + gnot(v.NetRaised) + "** raised")
	if v.Goal > 0 {
		b.WriteString(" · " + percent(v.NetRaised, v.Goal) + " of a " + gnot(v.Goal) + " goal")
	}
	b.WriteString("  \n**" + count(v.DonorCount, "donor", "donors") + "** · " + count(v.DonationCount, "gift", "gifts"))
	if v.RefundCount > 0 {
		b.WriteString(", " + count(v.RefundCount, "refund", "refunds"))
	}
	b.WriteString("  \n")
	switch {
	case v.Status == statusSettled:
		b.WriteString("**Completed** · closed on " + day(v.ClosedAt))
	case v.Status != statusOpen:
		b.WriteString("**Closed to new donations** · on " + day(v.ClosedAt))
	case v.Deadline != 0:
		b.WriteString("**" + left(v.Deadline) + "** · until " + day(v.Deadline))
	default:
		b.WriteString("**No deadline** · open until it is closed")
	}
	b.WriteString("\n\n")
}

// writeMode writes the custody mode in words and what it means now (UI spec §4.3,
// ModeChip), with the refund link while a refund window is open to some donor — as
// far as the books can tell: after every donor's exit claim, rounding can leave a few
// ugnot that keep the window open in the books (API §2.4, §5).
func writeMode(b *strings.Builder, v CampaignView) {
	if v.Mode != modeEscrow {
		b.WriteString("**Direct**: each gift goes straight to the beneficiary, in the same transaction. Gifts can't be refunded.\n\n")
		return
	}
	b.WriteString("**Escrow**: ")
	switch {
	case v.Status != statusOpen && v.Balance == 0:
		b.WriteString("no gift is held any more.")
	case v.Status != statusOpen && now() >= v.ExitOpensAt: // the beneficiary's window has passed
		b.WriteString("the beneficiary didn't collect in time, so a donor who hasn't reclaimed their share yet can, at any time.")
	case v.EverWithdrawn:
		b.WriteString("the beneficiary has withdrawn funds, so gifts can't be refunded now.")
	default:
		b.WriteString("the gifts stay in escrow until the beneficiary withdraws them. Until then, a donor can take their gift back.")
	}
	if v.ExitOpen || !v.EverWithdrawn && v.Balance > 0 {
		b.WriteString(" [Refund](" + txlink.Realm(pkgPath).NewLink("Refund").AddArgs("id", v.ID).URL() + ")")
	}
	b.WriteString("\n\n")
}

// writeBanner writes the one state banner the UI spec's state matrix gives the
// campaign now (§6), as gnoweb's alert box, which no user text can open (API §5): how
// it was closed and what remains to happen, that it completed, that Bolo is paused,
// that the escrow cap leaves no room for a gift, or that anyone may close it as it is
// dormant. space is the room the cap leaves.
func writeBanner(b *strings.Builder, v CampaignView, space int64, dormant bool) {
	kind, title, text := "NOTE", "", ""
	switch {
	case v.Status == statusSettled:
		kind, title = "SUCCESS", "Completed"
		text = "Closed to new donations on " + when(v.ClosedAt) + ", then settled: the organizer's deposit went back to them."
	case v.Status != statusOpen:
		title, text = "Closed to new donations", closedText(v)
	case paused:
		kind, title, text = "CAUTION", "Bolo is paused", "New gifts wait until it resumes. Withdrawals and refunds still work."
	case space < minDonation:
		title, text = "Full for now", "This campaign can't take more until the beneficiary withdraws."
		if escrowCap < minDonation { // no withdrawal makes room
			text = "Bolo's escrow cap is set below its smallest gift, so no campaign in escrow can take a gift for now."
		}
	case dormant:
		title, text = "Inactive", "No gift and no update for "+days(v.Params.DormancyPeriod)+": anyone can close it now."
	default:
		return
	}
	b.WriteString("> [!" + kind + "] " + title + "\n> " + text + "\n\n")
}

// closedText says how a campaign was closed and, in escrow, what remains: the
// beneficiary's countdown to the exit window, or the window open to donors.
func closedText(v CampaignView) string {
	var out string
	switch v.CloseReason {
	case reasonDeadline:
		out = "It ended at its deadline, on " + when(v.ClosedAt) + "."
	case reasonDormant:
		out = "Closed on " + when(v.ClosedAt) + ", after " + days(v.Params.DormancyPeriod) + " with no gift and no update."
	default:
		out = "Closed by its organizer on " + when(v.ClosedAt) + "."
	}
	if v.Mode != modeEscrow || v.Balance == 0 {
		return out
	}
	if now() < v.ExitOpensAt {
		return out + " The beneficiary can withdraw the " + gnot(v.Balance) + " held until " + when(v.ExitOpensAt) + ", " + left(v.ExitOpensAt) + "; after that, donors can reclaim their share."
	}
	return out + " The beneficiary didn't collect in time: a donor who hasn't reclaimed their share yet can, at any time."
}

// room is how much more campaign v can take: what the escrow cap leaves, in escrow
// with a cap (checkRoom); otherwise as much as an amount can be.
func room(v CampaignView) int64 {
	if v.Mode != modeEscrow || escrowCap == 0 {
		return math.MaxInt64
	}
	return escrowCap - v.Balance
}

// writeGive writes the one-click donate links (API §5): while the campaign is open,
// listed and Bolo isn't paused, one per preset Donate would take — at least the
// smallest gift, and no more than the room the escrow cap leaves, space — then the
// page for another amount, with the room said when it left a preset out.
func writeGive(b *strings.Builder, v CampaignView, space int64) {
	if v.Status != statusOpen || !v.Listed || paused || space < minDonation {
		return
	}
	var links []string
	capped := false
	for _, preset := range presets {
		if preset > space {
			capped = true
			continue
		}
		if preset < minDonation {
			continue
		}
		links = append(links, giveLink(v.ID, preset))
	}
	links = append(links, "[Another amount]("+webPath+":c/"+v.ID+"/give)")
	b.WriteString("## Give\n\n" + strings.Join(links, " · ") + "\n\n")
	if capped {
		b.WriteString("It can take " + gnot(space) + " more for now: the beneficiary's next withdrawal makes room.\n\n")
	}
}

// giveLink is a one-click link that gives ugnot to campaign id, with no tip and no
// message: gnoweb's form attaches the coins once the donor confirms them.
func giveLink(id string, ugnot int64) string {
	link := txlink.Realm(pkgPath).NewLink("Donate").
		AddArgs("id", id, "tip", "0", "message", "", "anonymous", "false").
		SetSend(strconv.FormatInt(ugnot, 10) + "ugnot").URL()
	return "[Give " + gnot(ugnot) + "](" + link + ")"
}

// renderGive is the page for another amount (API §5). gnoweb's function form attaches
// only the coins a link carries, so this page asks the amount in gnoweb's own form,
// which submits back as ?amount=, and answers an amount Donate would take with its
// one-click link. Any other amount gets the form again with what the campaign can
// take, echoing nothing; a campaign Bolo offers no gift link for says so.
func renderGive(c *campaign, q map[string]string) string {
	v := campaignView(c)
	space := room(v)
	back := "[Back to the campaign](" + webPath + ":c/" + v.ID + ")\n"
	var b strings.Builder
	b.WriteString("# Give to [" + inline(v.Title) + "](" + webPath + ":c/" + v.ID + ")\n\n")
	if v.Status != statusOpen || !v.Listed || paused || space < minDonation {
		b.WriteString("Bolo offers no gift link for this campaign now: its page says why.\n\n" + back)
		return b.String()
	}
	raw, asked := q["amount"]
	if asked {
		if ugnot, ok := parseGNOT(raw); ok && ugnot >= minDonation && ugnot <= space {
			b.WriteString("**" + giveLink(v.ID, ugnot) + "**\n\n")
			b.WriteString("gnoweb's form asks you to confirm the coins before it adds them.\n\n" + back)
			return b.String()
		}
		b.WriteString("That isn't an amount this campaign can take.\n\n")
	}
	b.WriteString("Any amount from " + gnot(minDonation))
	if space < math.MaxInt64 {
		b.WriteString(" to " + gnot(space))
	}
	b.WriteString(", in GNOT.\n\n")
	b.WriteString("<gno-form path=\"c/" + v.ID + "/give\">\n  <gno-input name=\"amount\" placeholder=\"7.5\" />\n</gno-form>\n\n" + back)
	return b.String()
}

// parseGNOT parses an amount in GNOT into ugnot (API §5): digits without a sign or a
// leading zero, at most 12 of them, then optionally a decimal point — "." or, as a
// form sends a comma, "%2C" — and one to six digits; but not a comma and exactly
// three, which may be a thousands separator. The spaces a form sends around a value,
// as "+", are dropped first.
func parseGNOT(s string) (int64, bool) {
	s = strings.Trim(s, "+")
	whole, frac, point := strings.Cut(s, ".")
	if !point {
		whole, frac, point = strings.Cut(s, "%2C")
		if point && len(frac) == 3 { // "1,000": a thousand, or one?
			return 0, false
		}
	}
	if whole == "" || len(whole) > 12 || len(whole) > 1 && whole[0] == '0' || point && (frac == "" || len(frac) > 6) {
		return 0, false
	}
	var n int64
	for i := 0; i < len(whole); i++ {
		if whole[i] < '0' || whole[i] > '9' {
			return 0, false
		}
		n = n*10 + int64(whole[i]-'0')
	}
	n *= 1_000_000
	unit := int64(100_000)
	for i := 0; i < len(frac); i++ {
		if frac[i] < '0' || frac[i] > '9' {
			return 0, false
		}
		n += int64(frac[i]-'0') * unit
		unit /= 10
	}
	return n, true
}

// writeMoney writes where the money is, a table of amounts: given, then, in escrow,
// refunded, raised net of refunds, withdrawn and held; in direct mode, sent straight
// to the beneficiary.
func writeMoney(b *strings.Builder, v CampaignView) {
	b.WriteString("## Where the money is\n\n| | GNOT |\n|---|--:|\n")
	b.WriteString("| Given: " + count(v.DonationCount, "gift", "gifts") + " from " + count(v.DonorCount, "donor", "donors") + " | " + amount(v.Raised) + " |\n")
	if v.Mode != modeEscrow {
		b.WriteString("| Sent straight to the beneficiary | " + amount(v.Raised) + " |\n\n")
		return
	}
	b.WriteString("| Refunded to donors | " + amount(v.Refunded) + " |\n")
	b.WriteString("| **Raised**, net of refunds | **" + amount(v.NetRaised) + "** |\n")
	b.WriteString("| Withdrawn by the beneficiary | " + amount(v.Withdrawn) + " |\n")
	b.WriteString("| Held in escrow | " + amount(v.Balance) + " |\n\n")
}

// writeVerify writes the verification block: where to check every figure on the chain
// itself (UI spec §2, level 3), each address in full.
func writeVerify(b *strings.Builder, v CampaignView) {
	b.WriteString("## Check it yourself\n\n")
	if v.Mode == modeEscrow {
		b.WriteString("- **Escrow** `" + v.EscrowAddress.String() + "`: its bank balance is the " + gnot(v.Balance) + " held, plus " + gnot(v.Untracked) + " sent there outside Bolo\n")
	}
	b.WriteString("- **Bond address** `" + v.BondAddress.String() + "`: the organizer's " + gnot(v.Deposit) + " deposit")
	if v.Status == statusSettled {
		b.WriteString(", returned when the campaign completed")
	} else {
		b.WriteString(", returned when the campaign completes")
	}
	switch {
	case v.Bond == 0:
	case v.BondSlashed:
		b.WriteString("; a " + gnot(v.Bond) + " bond, slashed")
	case v.Status != statusOpen && now() >= v.BondReleasableAt:
		b.WriteString("; a " + gnot(v.Bond) + " bond the organizer staked, whose hold ended " + when(v.BondReleasableAt) + ": no longer at stake, it goes back to the organizer")
	default:
		b.WriteString("; a " + gnot(v.Bond) + " bond the organizer staked, lost if the campaign is delisted for fraud — not a guarantee")
	}
	b.WriteString("\n- **Organizer** `" + v.Organizer.String() + "`\n- **Beneficiary** `" + v.Beneficiary.String() + "`\n\n")
	b.WriteString("Created " + when(v.CreatedAt))
	if v.Deadline != 0 {
		b.WriteString(" · deadline " + when(v.Deadline))
	}
	if v.ClosedAt != 0 {
		b.WriteString(" · closed " + when(v.ClosedAt))
	}
	b.WriteString("\n\n")
}

// writeManage writes the actions of the organizer, the beneficiary and anyone, each
// with who may take it, when that call could succeed for someone (API §5): last, as
// the web app puts maintenance last (UI spec §4.3). anyone is whether CanClose lets
// anyone close it.
func writeManage(b *strings.Builder, v CampaignView, anyone bool) {
	id := v.ID
	var links []string
	if v.Mode == modeEscrow && v.Balance+v.Untracked > 0 && (v.Status == statusOpen || v.Status == statusClosed && now() < v.ExitOpensAt) {
		links = append(links, "[Withdraw]("+txlink.Realm(pkgPath).NewLink("Withdraw").AddArgs("id", id).URL()+"): the beneficiary")
	}
	if anyone || v.Status == statusOpen {
		who := "the organizer"
		if anyone {
			who = "anyone"
		}
		links = append(links, "[Close]("+txlink.Realm(pkgPath).NewLink("Close").AddArgs("id", id).URL()+"): "+who)
	}
	if ok, _ := CanFinalize(id); ok {
		links = append(links, "[Finalize]("+txlink.Realm(pkgPath).NewLink("Finalize").AddArgs("id", id).URL()+"): anyone")
	}
	links = append(links, "[Post an update]("+txlink.Realm(pkgPath).NewLink("PostUpdate").AddArgs("id", id).URL()+"): the organizer")
	b.WriteString("## Manage this campaign\n\n- " + strings.Join(links, "\n- ") + "\n")
}

// writeGift writes one gift in two lines: its amount, and its message unless
// moderation hid it; then who gave it — a short address linking to its page, or
// anonymous — when, how much its donor was refunded since (INV-12), and its receipt.
func writeGift(b *strings.Builder, r ReceiptView) {
	b.WriteString("- **" + gnot(r.Amount) + "**")
	if r.MessageHidden {
		b.WriteString(" · message hidden by moderation")
	} else if r.Message != "" {
		b.WriteString(" · “" + inline(r.Message) + "”")
	}
	b.WriteString("  \n  ")
	if r.Anonymous {
		b.WriteString("Anonymous")
	} else {
		b.WriteString("from " + addrLink(r.Donor))
	}
	b.WriteString(" · " + when(r.At))
	if r.DonorRefunded > 0 {
		b.WriteString(" · **" + gnot(r.DonorRefunded) + " refunded since**")
	}
	b.WriteString(" · [receipt](" + webPath + ":c/" + r.CampaignID + "/r/" + strconv.FormatInt(r.Seq, 10) + ")\n")
}

// renderReceipt is a gift's receipt: the shareable object (PRD §5). When its donor was
// refunded since, the refund banner comes first, so a refunded receipt never looks like
// a live gift (UI spec §4.5, INV-12).
func renderReceipt(c *campaign, seq int64) string {
	r := GetReceipt(idString(c.id), seq)
	v := campaignView(c)
	var b strings.Builder
	if r.DonorRefunded > 0 {
		b.WriteString("> [!CAUTION] Refunded since\n> " + gnot(r.DonorRefunded) + " went back to this donor after this gift.\n\n")
	}
	b.WriteString("# Gift receipt\n\n")
	b.WriteString("**" + gnot(r.Amount) + "** to [" + inline(v.Title) + "](" + webPath + ":c/" + v.ID + "), on " + when(r.At) + ".\n\n")
	b.WriteString("| Receipt | " + r.ID + " |\n|---|---|\n")
	if r.Anonymous {
		b.WriteString("| From | Anonymous |\n")
	} else {
		b.WriteString("| From | `" + r.Donor.String() + "` |\n")
	}
	if r.Tip > 0 {
		b.WriteString("| Tip to Bolo | " + gnot(r.Tip) + " |\n")
	}
	b.WriteString("| The campaign's total right after it | " + gnot(r.RaisedAfter) + " |\n\n")
	if r.MessageHidden {
		b.WriteString("Message: hidden by moderation.\n\n")
	} else if r.Message != "" {
		b.WriteString("Message: “" + inline(r.Message) + "”\n\n")
	}
	b.WriteString("## Where it went\n\n")
	if bar := progressBar(v.NetRaised, v.Goal, barWide); bar != "" {
		b.WriteString(bar + "\n\n")
	}
	b.WriteString("The campaign is " + strings.ToLower(statusWord(v.Status)) + ": " + gnot(v.NetRaised) + " raised net of refunds")
	if v.Goal > 0 {
		b.WriteString(", " + percent(v.NetRaised, v.Goal) + " of its " + gnot(v.Goal) + " goal")
	}
	b.WriteString(".\n\n")
	if v.Mode == modeEscrow {
		b.WriteString("- " + gnot(v.Withdrawn) + " withdrawn by the beneficiary, `" + v.Beneficiary.String() + "`\n")
		b.WriteString("- " + gnot(v.Balance) + " held in escrow, at `" + v.EscrowAddress.String() + "`\n\n")
	} else {
		b.WriteString("Every gift went straight to the beneficiary, `" + v.Beneficiary.String() + "`, in the same transaction.\n\n")
	}
	b.WriteString("[The campaign](" + webPath + ":c/" + v.ID + ") · [All gifts](" + webPath + ":c/" + v.ID + "/donations)")
	if v.Mode == modeEscrow {
		b.WriteString(" · [Money out](" + webPath + ":c/" + v.ID + "/ledger)")
	}
	b.WriteString("\n")
	return b.String()
}

// renderDonations is a page of a campaign's gifts, newest first, under one line of
// totals.
func renderDonations(c *campaign, page int) string {
	id := idString(c.id)
	s := c.state
	var b strings.Builder
	b.WriteString("# Gifts to [" + inline(c.text.title) + "](" + webPath + ":c/" + id + ")\n\n")
	b.WriteString(count(s.donationCount, "gift", "gifts") + " from " + count(s.donorCount, "donor", "donors") + " · " + gnot(s.raised) + " given")
	if s.refunded > 0 {
		b.WriteString(" · " + gnot(s.refunded) + " refunded")
	}
	b.WriteString("\n\n")
	gifts := ListReceipts(id, page, listPage)
	for _, r := range gifts {
		writeGift(&b, r)
	}
	if len(gifts) == 0 {
		b.WriteString(empty(page, "No gifts yet.\n", "No gifts on this page.\n"))
	}
	writePager(&b, webPath+":c/"+id+"/donations", page, listPage, c.receipts.Size())
	return b.String()
}

// renderLedger is a page of a campaign's money out of its escrow: withdrawals, then
// refunds, each newest first. In direct mode, it says that nothing goes out: Withdraw
// and Refund refuse a direct campaign, so neither list ever holds one.
func renderLedger(c *campaign, page int) string {
	id := idString(c.id)
	var b strings.Builder
	b.WriteString("# Money out of [" + inline(c.text.title) + "](" + webPath + ":c/" + id + ")\n\n")
	if c.mode != modeEscrow {
		b.WriteString("**Direct**: each gift went straight to the beneficiary, `" + c.beneficiary.String() + "`, when it was given. Nothing is held, so nothing goes out.\n\n")
		b.WriteString("[All gifts](" + webPath + ":c/" + id + "/donations)\n")
		return b.String()
	}
	b.WriteString("Every coin that left the escrow, `" + escrowAddr(c.id).String() + "`: to the beneficiary, or back to donors.\n\n")
	b.WriteString("## Withdrawals\n\n")
	if ws := ListWithdrawals(id, page, listPage); len(ws) > 0 {
		b.WriteString("| When (UTC) | GNOT | Outside Bolo | To |\n|---|--:|--:|---|\n")
		for _, w := range ws {
			b.WriteString("| " + stamp(w.At) + " | " + amount(w.Amount) + " | " + amount(w.Untracked) + " | `" + w.To.String() + "` |\n")
		}
		b.WriteString("\nOutside Bolo: coins sent to the escrow directly, which the withdrawal carried too.\n")
	} else {
		b.WriteString(empty(page, "None.\n", "None on this page.\n"))
	}
	b.WriteString("\n## Refunds\n\n")
	if rs := ListRefunds(id, page, listPage); len(rs) > 0 {
		b.WriteString("| When (UTC) | GNOT | How | To |\n|---|--:|---|---|\n")
		for _, r := range rs {
			to := "Anonymous"
			if r.Donor != "" {
				to = "`" + r.Donor.String() + "`"
			}
			how := "refund"
			if r.Kind == windowExit {
				how = "exit claim"
			}
			b.WriteString("| " + stamp(r.At) + " | " + amount(r.Amount) + " | " + how + " | " + to + " |\n")
		}
	} else {
		b.WriteString(empty(page, "None.\n", "None on this page.\n"))
	}
	n := c.withdrawals.Size()
	if m := c.refunds.Size(); m > n {
		n = m
	}
	writePager(&b, webPath+":c/"+id+"/ledger", page, listPage, n)
	return b.String()
}

// renderUpdates is a page of a campaign's updates, newest first, each as a quote.
func renderUpdates(c *campaign, page int) string {
	id := idString(c.id)
	var b strings.Builder
	b.WriteString("# Updates on [" + inline(c.text.title) + "](" + webPath + ":c/" + id + ")\n\n")
	updates := ListUpdates(id, page, updatesPage)
	for _, u := range updates {
		b.WriteString("## " + when(u.At) + "\n")
		b.WriteString(sanitize.Blockquote(u.Body))
	}
	if len(updates) == 0 {
		b.WriteString(empty(page, "No updates yet.\n", "No updates on this page.\n"))
	}
	writePager(&b, webPath+":c/"+id+"/updates", page, updatesPage, c.updates.Size())
	return b.String()
}

// empty says a page of a campaign's list has nothing on it: first on the list's first
// page, where it means the list is empty, later past it (API §5).
func empty(page int, first, later string) string {
	if page == 1 {
		return first
	}
	return later
}

// writePager writes links to the pages before and after page, of n entries, size a
// page.
func writePager(b *strings.Builder, base string, page, size, n int) {
	var links []string
	if page > 1 {
		links = append(links, "[Newer]("+base+"?page="+strconv.Itoa(page-1)+")")
	}
	if page*size < n {
		links = append(links, "[Older]("+base+"?page="+strconv.Itoa(page+1)+")")
	}
	if len(links) > 0 {
		b.WriteString("\n" + strings.Join(links, " · ") + "\n")
	}
}

// addressList returns the address page's list a path segment names, and its heading;
// nil for any other segment. They show listed campaigns only, as they promote (API §5).
func addressList(name string) (func(address, string, int) ([]CampaignView, string), string) {
	switch name {
	case "organized":
		return ListByOrganizer, "Organized"
	case "named":
		return ListByBeneficiary, "Named as beneficiary by an organizer"
	case "gave":
		return ListByDonor, "Gave to, without anonymity"
	}
	return nil, ""
}

// renderAddress is the public address page: the short address as its title and the
// full one under it, then the 10 newest campaigns of each list, as cards, with "More"
// while a list goes on.
func renderAddress(addr address) string {
	var b strings.Builder
	b.WriteString("# `" + short(addr) + "` on Bolo\n\n")
	b.WriteString("`" + addr.String() + "`: the campaigns this address organized, is named beneficiary of, or gave to without anonymity. Campaigns hidden from listings and anonymous gifts aren't shown.\n\n")
	for _, name := range []string{"organized", "named", "gave"} {
		list, heading := addressList(name)
		b.WriteString("## " + heading + "\n\n")
		views, next := list(addr, "", addressSection)
		writeListed(&b, views, next != "")
		if next != "" {
			b.WriteString("[More](" + webPath + ":u/" + addr.String() + "/" + name + "?after=" + next + ")\n\n")
		}
	}
	return b.String()
}

// renderAddressList is one of the address page's lists, 20 at a time by cursor.
func renderAddressList(addr address, name, heading string, list func(address, string, int) ([]CampaignView, string), after string) string {
	var b strings.Builder
	b.WriteString("# `" + short(addr) + "`: " + strings.ToLower(heading[:1]) + heading[1:] + "\n\n")
	b.WriteString("[All of `" + addr.String() + "` on Bolo](" + webPath + ":u/" + addr.String() + ")\n\n")
	views, next := list(addr, after, listPage)
	writeListed(&b, views, after != "" || next != "")
	if next != "" {
		b.WriteString("[More](" + webPath + ":u/" + addr.String() + "/" + name + "?after=" + next + ")\n")
	}
	return b.String()
}

// writeListed writes the cards of the listed campaigns among views: a delisted one is
// left out of a list that promotes. With none to show, it says so, and whether this is
// only one page of the list: a later one, or one a "More" follows (paged).
func writeListed(b *strings.Builder, views []CampaignView, paged bool) {
	var listed []CampaignView
	for _, v := range views {
		if v.Listed {
			listed = append(listed, v)
		}
	}
	switch {
	case len(listed) > 0:
		writeCards(b, listed)
	case paged:
		b.WriteString("None on this page.\n\n")
	default:
		b.WriteString("None.\n\n")
	}
}

// renderLookup is the page that finds an address: gnoweb's form, which submits back
// here as ?address=. A valid address gets its page; anything else, the form again with
// one fixed line, echoing nothing from the request (API §5).
func renderLookup(q map[string]string) string {
	raw, asked := q["address"]
	if asked {
		if addr, ok := parseAddress(raw); ok {
			return renderAddress(addr)
		}
	}
	var b strings.Builder
	b.WriteString("# Find an address\n\n")
	if asked {
		b.WriteString("That isn't a gno.land address.\n\n")
	}
	b.WriteString("See what an address has done on Bolo: the campaigns it organized, is named beneficiary of, or gave to without anonymity.\n\n")
	b.WriteString("<gno-form path=\"u\">\n  <gno-input name=\"address\" placeholder=\"g1…\" />\n</gno-form>\n")
	return b.String()
}

// renderAbout is the guarantees table, what Bolo costs, where tips go, how to check it,
// and what not to do (PRD §3, UI spec §4.11).
func renderAbout() string {
	return "# What Bolo guarantees, and what it doesn't\n\n" +
		"| A donor can verify themselves | A donor must still take on faith |\n|---|---|\n" +
		"| The exact amount the campaign has received | That the campaign's story is true |\n" +
		"| Every payout: amount, destination, timestamp | That the beneficiary spends it as promised |\n" +
		"| That no fee was taken | That the person in the photo consented to it |\n" +
		"| That the organizer cannot quietly change the beneficiary | That the organizer is who they claim to be |\n" +
		"| That their own donation arrived and is counted | |\n" +
		"| That nothing in Bolo, and nobody running it, can freeze or seize it | |\n\n" +
		"The last row is scoped to Bolo: the gno.land chain's own governance sits above every application on it.\n\n" +
		"**A chain fixes custody fraud. It does not fix claim fraud.** \"Verified on-chain\" never means \"verified true\".\n\n" +
		"## Fees\n\n0% platform fee. Your wallet pays a small network fee. Tips to Bolo are optional.\n\n" +
		"## Where tips go\n\nTo `" + tipRecipient.String() + "`, in the same transaction as your gift: Bolo keeps no treasury.\n\n" +
		"## How to check\n\nEvery campaign page lists its escrow and bond addresses: read their balances on any explorer, and every transaction behind each figure. The code doing all of this is public, at `" + pkgPath + "`, and nobody can change it.\n\n" +
		"## Don't send coins to Bolo's addresses directly\n\nGive through a campaign's page. Coins sent straight to this version's own address can be swept to the tip recipient; coins sent to the version registry can't be recovered.\n\n" +
		"[Bolo](" + webPath + ")\n"
}

// renderParams shows the parameters new campaigns get, the live settings in words,
// and the admin.
func renderParams() string {
	s := GetSettings()
	p := params
	a, pending := GetAdmin()
	var b strings.Builder
	b.WriteString("# Parameters\n\n## For new campaigns\n\n")
	b.WriteString("- Creation deposit: " + gnot(p.CreationDeposit) + "\n")
	b.WriteString("- Dormancy: " + days(p.DormancyPeriod) + "; exit delay: " + days(p.ExitDelay) + "; bond hold: " + days(p.BondHold) + "\n\n")
	b.WriteString("## Settings\n\n")
	if s.Paused {
		b.WriteString("- Gifts: paused — withdrawals and refunds still work\n")
	} else {
		b.WriteString("- Gifts: accepted\n")
	}
	switch {
	case s.Sunset:
		b.WriteString("- New campaigns: not on this version\n")
	case s.Paused:
		b.WriteString("- New campaigns: paused\n")
	default:
		b.WriteString("- New campaigns: accepted\n")
	}
	b.WriteString("- Smallest gift: " + gnot(s.MinDonation) + "\n")
	b.WriteString("- One-click amounts: ")
	for i, preset := range s.Presets {
		if i > 0 {
			b.WriteString(" · ")
		}
		b.WriteString(gnot(preset))
	}
	b.WriteString("\n- Escrow cap: ")
	if s.MaxEscrowBalance == 0 {
		b.WriteString("none")
	} else {
		b.WriteString(gnot(s.MaxEscrowBalance))
	}
	b.WriteString("\n- Tips go to: `" + s.TipRecipient.String() + "`\n")
	b.WriteString("- Categories: " + strings.Join(s.Categories, ", ") + "\n\n")
	b.WriteString("## Admin\n\n`" + a.String() + "`")
	if pending != "" {
		b.WriteString(", handing over to `" + pending.String() + "`")
	}
	b.WriteString("\n")
	return b.String()
}

// progressBar draws how much of its goal a campaign raised (UI spec §5, ProgressBar):
// an SVG image of two numbers, which gnoweb accepts inline as a data URI, width wide.
// It fills min(net, goal) of goal; its text, the percentage, is uncapped. With no goal,
// there is no bar.
func progressBar(net, goal int64, width int) string {
	if goal <= 0 {
		return ""
	}
	filled := net
	if filled > goal {
		filled = goal
	}
	w := strconv.Itoa(width)
	return "![" + percent(net, goal) + " of the goal](data:image/svg+xml;utf8," +
		"%3Csvg%20xmlns='http://www.w3.org/2000/svg'%20width='" + w + "'%20height='10'%20viewBox='0%200%20" + w + "%2010'%3E" +
		"%3Crect%20width='" + w + "'%20height='10'%20rx='5'%20fill='%23888'%20fill-opacity='.25'/%3E" +
		"%3Crect%20width='" + strconv.FormatInt(share(filled, goal, int64(width)), 10) + "'%20height='10'%20rx='5'%20fill='%23E4A11B'/%3E" +
		"%3C/svg%3E)"
}

// percent writes net as a share of goal, rounded down and uncapped: "124%".
func percent(net, goal int64) string {
	return strconv.FormatInt(share(net, goal, 100), 10) + "%"
}

// share is part×scale/whole rounded down, for whole > 0, and 0 for part ≤ 0: exact for
// any part up to math.MaxInt64/scale, past every amount of ugnot there is, and held
// there beyond, so the product never overflows.
func share(part, whole, scale int64) int64 {
	if part <= 0 {
		return 0
	}
	if part > math.MaxInt64/scale {
		part = math.MaxInt64 / scale
	}
	return part * scale / whole
}

// short shortens an address where a reader recognizes it rather than checks it: its
// first eight and last six characters (UI spec §4.13).
func short(a address) string {
	s := a.String()
	if len(s) <= 14 {
		return s
	}
	return s[:8] + "…" + s[len(s)-6:]
}

// addrLink links an address's short form, in a code span, to its address page: Bolo's
// own link, where gnoweb makes no mention (API §5).
func addrLink(a address) string {
	return "[`" + short(a) + "`](" + webPath + ":u/" + a.String() + ")"
}

// gnot writes an amount of ugnot in GNOT: up to six decimals, trailing zeros dropped.
func gnot(ugnot int64) string {
	return amount(ugnot) + " GNOT"
}

// amount writes an amount of ugnot as a number of GNOT, for a column headed GNOT.
func amount(ugnot int64) string {
	sign := ""
	if ugnot < 0 {
		sign, ugnot = "-", -ugnot
	}
	whole, frac := ugnot/1_000_000, ugnot%1_000_000
	out := sign + strconv.FormatInt(whole, 10)
	if frac != 0 {
		f := strconv.FormatInt(frac+1_000_000, 10)[1:]
		out += "." + strings.TrimRight(f, "0")
	}
	return out
}

// when writes a Unix time in UTC.
func when(unix int64) string {
	return stamp(unix) + " UTC"
}

// stamp writes a Unix time in UTC without saying so, for a column that does.
func stamp(unix int64) string {
	return time.Unix(unix, 0).UTC().Format("2006-01-02 15:04")
}

// day writes a Unix time's day in UTC, where the minute is written nearby: a figure's
// caption, under the full time in the dates line.
func day(unix int64) string {
	return time.Unix(unix, 0).UTC().Format("2006-01-02")
}

// left writes a real timer's countdown (UI spec §5, Countdown): whole days left, then
// "less than a day left".
func left(until int64) string {
	d := (until - now()) / secondsPerDay
	if d < 1 {
		return "less than a day left"
	}
	return count(int(d), "day left", "days left")
}

// count writes n of something: one, or many.
func count(n int, one, many string) string {
	if n == 1 {
		return "1 " + one
	}
	return strconv.Itoa(n) + " " + many
}

// days writes a duration in seconds as whole days.
func days(seconds int64) string {
	return strconv.FormatInt(seconds/secondsPerDay, 10) + " days"
}

// statusWord names a status in the UI spec's words (§8.1).
func statusWord(status string) string {
	switch status {
	case statusOpen:
		return "Open"
	case statusClosed:
		return "Closed to new donations"
	}
	return "Completed"
}

// modeWord names a custody mode in the UI spec's words (§8.1).
func modeWord(mode string) string {
	if mode == modeEscrow {
		return "Escrow"
	}
	return "Direct"
}

// inline escapes text for an inline slot: sanitize.InlineText, which leaves no link and
// no image, then the mentions gnoweb would still make links of — "@name", and an
// address after a space — each to a page whose owner writes it (API §5). A backslash
// keeps "@" as it reads; a no-break space looks like the space it replaces.
func inline(s string) string {
	s = strings.ReplaceAll(sanitize.InlineText(s), "@", `\@`)
	return strings.ReplaceAll(s, " g1", "\u00a0g1")
}

// lineStart escapes text for an inline slot that opens a line — the title's heading,
// the notice's line — where gnoweb also links an address with nothing before it:
// "&#103;" reads as the "g" it replaces. Only there: gnoweb's table of contents shows a
// card's heading as written, and a card's title sits in a link's text, where gnoweb
// makes no mention (API §5).
func lineStart(s string) string {
	s = inline(s)
	if strings.HasPrefix(s, "g1") {
		s = "&#103;" + s[1:]
	}
	return s
}
