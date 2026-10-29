package kourt
import "strconv"
const (
	freezeMaxBlocks = int64(17_280) / 2
	freezeGapBlocks = freezeMaxBlocks
)
func mustBoardModInvariants() {
	if freezeMaxBlocks >= 17_280 {
		panic("kourtv2: a board freeze must expire inside the nomination window")
	}
	if freezeGapBlocks < freezeMaxBlocks {
		panic("kourtv2: the gap between freezes must be at least one freeze long, " +
			"or the ceiling is a formality")
	}
}
func init() { mustBoardModInvariants() }
func speechM(cm *courtMod) int {
	m := cm.m
	if m < 2 {
		m = 2
	}
	if m > cm.n {
		m = cm.n
	}
	return m
}
func SpeechThreshold(courtSlug string) int {
	c := mustCourt(courtSlug)
	if c.mod == nil {
		return 0
	}
	return speechM(c.mod)
}
func boardSanctionEpochOf(c *Court) int64 {
	if c.mod == nil {
		return 0
	}
	return c.mod.boardSanctionEpoch
}
func boardFreezeActive(r *standingRow) bool {
	passed, known := pastDeadline(r.frozenUntilTime, 0)
	return (known && !passed) || (!known && heightNow() < r.frozenUntil)
}
func boardFreezeGapOpen(r *standingRow) bool {
	passed, known := pastDeadline(r.frozenGapUntilTime, 0)
	return (known && !passed) || (!known && heightNow() < r.frozenGapUntil)
}
func boardFrozen(c *Court, who address) bool {
	r := lookupStanding(c, who)
	if r == nil || r.frozenUntil == 0 {
		return false
	}
	if r.frozenEpoch != boardSanctionEpochOf(c) {
		return false
	}
	return boardFreezeActive(r)
}
func boardFrozenAt(c *Court, who address) (at, atHeight int64) {
	if !boardFrozen(c, who) {
		return 0, 0
	}
	r := lookupStanding(c, who)
	return r.frozenUntilTime, r.frozenUntil
}
func BoardFrozenUntil(courtSlug string, who address) (at, atHeight int64) {
	return boardFrozenAt(mustCourt(courtSlug), who)
}
func claimFreezeActive(clm *claimMod) bool {
	passed, known := pastDeadline(clm.boardFrozenUntilTime, 0)
	return (known && !passed) || (!known && heightNow() < clm.boardFrozenUntil)
}
func claimFreezeGapOpen(clm *claimMod) bool {
	passed, known := pastDeadline(clm.boardFrozenGapUntilTime, 0)
	return (known && !passed) || (!known && heightNow() < clm.boardFrozenGapUntil)
}
func claimBoardFrozen(c *Court, claimID uint64) bool {
	if c.mod == nil {
		return false
	}
	clm := lookupClaimMod(c.mod, claimID)
	if clm == nil || clm.boardFrozenUntil == 0 {
		return false
	}
	if clm.boardFrozenEpoch != c.mod.boardSanctionEpoch {
		return false
	}
	return claimFreezeActive(clm)
}
func claimBoardFrozenAt(c *Court, claimID uint64) (at, atHeight int64) {
	if !claimBoardFrozen(c, claimID) {
		return 0, 0
	}
	clm := lookupClaimMod(c.mod, claimID)
	return clm.boardFrozenUntilTime, clm.boardFrozenUntil
}
func ClaimBoardFrozenUntil(courtSlug string, claimID uint64) (at, atHeight int64) {
	return claimBoardFrozenAt(mustCourt(courtSlug), claimID)
}
func HideBoardRow(cur realm, courtSlug string, claimID, rowID uint64, code string) {
	if !cur.IsCurrent() {
		panic(errStaleRealm)
	}
	who := cur.Previous().Address()
	c := mustCourt(courtSlug)
	cm := ensureMod(c)
	requireActiveMod(cm, who)
	mustBoardCode(code)
	cs := mustClaim(c, claimID)
	r := mustBoardRow(cs, rowID)
	if r.hiddenByMod {
		panic("kourtv2: that comment is already hidden")
	}
	fire, _ := approveAction(cm.pending,
		"boardhide:"+strconv.FormatUint(claimID, 10)+":"+strconv.FormatUint(rowID, 10),
		who, code, speechM(cm))
	if !fire {
		return
	}
	r.hiddenByMod = true
	scoreIndexDrop(cs, r)
	ensureClaimMod(c, cm, claimID).
		appendLog(who, boardActCode("board-hide", rowID, code), "")
	emitModAct(c.id, claimID, "board-hide", who)
}
func UnhideBoardRow(cur realm, courtSlug string, claimID, rowID uint64) {
	if !cur.IsCurrent() {
		panic(errStaleRealm)
	}
	who := cur.Previous().Address()
	c := mustCourt(courtSlug)
	cm := ensureMod(c)
	requireMod(cm, who)
	cs := mustClaim(c, claimID)
	r := mustBoardRow(cs, rowID)
	if !r.hiddenByMod {
		panic("kourtv2: that comment is not hidden")
	}
	fire, _ := approveAction(cm.pending,
		"boardunhide:"+strconv.FormatUint(claimID, 10)+":"+strconv.FormatUint(rowID, 10),
		who, "", speechM(cm))
	if !fire {
		return
	}
	r.hiddenByMod = false
	scoreIndexPut(cs, r)
	ensureClaimMod(c, cm, claimID).
		appendLog(who, boardActCode("board-unhide", rowID, ""), "")
	emitModAct(c.id, claimID, "board-unhide", who)
}
func SlashStanding(cur realm, courtSlug string, who address, levels int64, code string) {
	if !cur.IsCurrent() {
		panic(errStaleRealm)
	}
	actor := cur.Previous().Address()
	if levels < 1 || levels > 3 {
		panic("kourtv2: a slash is 1, 2 or 3 whole levels")
	}
	c := mustCourt(courtSlug)
	cm := ensureMod(c)
	requireActiveMod(cm, actor)
	mustBoardCode(code)
	if who == "" {
		panic("kourtv2: no such address")
	}
	fire, voted := approveAction(cm.pending,
		"slash:"+who.String()+":"+strconv.FormatInt(levels, 10),
		actor, code, speechM(cm))
	if !fire {
		return
	}
	r := getStanding(c, who)
	target := postLevel(c, who) - levels
	if target < 0 {
		target = 0
	}
	if want := levelFloor(c, target); r.score > want {
		r.score = want
	}
	if target == 0 {
		r.passHeld = false
	}
	cm.appendCourtLog(actor, "slash:"+strconv.FormatInt(levels, 10), voted)
	emitModAct(c.id, 0, "slash", actor)
}
func levelFloor(c *Court, lv int64) int64 {
	if lv <= 0 {
		return 0
	}
	l := ladderFor(c)
	sup, _ := boardSupply(c)
	switch lv {
	case 1:
		return sup * l.t1Bps / 10_000
	case 2:
		return sup * l.t2Bps / 10_000
	}
	return sup * l.t3Bps / 10_000
}
func RestoreStanding(cur realm, courtSlug string, who address) int64 {
	if !cur.IsCurrent() {
		panic(errStaleRealm)
	}
	actor := cur.Previous().Address()
	c := mustCourt(courtSlug)
	cm := ensureMod(c)
	requireMod(cm, actor)
	r := lookupStanding(c, who)
	if r == nil || r.score >= r.highWater {
		panic("kourtv2: that address has nothing to restore")
	}
	fire, _ := approveAction(cm.pending, "restore:"+who.String(), actor, "",
		speechM(cm))
	if !fire {
		return 0
	}
	r.score = r.highWater
	cm.appendCourtLog(actor, "restore", "")
	emitModAct(c.id, 0, "restore", actor)
	return r.score
}
func FreezeBoard(cur realm, courtSlug string, who address, blocks int64, code string) {
	if !cur.IsCurrent() {
		panic(errStaleRealm)
	}
	actor := cur.Previous().Address()
	if blocks < 1 || blocks > freezeMaxBlocks {
		panic("kourtv2: a board freeze is at most freezeMaxBlocks long")
	}
	c := mustCourt(courtSlug)
	cm := ensureMod(c)
	requireActiveMod(cm, actor)
	mustBoardCode(code)
	if who == "" {
		panic("kourtv2: no such address")
	}
	now := heightNow()
	if r := lookupStanding(c, who); r != nil && boardFreezeGapOpen(r) {
		panic("kourtv2: this address was frozen too recently; the ceiling is not a formality")
	}
	fire, voted := approveAction(cm.pending, "freeze:"+who.String(), actor, code,
		speechM(cm))
	if !fire {
		return
	}
	r := getStanding(c, who)
	r.frozenUntil = now + blocks
	r.frozenUntilTime = nowTime() + blocksToSecs(blocks)
	r.frozenEpoch = boardSanctionEpochOf(c)
	r.frozenGapUntil = now + freezeMaxBlocks + freezeGapBlocks
	r.frozenGapUntilTime = nowTime() + blocksToSecs(freezeMaxBlocks+freezeGapBlocks)
	cm.appendCourtLog(actor, "freeze:"+strconv.FormatInt(blocks, 10), voted)
	emitModAct(c.id, 0, "freeze", actor)
}
func UnfreezeBoard(cur realm, courtSlug string, who address) {
	if !cur.IsCurrent() {
		panic(errStaleRealm)
	}
	actor := cur.Previous().Address()
	c := mustCourt(courtSlug)
	cm := ensureMod(c)
	requireMod(cm, actor)
	if !boardFrozen(c, who) {
		panic("kourtv2: that address is not frozen")
	}
	fire, _ := approveAction(cm.pending, "unfreeze:"+who.String(), actor, "",
		speechM(cm))
	if !fire {
		return
	}
	lifted := lookupStanding(c, who)
	lifted.frozenUntil = 0
	lifted.frozenUntilTime = 0
	cm.appendCourtLog(actor, "unfreeze", "")
	emitModAct(c.id, 0, "unfreeze", actor)
}
func FreezeClaimBoard(cur realm, courtSlug string, claimID uint64, blocks int64, code string) {
	if !cur.IsCurrent() {
		panic(errStaleRealm)
	}
	actor := cur.Previous().Address()
	if blocks < 1 || blocks > freezeMaxBlocks {
		panic("kourtv2: a board freeze is at most freezeMaxBlocks long")
	}
	c := mustCourt(courtSlug)
	cm := ensureMod(c)
	requireActiveMod(cm, actor)
	mustBoardCode(code)
	_ = mustClaim(c, claimID)
	now := heightNow()
	if prev := lookupClaimMod(cm, claimID); prev != nil && claimFreezeGapOpen(prev) {
		panic("kourtv2: this board was frozen too recently; the ceiling is not a formality")
	}
	fire, _ := approveAction(cm.pending,
		"freezeboard:"+strconv.FormatUint(claimID, 10), actor, code, speechM(cm))
	if !fire {
		return
	}
	clm := ensureClaimMod(c, cm, claimID)
	clm.boardFrozenUntil = now + blocks
	clm.boardFrozenUntilTime = nowTime() + blocksToSecs(blocks)
	clm.boardFrozenEpoch = cm.boardSanctionEpoch
	clm.boardFrozenGapUntil = now + freezeMaxBlocks + freezeGapBlocks
	clm.boardFrozenGapUntilTime = nowTime() + blocksToSecs(freezeMaxBlocks+freezeGapBlocks)
	clm.appendLog(actor, "freezeboard:"+strconv.FormatInt(blocks, 10)+":"+code, "")
	emitModAct(c.id, claimID, "freezeboard", actor)
}
func ThawClaimBoard(cur realm, courtSlug string, claimID uint64) {
	if !cur.IsCurrent() {
		panic(errStaleRealm)
	}
	actor := cur.Previous().Address()
	c := mustCourt(courtSlug)
	cm := ensureMod(c)
	requireMod(cm, actor)
	if !claimBoardFrozen(c, claimID) {
		panic("kourtv2: that board is not frozen")
	}
	fire, _ := approveAction(cm.pending,
		"thawboard:"+strconv.FormatUint(claimID, 10), actor, "", speechM(cm))
	if !fire {
		return
	}
	thawed := lookupClaimMod(cm, claimID)
	thawed.boardFrozenUntil = 0
	thawed.boardFrozenUntilTime = 0
	ensureClaimMod(c, cm, claimID).appendLog(actor, "thawboard", "")
	emitModAct(c.id, claimID, "thawboard", actor)
}
func GlobalClearBoardBits(cur realm, courtSlug string) int64 {
	if !cur.IsCurrent() {
		panic(errStaleRealm)
	}
	who := cur.Previous().Address()
	if !isGlobalMod(who) {
		panic("kourtv2: only a global DAO member may clear board bits (recovery)")
	}
	c := mustCourt(courtSlug)
	cm := ensureMod(c)
	cm.boardSanctionEpoch++
	cm.appendCourtLog(who, "global-clear-board-bits", "")
	emitGlobalAct(c.id, 0, "clear-board-bits", who)
	return cm.boardSanctionEpoch
}
func GlobalRestoreStanding(cur realm, courtSlug string, who address) int64 {
	if !cur.IsCurrent() {
		panic(errStaleRealm)
	}
	actor := cur.Previous().Address()
	if !isGlobalMod(actor) {
		panic("kourtv2: only a global DAO member may restore standing (recovery)")
	}
	c := mustCourt(courtSlug)
	r := lookupStanding(c, who)
	if r == nil || r.score >= r.highWater {
		panic("kourtv2: that address has nothing to restore")
	}
	r.score = r.highWater
	ensureMod(c).appendCourtLog(actor, "global-restore-standing", "")
	emitGlobalAct(c.id, 0, "restore-standing", actor)
	return r.score
}
func mustBoardWritable(c *Court, cs *claimState, who address) {
	if claimBoardFrozen(c, cs.id) {
		panic("kourtv2: this claim's board is frozen by moderators")
	}
	if boardFrozen(c, who) {
		panic("kourtv2: you are frozen out of this court's boards")
	}
}
func PurgeCourtLogRow(cur realm, courtSlug string, rowID uint64, categoryCode string) {
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
	cm := ensureMod(c)
	idx := -1
	for i := range cm.log {
		if cm.log[i].rowID == rowID {
			idx = i
			break
		}
	}
	if idx < 0 {
		panic("kourtv2: no such court log row")
	}
	if cm.log[idx].purged {
		return
	}
	fire, code := approveAction(d.pending,
		"purgecourtrow:"+c.id+":"+strconv.FormatUint(rowID, 10),
		who, categoryCode, d.purgeM)
	if !fire {
		return
	}
	cm.log[idx].purged = true
	cm.log[idx].reason = ""
	cm.appendCourtLog(who, "purgecourtrow:"+code, "")
	emitPurge(c.id, 0, code, who)
}
func GlobalClearCourtParams(cur realm, courtSlug string) {
	if !cur.IsCurrent() {
		panic(errStaleRealm)
	}
	who := cur.Previous().Address()
	if !isGlobalMod(who) {
		panic("kourtv2: only a global DAO member may clear court parameters (recovery)")
	}
	c := mustCourt(courtSlug)
	if c.ladder == nil && c.creditRates == nil {
		panic("kourtv2: this court has no parameter overrides")
	}
	c.ladder, c.creditRates = nil, nil
	ensureMod(c).appendCourtLog(who, "global-clear-params", "")
	emitGlobalAct(c.id, 0, "clear-court-params", who)
}
