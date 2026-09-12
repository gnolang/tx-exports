package kourt2
import "strconv"
func boardActCode(verb string, rowID uint64, categoryCode string) string {
	code := verb + "#" + strconv.FormatUint(rowID, 10)
	if categoryCode != "" {
		code += ":" + categoryCode
	}
	return code
}
const (
	boardCodeSpam      = "spam"
	boardCodeOffTopic  = "off-topic"
	boardCodeAbuse     = "abuse"
	boardCodeImpersonation = "impersonation"
	boardCodeIllegal   = "illegal-referred"
)
func mustBoardCode(code string) {
	switch code {
	case boardCodeSpam, boardCodeOffTopic, boardCodeAbuse,
		boardCodeImpersonation, boardCodeIllegal:
		return
	}
	panic("kourtv2: a board moderation code is one of: spam, off-topic, abuse, " +
		"impersonation, illegal-referred")
}
func BoardCodes() string {
	return boardCodeSpam + "," + boardCodeOffTopic + "," + boardCodeAbuse + "," +
		boardCodeImpersonation + "," + boardCodeIllegal
}
func GlobalHideRow(cur realm, courtSlug string, claimID, rowID uint64, categoryCode string) {
	if !cur.IsCurrent() {
		panic(errStaleRealm)
	}
	who := cur.Previous().Address()
	if !isGlobalMod(who) {
		panic("kourtv2: only a global DAO member may globally hide a comment")
	}
	checkReason(categoryCode)
	c := mustCourt(courtSlug)
	cs := mustClaim(c, claimID)
	r := mustBoardRow(cs, rowID)
	if r.purged {
		panic("kourtv2: that comment was already destroyed; there is nothing to withhold")
	}
	now := heightNow()
	if !r.global && r.globalClearedAt != 0 &&
		reSetWindowOpen(r.globalClearedAtTime, r.globalClearedAt, now) {
		d := ensureGlobalDAO()
		fire, _ := approveAction(d.pending,
			"boardreset:"+c.id+":"+strconv.FormatUint(claimID, 10)+":"+strconv.FormatUint(rowID, 10),
			who, categoryCode, d.purgeM)
		if !fire {
			return
		}
	}
	r.global = true
	scoreIndexDrop(cs, r)
	ensureClaimMod(c, ensureMod(c), claimID).
		appendLog(who, boardActCode("board-global-hide", rowID, categoryCode), "")
	emitGlobalAct(c.id, claimID, "board-global-hide", who)
}
func GlobalClearRow(cur realm, courtSlug string, claimID, rowID uint64) {
	if !cur.IsCurrent() {
		panic(errStaleRealm)
	}
	who := cur.Previous().Address()
	if !isGlobalMod(who) {
		panic("kourtv2: only a global DAO member may clear a global comment hide")
	}
	c := mustCourt(courtSlug)
	cs := mustClaim(c, claimID)
	r := mustBoardRow(cs, rowID)
	if !r.global {
		panic("kourtv2: that comment is not globally hidden")
	}
	r.global = false
	r.globalClearedAt = heightNow()
	r.globalClearedAtTime = nowTime()
	scoreIndexPut(cs, r)
	ensureClaimMod(c, ensureMod(c), claimID).
		appendLog(who, boardActCode("board-global-clear", rowID, ""), "")
	emitGlobalAct(c.id, claimID, "board-global-clear", who)
}
func PurgeBoardRow(cur realm, courtSlug string, claimID, rowID uint64, categoryCode string) {
	if !cur.IsCurrent() {
		panic(errStaleRealm)
	}
	who := cur.Previous().Address()
	d := ensureGlobalDAO()
	if !d.members.Has(who.String()) {
		panic("kourtv2: only a global DAO member may purge")
	}
	mustCategoryCode(categoryCode)
	c := mustCourt(courtSlug)
	cs := mustClaim(c, claimID)
	r := mustBoardRow(cs, rowID)
	if r.purged {
		return
	}
	fire, votedCode := approveAction(d.pending,
		"boardpurge:"+c.id+":"+strconv.FormatUint(claimID, 10)+":"+strconv.FormatUint(rowID, 10),
		who, categoryCode, d.purgeM)
	if !fire {
		return
	}
	r.purged = true
	r.text = ""
	scoreIndexDrop(cs, r)
	ensureClaimMod(c, ensureMod(c), claimID).
		appendLog(who, boardActCode("board-purge", rowID, votedCode), "")
	emitPurge(c.id, claimID, "board-row", who)
}
func BoardRowState(courtSlug string, claimID uint64, rowID uint64) string {
	return boardMark(mustBoardRow(mustClaim(mustCourt(courtSlug), claimID), rowID))
}
const maxBatchRows = 64
func PurgeBoardRange(cur realm, courtSlug string, claimID, fromRowID uint64, categoryCode string) uint64 {
	if !cur.IsCurrent() {
		panic(errStaleRealm)
	}
	who := cur.Previous().Address()
	d := ensureGlobalDAO()
	if !d.members.Has(who.String()) {
		panic("kourtv2: only a global DAO member may purge")
	}
	mustCategoryCode(categoryCode)
	c := mustCourt(courtSlug)
	cs := mustClaim(c, claimID)
	cm := ensureMod(c)
	clm := lookupClaimMod(cm, claimID)
	if clm == nil || !clm.boardPurgeAll {
		fire, _ := approveAction(d.pending,
			"boardpurgeall:"+c.id+":"+strconv.FormatUint(claimID, 10),
			who, categoryCode, d.purgeM)
		if !fire {
			return fromRowID
		}
		clm = ensureClaimMod(c, cm, claimID)
		clm.boardPurgeAll = true
		clm.appendLog(who, boardActCode("board-purge-all", 0, categoryCode), "")
		emitPurge(c.id, claimID, "board-all", who)
	}
	if cs.board == nil {
		return 0
	}
	n, next := 0, uint64(0)
	cs.board.Iterate(beClaimKey(fromRowID), "", func(_ string, v any) bool {
		r := v.(*boardRow)
		if r.purged {
			return false
		}
		if n >= maxBatchRows {
			next = r.id
			return true
		}
		r.purged = true
		r.text = ""
		scoreIndexDrop(cs, r)
		n++
		return false
	})
	return next
}
func BoardPurgeOrdered(courtSlug string, claimID uint64) bool {
	c := mustCourt(courtSlug)
	if c.mod == nil {
		return false
	}
	clm := lookupClaimMod(c.mod, claimID)
	return clm != nil && clm.boardPurgeAll
}
