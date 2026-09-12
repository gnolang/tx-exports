package kourt
import (
	"math/overflow"
	"strconv"
	"strings"
	bptree "gno.land/p/nt/bptree/v0"
	sanitize "gno.land/p/nt/markdown/sanitize/v0"
)
var (
	burnIdx    = bptree.NewBPTree32()
	createdIdx = bptree.NewBPTree32()
	courtSeq   uint64
)
func beInv(v int64) string {
	if v < 0 {
		v = 0
	}
	return beClaimKey(^uint64(v))
}
func reindexBurn(c *Court, spent int64) {
	sum, ok := overflow.Add64(c.burnedGNOT, spent)
	if !ok {
		return
	}
	if c.burnedGNOT > 0 || c.burnKey != "" {
		burnIdx.Remove(c.burnKey)
	}
	c.burnedGNOT = sum
	c.burnKey = beInv(c.burnedGNOT) + c.id
	burnIdx.Set(c.burnKey, c.id)
	recordBurn(c)
}
func indexNewCourt(c *Court) {
	courtSeq++
	c.createdSeq = courtSeq
	createdIdx.Set(beClaimKey(c.createdSeq), c.id)
	c.burnKey = beInv(0) + c.id
	burnIdx.Set(c.burnKey, c.id)
}
func listedPage(order string, offset, limit int) []string {
	out := []string{}
	if limit <= 0 {
		return out
	}
	skipped := 0
	take := func(_ string, v any) bool {
		slug, ok := v.(string)
		if !ok || !Exists(slug) {
			return false
		}
		c := mustCourt(slug)
		if c.tier == tierHidden {
			return false
		}
		if skipped < offset {
			skipped++
			return false
		}
		out = append(out, slug)
		return len(out) >= limit
	}
	if order == "new" {
		createdIdx.ReverseIterate("", "", take)
	} else {
		burnIdx.Iterate("", "", take)
	}
	return out
}
func ListedCourtsBy(order string, offset, limit int) []string {
	return listedPage(order, offset, limit)
}
func CourtBurnedGNOT(courtSlug string) int64 { return mustCourt(courtSlug).burnedGNOT }
func claimTitleFor(c *Court, cs *claimState) string {
	if c.mod != nil {
		if clm := lookupClaimMod(c.mod, cs.id); clm != nil {
			if clm.purged {
				return "[removed · " + sanitize.InlineText(clm.tombstone) + "]"
			}
			if clm.global {
				return "[text withheld]"
			}
		}
	}
	return sanitize.InlineText(cs.title)
}
func claimBodyVisible(c *Court, cs *claimState) string {
	if cs.body == "" {
		return ""
	}
	if c.mod != nil {
		if clm := lookupClaimMod(c.mod, cs.id); clm != nil {
			if clm.purged || clm.global {
				return ""
			}
		}
	}
	return cs.body
}
func claimMediaVisible(c *Court, cs *claimState) []mediaItem {
	if len(cs.media) == 0 {
		return nil
	}
	if c.mod != nil {
		if clm := lookupClaimMod(c.mod, cs.id); clm != nil {
			if clm.purged || clm.global {
				return nil
			}
		}
	}
	return cs.media
}
func claimBodyFor(c *Court, cs *claimState) string {
	body := claimBodyVisible(c, cs)
	if body == "" {
		return ""
	}
	return sanitize.Block(body)
}
func claimBodyQuoted(c *Court, cs *claimState) string {
	body := claimBodyVisible(c, cs)
	if body == "" {
		return ""
	}
	return sanitize.Blockquote(body)
}
const (
	platformName   = "Kourt"
	platformTicker = "KOURT"
)
func qualifiedSymbol(c *Court) string {
	return platformTicker + ":" + sanitize.InlineText(c.coin.Symbol())
}
func courtNameFor(c *Court) string {
	if c.mod != nil && c.mod.courtPurged {
		return "[removed · " + sanitize.InlineText(c.mod.courtTombstone) + "]"
	}
	return sanitize.InlineText(c.name)
}
func courtDescFor(c *Court) string {
	if c.desc == "" {
		return ""
	}
	if c.mod != nil && c.mod.courtPurged {
		return ""
	}
	return sanitize.InlineText(c.desc)
}
func hideBanner(c *Court, cs *claimState) string {
	if c.mod == nil {
		return ""
	}
	clm := lookupClaimMod(c.mod, cs.id)
	if clm == nil {
		return ""
	}
	switch {
	case clm.purged:
		return "> **Removed on legal grounds** (" + sanitize.InlineText(clm.tombstone) +
			"). The claim's lifecycle is unaffected: stakes, verdict and refunds proceed.\n\n"
	case clm.global:
		return "> **Text withheld pending review.** The claim's id, its state, its deadlines and every balance are still shown, so you can always act on a position.\n\n"
	case clm.meta:
		return "> **Hidden by the review court.** Listed nowhere, reachable here; the lifecycle is unaffected.\n\n"
	case clm.court:
		return "> **Hidden by this court's moderators.** Listed nowhere, reachable here; the lifecycle is unaffected.\n\n"
	}
	return ""
}
const (
	stripHeading = "Still flaggable"
	stripBlurb   = "Answered claims that can still be flagged as spam — nearest deadline first. A claim leaves this list when its rewards are opened, not when it settles, so a settled claim stays here while it can still be flagged. This list ignores moderation: a claim hidden from the lists above still appears here."
)
func writeStrip(b *strings.Builder, slug string) {
	c := mustCourt(slug)
	n := StripSize(slug)
	if n == 0 {
		return
	}
	b.WriteString("## " + stripHeading + "\n\n" + stripBlurb + "\n\n")
	ids := StripPage(slug, 0, renderPageSize)
	for _, id := range ids {
		cs := mustClaim(c, id)
		b.WriteString("- [" + claimTitleFor(c, cs) + "](/r/kourt/kourtv2:" + slug + "/" +
			strconv.FormatUint(id, 10) + ") — settles at block " +
			strconv.FormatInt(cs.answerHeight+settleDelay, 10) + "\n")
	}
	if n > len(ids) {
		b.WriteString("- _…and " + strconv.Itoa(n-len(ids)) + " more_\n")
	}
	b.WriteString("\n")
}
func writePending(b *strings.Builder, slug string) {
	c := mustCourt(slug)
	n := PendingSize(slug)
	if n == 0 {
		return
	}
	b.WriteString("## Awaiting an answer\n\nSeeded and appeal claims that no one has answered yet.\n\n")
	ids := PendingPage(slug, 0, renderPageSize)
	for _, id := range ids {
		cs := mustClaim(c, id)
		tag := ""
		if cs.seeded {
			tag = " — seeded by a moderator"
		}
		b.WriteString("- [" + claimTitleFor(c, cs) + "](/r/kourt/kourtv2:" + slug + "/" +
			strconv.FormatUint(id, 10) + ")" + tag + "\n")
	}
	if n > len(ids) {
		b.WriteString("- _…and " + strconv.Itoa(n-len(ids)) + " more_\n")
	}
	b.WriteString("\n")
}
func writeAppeal(b *strings.Builder, c *Court, cs *claimState) {
	if c.id != metaSlug {
		return
	}
	verb, court, target, valid := AppealParse(cs.id)
	if !valid {
		b.WriteString("> _Not a valid review request — this is an ordinary claim on the review court._\n\n")
		return
	}
	b.WriteString("## Review request\n\n")
	b.WriteString("- action: **" + sanitize.InlineText(verb) + "** — " +
		appealVerbGloss(verb) + "\n")
	b.WriteString("- court: " + sanitize.InlineText(court) + "\n")
	if verbIsAggressive(verb) {
		b.WriteString("- this is an **aggressive** act: it can only carry on a " +
			"contested vote that real opposition turned out for. Silence " +
			"defeats it.\n")
	} else {
		b.WriteString("- this is a **restorative** act: it undoes a restriction, so " +
			"it can carry undisputed. Silence lets it through.\n")
	}
	if verb == verbSetmods {
		b.WriteString("- installs candidate set #" + strconv.FormatUint(target, 10) + ":\n")
		if !Exists(court) {
			b.WriteString("  - _that court does not exist_\n\n")
			return
		}
		tc := mustCourt(court)
		if tc.mod == nil || tc.mod.candidates == nil ||
			tc.mod.candidates.Get(beClaimKey(target)) == nil {
			b.WriteString("  - **this candidate set does not exist yet — do not approve**\n\n")
			return
		}
		cand := tc.mod.candidates.Get(beClaimKey(target)).(*modCandidate)
		for _, a := range cand.members {
			b.WriteString("  - " + sanitize.InlineText(a.String()) + "\n")
		}
		b.WriteString("  - threshold: " + strconv.Itoa(cand.m) + " of " +
			strconv.Itoa(len(cand.members)) + " must agree\n")
	} else if target != 0 {
		b.WriteString("- claim: " + strconv.FormatUint(target, 10) + "\n")
	}
	b.WriteString("\n")
}
func modActLine(a modAct, kind string) string {
	line := "- " + kind + " " + strconv.FormatUint(a.rowID, 10) +
		" · block " + strconv.FormatInt(a.height, 10) + " · " +
		sanitize.InlineText(a.code) + " · by " + sanitize.InlineText(a.actor.String())
	switch {
	case a.purged:
		line += " — _[reason removed on legal grounds]_"
	case a.reason != "":
		line += " — " + sanitize.InlineText(a.reason)
	}
	return line
}
func renderModLog(slug string) string {
	if !Exists(slug) {
		return "## Not found\nNo court by that slug."
	}
	c := mustCourt(slug)
	b := strings.Builder{}
	b.WriteString("# Moderation log — " + courtNameFor(c) + "\n\n")
	b.WriteString("Every moderation act on this court's CLAIMS and COMMENTS is recorded here: who acted, what they did, and when. Moderation controls what is listed; it never moves a coin or changes a verdict.\n\n")
	b.WriteString("[Who holds these seats, and how to challenge them](/r/kourt/kourtv2:" +
		sanitize.InlineText(slug) + "/election)\n\n")
	b.WriteString("Curation — which claims a moderator filed under which heading — is " +
		"not in this list. The tree it produced is on the [court page](/r/kourt/kourtv2:" + sanitize.InlineText(slug) + "); the acts themselves are in " +
		"the chain's event stream.\n\n")
	if c.mod == nil {
		b.WriteString("## Moderators\n\n1-of-1 — " + c.admin.String() +
			" (the court's creator, until an election or an appointment changes it)\n\n")
		b.WriteString("_No moderation acts yet._\n")
		return b.String()
	}
	cm := c.mod
	if cm.courtPurged {
		b.WriteString("> **This court was removed on legal grounds** (" +
			sanitize.InlineText(cm.courtTombstone) + "). No new claims may be opened; existing claims settle and pay out normally.\n\n")
	}
	b.WriteString("## Moderators\n\n")
	if cm.n == 0 {
		b.WriteString("_None — the set is empty; the court's holders can elect one._\n\n")
	} else {
		b.WriteString("- " + strconv.Itoa(cm.m) + " of " + strconv.Itoa(cm.n) +
			" must agree for a moderation act\n")
		if sm := speechM(cm); sm != cm.m {
			b.WriteString("- " + strconv.Itoa(sm) + " of " + strconv.Itoa(cm.n) +
				" for a **board** act — hiding a comment, slashing standing, " +
				"freezing an address — because speech takes a wider agreement " +
				"than the set's own threshold\n")
		}
		if cm.suspended {
			b.WriteString("- **suspended** — they cannot take new moderation acts. " +
				"The hides and freezes already in place stand until cleared, and " +
				"any member may still lift their own\n")
		}
		if cm.installedByMeta {
			b.WriteString("- seated by the review court; may not seed claims until a local election\n")
		}
		b.WriteString("\n")
	}
	pendingRows := []string{}
	pendingSeen := 0
	pendingMore := false
	cm.pending.Iterate("", "", func(key string, v any) bool {
		pendingSeen++
		if a, ok := v.(*approval); ok {
			deadline := a.openedAt + pendingTTLBlocks
			if !approvalStale(a) {
				when := " (block " + strconv.FormatInt(deadline, 10) + ")"
				if at := deadlineTime(a.openedAtTime, blocksToSecs(pendingTTLBlocks)); at != 0 {
					when = " " + strconv.FormatInt(at, 10) + when
				}
				pendingRows = append(pendingRows,
					"- "+sanitize.InlineCode(key)+" — "+strconv.Itoa(a.approvers.Size())+
						" of "+strconv.Itoa(cm.m)+" approved, expires at"+when)
			}
		}
		if len(pendingRows) >= renderPageSize || pendingSeen >= renderPageSize {
			pendingMore = true
			return true
		}
		return false
	})
	if len(pendingRows) > 0 {
		b.WriteString("## Awaiting approval\n\nProposals this set has started and not yet carried. An approval expires if the set does not reach its threshold in time; the reason is withheld until the act carries.\n\n")
		for _, r := range pendingRows {
			b.WriteString(r + "\n")
		}
		if pendingMore {
			b.WriteString("- _…more not shown_\n")
		}
		b.WriteString("\n")
	}
	rows := []string{}
	visited := 0
	truncated := false
	for i := len(cm.log) - 1; i >= 0 && len(rows) < renderPageSize; i-- {
		rows = append(rows, modActLine(cm.log[i], "court row"))
	}
	if len(rows) >= renderPageSize {
		truncated = true
	}
	cm.claims.ReverseIterate("", "", func(_ string, v any) bool {
		if len(rows) >= renderPageSize {
			truncated = true
			return true
		}
		clm, ok := v.(*claimMod)
		if !ok {
			return false
		}
		visited++
		for i := len(clm.log) - 1; i >= 0; i-- {
			rows = append(rows, modActLine(clm.log[i], "row"))
			if len(rows) >= renderPageSize {
				truncated = true
				return true
			}
		}
		if visited >= renderPageSize {
			truncated = true
			return true
		}
		return false
	})
	b.WriteString("## Acts\n\n")
	if len(rows) == 0 {
		b.WriteString("_No moderation acts yet._\n")
		return b.String()
	}
	for _, r := range rows {
		b.WriteString(r + "\n")
	}
	if truncated {
		b.WriteString("\n_Showing the " + strconv.Itoa(len(rows)) +
			" most recent acts. This court has moderated " + strconv.Itoa(cm.claims.Size()) +
			" claims; older acts are not shown._\n")
	}
	return b.String()
}
func appealVerbGloss(verb string) string {
	switch verb {
	case verbUnhide:
		return "un-hides a claim its own court's moderators hid"
	case verbClear:
		return "clears a hide the review court itself placed"
	case verbHide:
		return "hides a claim across the platform, over its court's head"
	case verbSuspend:
		return "disarms a court's moderator set — they can take no further act"
	case verbUnsuspend:
		return "re-arms a suspended moderator set, and re-applies the hides that " +
			"were masked while it was disarmed"
	case verbSetmods:
		return "installs a moderator set on that court, replacing whoever holds " +
			"the seats now"
	}
	return "an action this page does not recognise"
}
