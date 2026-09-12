package kourt
import (
	"strconv"
	"strings"
	bptree "gno.land/p/nt/bptree/v0"
	sanitize "gno.land/p/nt/markdown/sanitize/v0"
)
const (
	maxBoardTextLen = 2000
	maxBoardRowsPerClaim = 512
	maxBoardRowsPerAuthor = 8
	maxBoardRepliesShown = 8
)
type boardRow struct {
	id     uint64
	parent uint64
	author address
	text   string
	score    int64
	scoreKey string
	at int64
	hiddenByAuthor bool
	hiddenByMod    bool
	global          bool
	purged          bool
	globalClearedAt     int64
	globalClearedAtTime int64
}
func boardMark(r *boardRow) string {
	switch {
	case r.purged:
		return "x"
	case r.global:
		return "g"
	case r.hiddenByAuthor || r.hiddenByMod:
		return "h"
	}
	return "."
}
func ensureBoard(cs *claimState) {
	if cs.board == nil {
		cs.board = bptree.NewBPTree32()
		cs.boardTop = bptree.NewBPTree32()
		cs.boardWrote = bptree.NewBPTree32()
	}
}
func ensureKids(cs *claimState) *bptree.BPTree {
	if cs.boardKids == nil {
		cs.boardKids = bptree.NewBPTree32()
	}
	return cs.boardKids
}
func ensureScoreIdx(cs *claimState) *bptree.BPTree {
	if cs.boardScore == nil {
		cs.boardScore = bptree.NewBPTree32()
	}
	return cs.boardScore
}
func ensureVoted(cs *claimState) *bptree.BPTree {
	if cs.boardVoted == nil {
		cs.boardVoted = bptree.NewBPTree32()
	}
	return cs.boardVoted
}
func boardOpen(cs *claimState) bool { return cs.verdictAt == 0 && !cs.closed }
func boardWroteBy(cs *claimState, who address) int64 {
	if cs.boardWrote == nil {
		return 0
	}
	if v := cs.boardWrote.Get(string(who)); v != nil {
		return v.(int64)
	}
	return 0
}
func PostComment(cur realm, courtSlug string, claimID uint64, parentRow uint64, text string) uint64 {
	if !cur.IsCurrent() {
		panic(errStaleRealm)
	}
	who := cur.Previous().Address()
	c := mustCourt(courtSlug)
	if courtIsPurged(c) {
		panic("kourtv2: this court is purged; it takes no new content")
	}
	cs := mustClaim(c, claimID)
	if !boardOpen(cs) {
		panic("kourtv2: this claim is settled; its board is closed to new comments")
	}
	mustBoardWritable(c, cs, who)
	text = strings.TrimSpace(text)
	if text == "" {
		panic("kourtv2: a comment needs text")
	}
	if runeLen(text) > maxBoardTextLen {
		panic("kourtv2: a comment is at most " + strconv.Itoa(maxBoardTextLen) + " characters")
	}
	if parentRow != 0 {
		p := mustBoardRow(cs, parentRow)
		if p.parent != 0 {
			panic("kourtv2: replies are one level deep; reply to the comment, not to a reply")
		}
	}
	if boardWroteBy(cs, who) >= maxBoardRowsPerAuthor {
		panic("kourtv2: you already have " + strconv.Itoa(maxBoardRowsPerAuthor) +
			" comments on this claim")
	}
	if cs.board != nil && cs.board.Size() >= maxBoardRowsPerClaim {
		panic("kourtv2: this claim's board is full")
	}
	mustSpendPost(c, who)
	ensureBoard(cs)
	cs.boardNextID++
	r := &boardRow{
		id: cs.boardNextID, parent: parentRow, author: who, text: text,
		at: heightNow(),
	}
	k := beClaimKey(r.id)
	cs.board.Set(k, r)
	if parentRow == 0 {
		cs.boardTop.Set(k, r)
		scoreIndexPut(cs, r)
	} else {
		ensureKids(cs).Set(beClaimKey(parentRow)+k, r)
	}
	cs.boardWrote.Set(string(who), boardWroteBy(cs, who)+1)
	return r.id
}
func mustBoardRow(cs *claimState, rowID uint64) *boardRow {
	if cs.board == nil {
		panic("kourtv2: no such comment")
	}
	v := cs.board.Get(beClaimKey(rowID))
	if v == nil {
		panic("kourtv2: no such comment")
	}
	return v.(*boardRow)
}
func HideOwnComment(cur realm, courtSlug string, claimID uint64, rowID uint64, hide bool) {
	if !cur.IsCurrent() {
		panic(errStaleRealm)
	}
	who := cur.Previous().Address()
	cs := mustClaim(mustCourt(courtSlug), claimID)
	r := mustBoardRow(cs, rowID)
	if r.author != who {
		panic("kourtv2: only a comment's author may hide their own comment")
	}
	r.hiddenByAuthor = hide
	if hide {
		scoreIndexDrop(cs, r)
	} else {
		scoreIndexPut(cs, r)
	}
}
func BoardSize(courtSlug string, claimID uint64) int {
	cs := mustClaim(mustCourt(courtSlug), claimID)
	if cs.board == nil {
		return 0
	}
	return cs.board.Size()
}
func BoardCounts(courtSlug string, ids string) string {
	c := mustCourt(courtSlug)
	out := strings.Builder{}
	sent := 0
	for _, part := range strings.Split(ids, ",") {
		if sent >= seriesPageMax {
			break
		}
		part = strings.TrimSpace(part)
		if part == "" {
			continue
		}
		id, err := strconv.ParseUint(part, 10, 64)
		if err != nil {
			continue
		}
		v := c.claims.Get(beClaimKey(id))
		if v == nil {
			continue
		}
		cs := v.(*claimState)
		rows, threads := 0, 0
		if cs.board != nil {
			rows = cs.board.Size()
		}
		if cs.boardTop != nil {
			threads = cs.boardTop.Size()
		}
		if sent > 0 {
			out.WriteString(";")
		}
		out.WriteString(strconv.FormatUint(id, 10))
		out.WriteString(":" + strconv.Itoa(rows))
		out.WriteString(":" + strconv.Itoa(threads))
		sent++
	}
	return out.String()
}
func BoardHiddenCount(courtSlug string, claimID uint64) int {
	cs := mustClaim(mustCourt(courtSlug), claimID)
	if cs.boardTop == nil {
		return 0
	}
	n := 0
	cs.boardTop.Iterate("", "", func(_ string, v any) bool {
		if boardMark(v.(*boardRow)) != "." {
			n++
		}
		return false
	})
	return n
}
func BoardOpen(courtSlug string, claimID uint64) bool {
	return boardOpen(mustClaim(mustCourt(courtSlug), claimID))
}
func CommentsWrittenBy(courtSlug string, claimID uint64, who address) int64 {
	return boardWroteBy(mustClaim(mustCourt(courtSlug), claimID), who)
}
func BoardNewest(courtSlug string, claimID uint64, offset, count int) string {
	cs := mustClaim(mustCourt(courtSlug), claimID)
	if cs.boardTop == nil || count <= 0 {
		return ""
	}
	if count > maxBoardRepliesShown*8 {
		count = maxBoardRepliesShown * 8
	}
	var b strings.Builder
	cs.boardTop.ReverseIterateByOffset(offset, count, func(_ string, v any) bool {
		r := v.(*boardRow)
		b.WriteString(strconv.FormatUint(r.id, 10) + "|" + r.author.String() + "|" +
			strconv.Itoa(boardReplyCount(cs, r.id)) + "|")
		if m := boardMark(r); m != "." {
			b.WriteString(m + "|" + strconv.FormatInt(r.at, 10) + "|\n")
			return false
		}
		b.WriteString(".|" + strconv.FormatInt(r.at, 10) + "|" + boardTextFor(r) + "\n")
		return false
	})
	return b.String()
}
func boardReplyCount(cs *claimState, parent uint64) int {
	if cs.boardKids == nil {
		return 0
	}
	pre := beClaimKey(parent)
	n := 0
	cs.boardKids.Iterate(pre, "", func(k string, _ any) bool {
		if !strings.HasPrefix(k, pre) || !boardKeyMine(pre, k) {
			return true
		}
		n++
		return false
	})
	return n
}
func boardKeyMine(pre, k string) bool { return len(k) == len(pre)+8 }
func BoardReplies(courtSlug string, claimID uint64, parent uint64) string {
	cs := mustClaim(mustCourt(courtSlug), claimID)
	if cs.boardKids == nil {
		return ""
	}
	pre := beClaimKey(parent)
	var b strings.Builder
	n := 0
	cs.boardKids.Iterate(pre, "", func(k string, v any) bool {
		if !strings.HasPrefix(k, pre) || !boardKeyMine(pre, k) {
			return true
		}
		r := v.(*boardRow)
		b.WriteString(strconv.FormatUint(r.id, 10) + "|" + r.author.String() + "|")
		if m := boardMark(r); m != "." {
			b.WriteString(m + "|" + strconv.FormatInt(r.at, 10) + "|\n")
		} else {
			b.WriteString(".|" + strconv.FormatInt(r.at, 10) + "|" + boardTextFor(r) + "\n")
		}
		n++
		return n >= maxBoardRepliesShown
	})
	return b.String()
}
func BoardPartyRows(courtSlug string, claimID uint64) string {
	cs := mustClaim(mustCourt(courtSlug), claimID)
	if cs.boardTop == nil {
		return ""
	}
	var b strings.Builder
	for _, r := range boardPartyRows(cs) {
		role := "answerer"
		if r.author == cs.author {
			role = "author"
		}
		b.WriteString(strconv.FormatUint(r.id, 10) + "|" + r.author.String() + "|" + role + "|")
		if m := boardMark(r); m != "." {
			b.WriteString(m + "|" + strconv.FormatInt(r.at, 10) + "|\n")
			continue
		}
		b.WriteString(".|" + strconv.FormatInt(r.at, 10) + "|" + boardTextFor(r) + "\n")
	}
	return b.String()
}
func boardTextFor(r *boardRow) string {
	if boardMark(r) != "." {
		return ""
	}
	return escapeWireText(r.text)
}
func escapeWireText(s string) string {
	if !strings.ContainsAny(s, "\\\n\r") {
		return s
	}
	var b strings.Builder
	for i := 0; i < len(s); i++ {
		switch s[i] {
		case '\\':
			b.WriteString("\\\\")
		case '\n':
			b.WriteString("\\n")
		case '\r':
			b.WriteString("\\r")
		default:
			b.WriteByte(s[i])
		}
	}
	return b.String()
}
func renderBoardPage(slug string, claimID uint64) string {
	return renderBoardIn(slug, claimID, false)
}
func renderBoardTop(slug string, claimID uint64) string {
	return renderBoardIn(slug, claimID, true)
}
func renderBoardHidden(slug string, claimID uint64) string {
	c := mustCourt(slug)
	cs := mustClaim(c, claimID)
	base := "/r/kourt/kourtv2:" + slug + "/" + strconv.FormatUint(claimID, 10)
	var b strings.Builder
	b.WriteString("# Hidden comments on claim " + strconv.FormatUint(claimID, 10) + "\n\n")
	b.WriteString("[← the comments](" + base + "/board)\n\n")
	if cs.boardTop == nil {
		b.WriteString("_Nothing has been hidden here._\n")
		return b.String()
	}
	n := 0
	cs.boardTop.Iterate("", "", func(_ string, v any) bool {
		r := v.(*boardRow)
		m := boardMark(r)
		if m == "." {
			return false
		}
		n++
		b.WriteString("---\n\n**" + sanitize.InlineText(r.author.String()) + "**")
		b.WriteString(" · block " + strconv.FormatInt(r.at, 10))
		if m != "x" {
			b.WriteString(" · [#" + strconv.FormatUint(r.id, 10) + "](" + base +
				"/board/" + strconv.FormatUint(r.id, 10) + ")")
		} else {
			b.WriteString(" · #" + strconv.FormatUint(r.id, 10))
		}
		b.WriteString("\n\n")
		switch {
		case r.purged:
			b.WriteString("> _Removed on legal grounds. The text is gone from the record; " +
				"the row remains._\n\n")
		case r.global:
			b.WriteString("> _Withheld pending a legal determination._\n\n")
		case r.hiddenByMod:
			b.WriteString("> _Removed from the listing by this court's moderators._\n\n")
			b.WriteString(boardTextVisible(r) + "\n\n")
		default:
			b.WriteString("> _Withdrawn from the listing by its author._\n\n")
			b.WriteString(boardTextVisible(r) + "\n\n")
		}
		return false
	})
	if n == 0 {
		b.WriteString("_Nothing has been hidden here._\n")
	}
	return b.String()
}
func boardPostLink(slug string, claimID, parentRow uint64) string {
	return "/r/kourt/kourtv2$help&func=PostComment" +
		"&courtSlug=" + slug +
		"&claimID=" + strconv.FormatUint(claimID, 10) +
		"&parentRow=" + strconv.FormatUint(parentRow, 10)
}
func renderBoardIn(slug string, claimID uint64, ranked bool) string {
	c := mustCourt(slug)
	cs := mustClaim(c, claimID)
	var b strings.Builder
	b.WriteString("# Comments on claim " + strconv.FormatUint(claimID, 10) + "\n\n")
	base := "/r/kourt/kourtv2:" + slug + "/" + strconv.FormatUint(claimID, 10)
	b.WriteString("[← the claim](" + base + ")")
	if ranked {
		b.WriteString(" · **Top** · [Newest](" + base + "/board)")
	} else {
		b.WriteString(" · [Top](" + base + "/board/top) · **Newest**")
	}
	b.WriteString("\n\n")
	b.WriteString("[Write a comment](" + boardPostLink(slug, claimID, 0) + ") · " +
		"[Where you stand](/r/kourt/kourtv2:" + slug + "/me) · " +
		helpLink + "\n\n")
	if !boardOpen(cs) {
		b.WriteString("> This claim is settled. Its board is closed to new comments;\n" +
			"> what is here stays.\n\n")
	}
	if TextRedacted(c.id, claimID) {
		b.WriteString("> **The claim itself is withheld or removed on legal grounds.**\n" +
			"> These comments are a separate record and are not covered by that act.\n\n")
	}
	if at, until := claimBoardFrozenAt(c, claimID); until != 0 {
		when := "block " + strconv.FormatInt(until, 10)
		if at != 0 {
			when = strconv.FormatInt(at, 10) + " (" + when + ")"
		}
		b.WriteString("> **Comments are paused on this claim by this court's moderators**\n" +
			"> until " + when + ". The claim itself is\n" +
			"> unaffected: answers, stakes and the verdict continue as normal.\n\n")
	}
	if cs.boardTop == nil || cs.boardTop.Size() == 0 {
		b.WriteString("_No comments yet._\n")
		return b.String()
	}
	seen := map[uint64]bool{}
	if parties := boardPartyRows(cs); len(parties) > 0 {
		b.WriteString("## The parties\n\n")
		for _, r := range parties {
			seen[r.id] = true
			if boardMark(r) != "." {
				continue
			}
			b.WriteString(renderBoardOne(slug, claimID, cs, r, true))
		}
		if ranked {
			b.WriteString("\n## Ranked\n\n")
		} else {
			b.WriteString("\n## Newest\n\n")
		}
	}
	shown := 0
	if ranked {
		if cs.boardScore != nil {
			cs.boardScore.IterateByOffset(0, maxBoardRepliesShown*3, func(_ string, v any) bool {
				r := v.(*boardRow)
				if seen[r.id] {
					return false
				}
				b.WriteString(renderBoardOne(slug, claimID, cs, r, true))
				shown++
				return false
			})
		}
		if shown == 0 {
			b.WriteString("_Nothing else upvoted yet — [Newest](" + base +
				"/board) is the fuller view._\n")
		}
		writeHiddenLink(&b, slug, claimID, base)
		return b.String()
	}
	cs.boardTop.ReverseIterateByOffset(0, maxBoardRepliesShown*3, func(_ string, v any) bool {
		r := v.(*boardRow)
		if seen[r.id] || boardMark(r) != "." {
			return false
		}
		b.WriteString(renderBoardOne(slug, claimID, cs, r, true))
		shown++
		return false
	})
	if rest := cs.boardTop.Size() - shown - len(seen); rest > 0 {
		b.WriteString("\n_" + strconv.Itoa(rest) + " older comments._\n")
	}
	writeHiddenLink(&b, slug, claimID, base)
	return b.String()
}
func writeHiddenLink(b *strings.Builder, slug string, claimID uint64, base string) {
	if k := BoardHiddenCount(slug, claimID); k > 0 {
		b.WriteString("\n[" + strconv.Itoa(k) + " hidden comment" + plural2(k) +
			"](" + base + "/board/hidden)\n")
	}
}
func boardPartyRows(cs *claimState) []*boardRow {
	want := []address{cs.author}
	if cs.frozenAt != 0 && cs.answerer != "" && cs.answerer != cs.author {
		want = append(want, cs.answerer)
	}
	var out []*boardRow
	for _, who := range want {
		var newest *boardRow
		cs.boardTop.ReverseIterate("", "", func(_ string, v any) bool {
			r := v.(*boardRow)
			if r.author == who {
				newest = r
				return true
			}
			return false
		})
		if newest != nil {
			out = append(out, newest)
		}
	}
	return out
}
func renderBoardRow(slug string, claimID uint64, rowArg string) string {
	id, err := strconv.ParseUint(rowArg, 10, 64)
	if err != nil {
		return "## Not found\nA comment id must be a number."
	}
	c := mustCourt(slug)
	cs := mustClaim(c, claimID)
	if cs.board == nil || cs.board.Get(beClaimKey(id)) == nil {
		return "## Not found\nNo comment by that id on this claim."
	}
	r := mustBoardRow(cs, id)
	var b strings.Builder
	b.WriteString("# " + claimTitleFor(c, cs) + "\n\n")
	base := "/r/kourt/kourtv2:" + slug + "/" + strconv.FormatUint(claimID, 10)
	b.WriteString("Comment " + strconv.FormatUint(id, 10) + " on this claim in " +
		"[" + courtNameFor(c) + "](/r/kourt/kourtv2:" + slug + ")\n\n")
	b.WriteString("[← the claim](" + base + ") · [all " +
		strconv.Itoa(cs.board.Size()) + " comments](" + base + "/board)\n\n")
	b.WriteString(renderBoardOne(slug, claimID, cs, r, false))
	return b.String()
}
func renderBoardOne(slug string, claimID uint64, cs *claimState, r *boardRow, listing bool) string {
	var b strings.Builder
	b.WriteString("---\n\n**" + sanitize.InlineText(r.author.String()) + "**")
	for _, badge := range boardBadges(cs, r.author) {
		b.WriteString(" · " + badge)
	}
	b.WriteString(" · [#" + strconv.FormatUint(r.id, 10) + "](/r/kourt/kourtv2:" + slug + "/" +
		strconv.FormatUint(claimID, 10) + "/board/" + strconv.FormatUint(r.id, 10) + ")" +
		" · block " + strconv.FormatInt(r.at, 10) + "\n\n")
	if (r.hiddenByAuthor || r.hiddenByMod) && !r.global && !r.purged && listing {
		if r.hiddenByMod {
			b.WriteString("> _Removed from this listing by this court's moderators. " +
				"It still reads at its own link._\n\n")
		} else {
			b.WriteString("> _Withdrawn from this listing. It still reads at its own link._\n\n")
		}
		return b.String()
	}
	b.WriteString(boardTextVisible(r) + "\n\n")
	if r.parent == 0 {
		writeBoardReplies(&b, slug, claimID, cs, r.id)
		if boardOpen(cs) {
			b.WriteString("[Reply](" + boardPostLink(slug, claimID, r.id) + ")\n\n")
		}
	}
	return b.String()
}
func writeBoardReplies(b *strings.Builder, slug string, claimID uint64, cs *claimState, parent uint64) {
	pre := beClaimKey(parent)
	n, total := 0, boardReplyCount(cs, parent)
	if total == 0 {
		return
	}
	cs.boardKids.Iterate(pre, "", func(k string, v any) bool {
		if !strings.HasPrefix(k, pre) || !boardKeyMine(pre, k) {
			return true
		}
		r := v.(*boardRow)
		if boardMark(r) != "." {
			return false
		}
		b.WriteString("> **" + sanitize.InlineText(r.author.String()) + "**")
		for _, badge := range boardBadges(cs, r.author) {
			b.WriteString(" · " + badge)
		}
		b.WriteString(" · [#" + strconv.FormatUint(r.id, 10) + "](/r/kourt/kourtv2:" + slug +
			"/" + strconv.FormatUint(claimID, 10) + "/board/" + strconv.FormatUint(r.id, 10) + ")\n>\n")
		{
			for _, line := range strings.Split(boardTextVisible(r), "\n") {
				b.WriteString("> " + line + "\n")
			}
			b.WriteString("\n")
		}
		n++
		return n >= maxBoardRepliesShown
	})
	if total > n {
		b.WriteString("_" + strconv.Itoa(total-n) + " more repl" + plural(total-n) +
			" at [#" + strconv.FormatUint(parent, 10) + "](/r/kourt/kourtv2:" + slug + "/" +
			strconv.FormatUint(claimID, 10) + "/board/" + strconv.FormatUint(parent, 10) + ")._\n\n")
	}
}
func plural(n int) string {
	if n == 1 {
		return "y"
	}
	return "ies"
}
func boardBadges(cs *claimState, who address) []string {
	var out []string
	if who == cs.author {
		out = append(out, "author")
	}
	if cs.frozenAt != 0 && who == cs.answerer {
		out = append(out, "answerer")
	}
	for _, side := range []int{sideYES, sideNO} {
		if v := cs.stakers.Get(posKey(who, side)); v != nil {
			if p := v.(*stakePos); p.stake > 0 {
				name := "YES"
				if side == sideNO {
					name = "NO"
				}
				out = append(out, name+" "+strconv.FormatInt(p.stake, 10))
			}
		}
	}
	return out
}
func boardTextVisible(r *boardRow) string {
	if r.purged {
		return "> _Removed. The text is gone from the record; the row remains._"
	}
	if r.global {
		return "> _Withheld pending a legal determination._"
	}
	if r.text == "" {
		return "_(empty)_"
	}
	return sanitize.Block(r.text)
}
func boardScoreKey(score int64, rowID uint64) string {
	return beInv(score) + beInv(int64(rowID))
}
func scoreIndexPut(cs *claimState, r *boardRow) {
	if r.parent != 0 || boardMark(r) != "." {
		return
	}
	r.scoreKey = boardScoreKey(r.score, r.id)
	ensureScoreIdx(cs).Set(r.scoreKey, r)
}
func scoreIndexDrop(cs *claimState, r *boardRow) {
	if cs.boardScore == nil || r.scoreKey == "" {
		return
	}
	cs.boardScore.Remove(r.scoreKey)
	r.scoreKey = ""
}
func UpvoteComment(cur realm, courtSlug string, claimID uint64, rowID uint64) int64 {
	if !cur.IsCurrent() {
		panic(errStaleRealm)
	}
	who := cur.Previous().Address()
	c := mustCourt(courtSlug)
	if courtIsPurged(c) {
		panic("kourtv2: this court is purged; it takes no new content")
	}
	cs := mustClaim(c, claimID)
	if !boardOpen(cs) {
		panic("kourtv2: this claim is settled; its board is closed")
	}
	mustBoardWritable(c, cs, who)
	r := mustBoardRow(cs, rowID)
	if r.parent != 0 {
		panic("kourtv2: only top-level comments are ranked; a reply is read under its parent")
	}
	if r.author == who {
		panic("kourtv2: you cannot upvote your own comment")
	}
	if r.purged {
		panic("kourtv2: that comment was destroyed on legal grounds; it takes no votes")
	}
	vk := beClaimKey(rowID) + string(who)
	if cs.boardVoted != nil && cs.boardVoted.Has(vk) {
		panic("kourtv2: you have already upvoted that comment")
	}
	var w int64
	if sr := lookupStanding(c, who); sr != nil {
		w = sr.score
	}
	if w <= 0 {
		panic("kourtv2: an upvote is weighted by standing, and you have none here yet")
	}
	mustSpendPost(c, who)
	ensureBoard(cs)
	ensureVoted(cs).Set(vk, true)
	scoreIndexDrop(cs, r)
	r.score = satAdd(r.score, w)
	scoreIndexPut(cs, r)
	return r.score
}
func HasUpvoted(courtSlug string, claimID uint64, rowID uint64, who address) bool {
	cs := mustClaim(mustCourt(courtSlug), claimID)
	if cs.boardVoted == nil {
		return false
	}
	return cs.boardVoted.Has(beClaimKey(rowID) + string(who))
}
func CommentScore(courtSlug string, claimID uint64, rowID uint64) int64 {
	return mustBoardRow(mustClaim(mustCourt(courtSlug), claimID), rowID).score
}
func BoardTop(courtSlug string, claimID uint64, offset, count int) string {
	cs := mustClaim(mustCourt(courtSlug), claimID)
	if cs.boardScore == nil || count <= 0 {
		return ""
	}
	if count > maxBoardRepliesShown*8 {
		count = maxBoardRepliesShown * 8
	}
	var b strings.Builder
	cs.boardScore.IterateByOffset(offset, count, func(_ string, v any) bool {
		r := v.(*boardRow)
		b.WriteString(strconv.FormatUint(r.id, 10) + "|" + r.author.String() + "|" +
			strconv.FormatInt(r.score, 10) + "|.|" + strconv.FormatInt(r.at, 10) +
			"|" + boardTextFor(r) + "\n")
		return false
	})
	return b.String()
}
func writeBoardLink(b *strings.Builder, c *Court, cs *claimState, claimID uint64) {
	n := 0
	if cs.board != nil {
		n = cs.board.Size()
	}
	link := "/r/kourt/kourtv2:" + c.id + "/" + strconv.FormatUint(claimID, 10) + "/board"
	switch {
	case n == 0 && !boardOpen(cs):
		return
	case n == 0:
		b.WriteString("## Comments\n\n[Write the first one](" +
			boardPostLink(c.id, claimID, 0) + ")\n\n")
		return
	}
	b.WriteString("## Comments\n\n")
	b.WriteString("[Write a comment](" + boardPostLink(c.id, claimID, 0) + ")\n\n")
	shown, drawn := 0, 0
	if cs.boardTop != nil {
		cs.boardTop.ReverseIterate("", "", func(_ string, v any) bool {
			r := v.(*boardRow)
			if boardMark(r) != "." {
				return false
			}
			b.WriteString(renderBoardOne(c.id, claimID, cs, r, true))
			shown += 1 + boardReplyCount(cs, r.id)
			drawn++
			return drawn >= claimBoardPreview
		})
	}
	all := ""
	if shown < n {
		all = "all "
	}
	b.WriteString("\n[" + all + strconv.Itoa(n) + " comment" + plural2(n) + "](" + link +
		") · [Top](" + link + "/top)\n\n")
	writeHiddenLink(b, c.id, claimID, "/r/kourt/kourtv2:"+c.id+"/"+strconv.FormatUint(claimID, 10))
}
const claimBoardPreview = 3
func plural2(n int) string {
	if n == 1 {
		return ""
	}
	return "s"
}
