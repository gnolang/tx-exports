package kourt2
import (
	"chain"
	"strconv"
	bptree "gno.land/p/nt/bptree/v0"
)
const (
	maxReasonLen = 200
	maxModSetSize = 32
	reSetWindowBlocks = int64(241_920)
	modActEvent    = "ModAct"
	globalActEvent = "GlobalAct"
	purgeEvent     = "Purge"
)
type daoState struct {
	admin   address
	members *bptree.BPTree
	n       int
	purgeM  int
	pending *bptree.BPTree
}
var globalDAO *daoState
const (
	daoBootstrapN = 1
	daoBootstrapM = 1
)
func ensureGlobalDAO() *daoState {
	if globalDAO != nil {
		return globalDAO
	}
	if directoryAdmin == "" {
		panic("kourtv2: no court exists yet; the global DAO has no admin")
	}
	d := &daoState{
		admin:   directoryAdmin,
		members: bptree.NewBPTree32(),
		n:       daoBootstrapN,
		purgeM:  daoBootstrapM,
		pending: bptree.NewBPTree32(),
	}
	d.members.Set(directoryAdmin.String(), true)
	globalDAO = d
	return d
}
func isGlobalMod(who address) bool {
	d := ensureGlobalDAO()
	return d.members.Has(who.String())
}
func AddGlobalMod(cur realm, who address) {
	if !cur.IsCurrent() {
		panic(errStaleRealm)
	}
	d := ensureGlobalDAO()
	if cur.Previous().Address() != d.admin {
		panic("kourtv2: only the global DAO admin manages membership")
	}
	seatGlobalMember(d, who)
}
func seatGlobalMember(d *daoState, who address) {
	if d.members.Has(who.String()) {
		return
	}
	d.members.Set(who.String(), true)
	d.n++
	clearPendingOnMembershipChange(&d.pending)
}
func RemoveGlobalMod(cur realm, who address) {
	if !cur.IsCurrent() {
		panic(errStaleRealm)
	}
	d := ensureGlobalDAO()
	if cur.Previous().Address() != d.admin {
		panic("kourtv2: only the global DAO admin manages membership")
	}
	if who == d.admin {
		panic("kourtv2: the admin cannot be removed; transfer admin first")
	}
	if d.members.Has(who.String()) {
		d.members.Remove(who.String())
		d.n--
		if d.purgeM > d.n {
			d.purgeM = d.n
		}
		clearPendingOnMembershipChange(&d.pending)
	}
}
func SetPurgeThreshold(cur realm, m int) {
	if !cur.IsCurrent() {
		panic(errStaleRealm)
	}
	d := ensureGlobalDAO()
	if cur.Previous().Address() != d.admin {
		panic("kourtv2: only the global DAO admin sets the purge threshold")
	}
	if m < 1 || m > d.n {
		panic("kourtv2: the purge threshold must be in 1..n")
	}
	if m != d.purgeM {
		clearPendingOnMembershipChange(&d.pending)
	}
	d.purgeM = m
}
func TransferGlobalAdmin(cur realm, to address) {
	if !cur.IsCurrent() {
		panic(errStaleRealm)
	}
	d := ensureGlobalDAO()
	if cur.Previous().Address() != d.admin {
		panic("kourtv2: only the global DAO admin transfers the seat")
	}
	seatGlobalMember(d, to)
	d.admin = to
}
type courtMod struct {
	members *bptree.BPTree
	n       int
	m       int
	suspended   bool
	suspendedAt int64
	suspendActByGlobal int64
	suspendedSetID     string
	suspendedM         int
	setActHeight       int64
	lastElectionAt     int64
	installedByMeta bool
	courtPurged    bool
	courtTombstone string
	claims  *bptree.BPTree
	pending *bptree.BPTree
	boardSanctionEpoch int64
	log    []modAct
	logSeq uint64
	folders   *bptree.BPTree
	folderSeq uint64
	folderProps   *bptree.BPTree
	folderPropSeq uint64
	candidates            *bptree.BPTree
	candSeq               uint64
	election              *election
	electionSeq           uint64
	electionCooldownUntil     int64
	electionCooldownUntilTime int64
	creatorUnseated       bool
}
type claimMod struct {
	court  bool
	meta   bool
	global bool
	purged    bool
	tombstone string
	boardFrozenUntil     int64
	boardFrozenUntilTime int64
	boardFrozenEpoch     int64
	boardFrozenGapUntil     int64
	boardFrozenGapUntilTime int64
	boardPurgeAll bool
	globalClearedAt     int64
	globalClearedAtTime int64
	executedAt      int64
	executedAtTime  int64
	logSeq uint64
	log    []modAct
}
type modAct struct {
	rowID  uint64
	actor  address
	code   string
	reason string
	height int64
	purged bool
}
func reSetWindowOpen(clearedAtTime, clearedAt, now int64) bool {
	passed, known := pastDeadline(clearedAtTime, blocksToSecs(reSetWindowBlocks))
	return (known && !passed) || (!known && now < clearedAt+reSetWindowBlocks)
}
const pendingTTLBlocks = decideWindowBlocks
type approval struct {
	approvers    *bptree.BPTree
	reason       string
	openedAt     int64
	openedAtTime int64
}
func approvalStale(a *approval) bool {
	passed, known := pastDeadline(a.openedAtTime, blocksToSecs(pendingTTLBlocks))
	return (known && passed) || (!known && heightNow() >= a.openedAt+pendingTTLBlocks)
}
func ensureMod(c *Court) *courtMod {
	if c.mod != nil {
		return c.mod
	}
	cm := &courtMod{
		members: bptree.NewBPTree32(),
		n:       1,
		m:       1,
		claims:  bptree.NewBPTree32(),
		pending: bptree.NewBPTree32(),
		folders: bptree.NewBPTree32(),
	}
	cm.members.Set(c.admin.String(), true)
	c.mod = cm
	return cm
}
func AppointMods(cur realm, courtSlug string, m int, mods ...address) {
	if !cur.IsCurrent() {
		panic(errStaleRealm)
	}
	c := mustCourt(courtSlug)
	if cur.Previous().Address() != c.admin {
		panic("kourtv2: only the court creator appoints moderators (until an election)")
	}
	if c.mod != nil && c.mod.creatorUnseated {
		panic("kourtv2: an election has installed a set; the creator's appointment power is spent")
	}
	if c.mod != nil && c.mod.suspended {
		panic("kourtv2: this moderator set is suspended; only an election or a meta verdict may reinstate it")
	}
	canon := canonicalMembers(mods)
	if len(canon) == 0 {
		panic("kourtv2: a moderator set may not be empty")
	}
	if m < 1 || m > len(canon) {
		panic("kourtv2: the m-of-n threshold must be in 1..n")
	}
	cm := ensureMod(c)
	fresh := bptree.NewBPTree32()
	n := 0
	for _, a := range canon {
		fresh.Set(a.String(), true)
		n++
	}
	cm.members = fresh
	cm.n = n
	cm.m = m
	cm.setActHeight = heightNow()
	cm.installedByMeta = false
	clearPendingOnMembershipChange(&cm.pending)
}
func requireMod(cm *courtMod, who address) {
	if !cm.members.Has(who.String()) {
		panic("kourtv2: not a moderator of this court")
	}
}
func clearPendingOnMembershipChange(pending **bptree.BPTree) {
	*pending = bptree.NewBPTree32()
}
func requireActiveMod(cm *courtMod, who address) {
	requireMod(cm, who)
	if cm.suspended {
		panic("kourtv2: this moderator set is suspended; only clearing its own bits is allowed")
	}
}
func isActiveMod(cm *courtMod, who address) bool {
	return !cm.suspended && cm.members.Has(who.String())
}
func requireEdgeRemover(c *Court, author, who address) {
	if author == who {
		return
	}
	cm := ensureMod(c)
	if !cm.members.Has(who.String()) {
		panic("kourtv2: only the edge's author or a court moderator may remove it")
	}
	requireActiveMod(cm, who)
}
func mustCategoryCode(code string) {
	if len(code) == 0 || runeLen(code) > maxReasonLen {
		panic("kourtv2: purge needs a statutory category code")
	}
}
func checkReason(reason string) {
	if runeLen(reason) > maxReasonLen {
		panic("kourtv2: a moderation reason is at most 200 characters")
	}
}
func ensureClaimMod(c *Court, cm *courtMod, claimID uint64) *claimMod {
	_ = mustClaim(c, claimID)
	k := beClaimKey(claimID)
	if v := cm.claims.Get(k); v != nil {
		return v.(*claimMod)
	}
	clm := &claimMod{}
	cm.claims.Set(k, clm)
	return clm
}
func lookupClaimMod(cm *courtMod, claimID uint64) *claimMod {
	if v := cm.claims.Get(beClaimKey(claimID)); v != nil {
		return v.(*claimMod)
	}
	return nil
}
func (clm *claimMod) appendLog(actor address, code, reason string) uint64 {
	clm.logSeq++
	clm.log = append(clm.log, modAct{
		rowID:  clm.logSeq,
		actor:  actor,
		code:   code,
		reason: reason,
		height: heightNow(),
	})
	return clm.logSeq
}
func (cm *courtMod) appendCourtLog(actor address, code, reason string) uint64 {
	cm.logSeq++
	cm.log = append(cm.log, modAct{
		rowID:  cm.logSeq,
		actor:  actor,
		code:   code,
		reason: reason,
		height: heightNow(),
	})
	return cm.logSeq
}
func approveAction(pending *bptree.BPTree, key string, who address, reason string, m int) (bool, string) {
	now := heightNow()
	var a *approval
	if v := pending.Get(key); v != nil {
		a = v.(*approval)
		if approvalStale(a) {
			a = nil
		}
	}
	if a == nil {
		a = &approval{approvers: bptree.NewBPTree32(), reason: reason,
			openedAt: now, openedAtTime: nowTime()}
	}
	if a.approvers.Has(who.String()) {
		return false, ""
	}
	a.approvers.Set(who.String(), true)
	if a.approvers.Size() >= m {
		pending.Remove(key)
		return true, a.reason
	}
	pending.Set(key, a)
	return false, ""
}
func pendingOpenedAt(pending *bptree.BPTree, key string) int64 {
	v := pending.Get(key)
	if v == nil {
		return 0
	}
	a := v.(*approval)
	if approvalStale(a) {
		return 0
	}
	return a.openedAt
}
func HideItem(cur realm, courtSlug string, claimID uint64, reason string) {
	if !cur.IsCurrent() {
		panic(errStaleRealm)
	}
	who := cur.Previous().Address()
	c := mustCourt(courtSlug)
	cm := ensureMod(c)
	requireActiveMod(cm, who)
	checkReason(reason)
	_ = mustClaim(c, claimID)
	if clm := lookupClaimMod(cm, claimID); clm != nil && clm.executedAt != 0 {
		if passed, known := pastDeadline(clm.executedAtTime, blocksToSecs(c.params.votingBlocks)); (known && !passed) ||
			(!known && heightNow() < clm.executedAt+c.params.votingBlocks) {
			panic("kourtv2: a review verdict just cleared this; the set may not re-hide yet")
		}
	}
	fire, r := approveAction(cm.pending, "hide:"+strconv.FormatUint(claimID, 10), who, reason, cm.m)
	if !fire {
		return
	}
	clm := ensureClaimMod(c, cm, claimID)
	clm.court = true
	clm.appendLog(who, "hide", r)
	emitModAct(c.id, claimID, "hide", who)
}
func UnhideItem(cur realm, courtSlug string, claimID uint64, reason string) {
	if !cur.IsCurrent() {
		panic(errStaleRealm)
	}
	who := cur.Previous().Address()
	c := mustCourt(courtSlug)
	cm := ensureMod(c)
	requireMod(cm, who)
	checkReason(reason)
	clm := lookupClaimMod(cm, claimID)
	if clm == nil || !clm.court {
		panic("kourtv2: this court is not hiding that claim")
	}
	fire, r := approveAction(cm.pending, "unhide:"+strconv.FormatUint(claimID, 10), who, reason, cm.m)
	if !fire {
		return
	}
	clm.court = false
	clm.appendLog(who, "unhide", r)
	emitModAct(c.id, claimID, "unhide", who)
}
func GlobalHide(cur realm, courtSlug string, claimID uint64, categoryCode string) {
	if !cur.IsCurrent() {
		panic(errStaleRealm)
	}
	who := cur.Previous().Address()
	if !isGlobalMod(who) {
		panic("kourtv2: only a global DAO member may global-hide")
	}
	checkReason(categoryCode)
	c := mustCourt(courtSlug)
	cm := ensureMod(c)
	_ = mustClaim(c, claimID)
	now := heightNow()
	if prev := lookupClaimMod(cm, claimID); prev != nil && !prev.global &&
		prev.globalClearedAt != 0 && reSetWindowOpen(prev.globalClearedAtTime, prev.globalClearedAt, now) {
		d := ensureGlobalDAO()
		fire, _ := approveAction(d.pending, "reset:"+c.id+":"+strconv.FormatUint(claimID, 10), who, categoryCode, d.purgeM)
		if !fire {
			return
		}
	}
	clm := ensureClaimMod(c, cm, claimID)
	clm.global = true
	clm.appendLog(who, "global-hide:"+categoryCode, "")
	emitGlobalAct(c.id, claimID, "global-hide", who)
}
func GlobalClear(cur realm, courtSlug string, claimID uint64) {
	if !cur.IsCurrent() {
		panic(errStaleRealm)
	}
	who := cur.Previous().Address()
	if !isGlobalMod(who) {
		panic("kourtv2: only a global DAO member may clear a global hide")
	}
	c := mustCourt(courtSlug)
	cm := ensureMod(c)
	clm := lookupClaimMod(cm, claimID)
	if clm == nil || !clm.global {
		panic("kourtv2: no global hide on that claim")
	}
	clm.global = false
	clm.globalClearedAt = heightNow()
	clm.globalClearedAtTime = nowTime()
	clm.appendLog(who, "global-clear", "")
	emitGlobalAct(c.id, claimID, "global-clear", who)
}
func ClearAnyBit(cur realm, courtSlug string, claimID uint64) {
	if !cur.IsCurrent() {
		panic(errStaleRealm)
	}
	who := cur.Previous().Address()
	if !isGlobalMod(who) {
		panic("kourtv2: only a global DAO member may clear bits (recovery)")
	}
	c := mustCourt(courtSlug)
	cm := ensureMod(c)
	clm := lookupClaimMod(cm, claimID)
	if clm == nil {
		panic("kourtv2: nothing to clear on that claim")
	}
	clm.court = false
	clm.meta = false
	clm.appendLog(who, "clear-any", "")
	emitGlobalAct(c.id, claimID, "clear-any", who)
}
func ClearCourtSuspension(cur realm, courtSlug string) {
	if !cur.IsCurrent() {
		panic(errStaleRealm)
	}
	who := cur.Previous().Address()
	if !isGlobalMod(who) {
		panic("kourtv2: only a global DAO member may clear a suspension (recovery)")
	}
	c := mustCourt(courtSlug)
	cm := ensureMod(c)
	if !cm.suspended {
		panic("kourtv2: that court's set is not suspended")
	}
	cm.suspended = false
	cm.suspendActByGlobal = heightNow()
	emitGlobalAct(c.id, 0, "clear-suspension", who)
}
func PurgeClaim(cur realm, courtSlug string, claimID uint64, categoryCode string) {
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
	_ = mustClaim(c, claimID)
	fire, code := approveAction(d.pending, "purge:"+c.id+":"+strconv.FormatUint(claimID, 10), who, categoryCode, d.purgeM)
	if !fire {
		return
	}
	clm := ensureClaimMod(c, cm, claimID)
	clm.purged = true
	clm.tombstone = code
	if c.id == metaSlug {
		poisonMetaParse(claimID)
	}
	clm.appendLog(who, "purge:"+code, "")
	emitPurge(c.id, claimID, code, who)
}
func GlobalSuspendSet(cur realm, courtSlug string) {
	if !cur.IsCurrent() {
		panic(errStaleRealm)
	}
	who := cur.Previous().Address()
	d := ensureGlobalDAO()
	if !d.members.Has(who.String()) {
		panic("kourtv2: only a global DAO member may suspend a moderator set")
	}
	c := mustCourt(courtSlug)
	cm := ensureMod(c)
	if cm.suspended {
		panic("kourtv2: that set is already suspended")
	}
	fire, _ := approveAction(d.pending, "gsuspend:"+c.id, who, "", d.purgeM)
	if !fire {
		return
	}
	suspendSet(c, who)
	cm.suspendActByGlobal = heightNow()
	emitGlobalAct(c.id, 0, "global-suspend-set", who)
}
func ResetModSet(cur realm, courtSlug string) {
	if !cur.IsCurrent() {
		panic(errStaleRealm)
	}
	who := cur.Previous().Address()
	d := ensureGlobalDAO()
	if !d.members.Has(who.String()) {
		panic("kourtv2: only a global DAO member may reset a moderator set")
	}
	c := mustCourt(courtSlug)
	cm := ensureMod(c)
	fire, _ := approveAction(d.pending, "resetmods:"+c.id, who, "", d.purgeM)
	if !fire {
		return
	}
	cm.members = bptree.NewBPTree32()
	cm.n = 0
	cm.m = 1
	clearPendingOnMembershipChange(&cm.pending)
	cm.suspended = false
	cm.boardSanctionEpoch++
	cm.setActHeight = heightNow()
	emitGlobalAct(c.id, 0, "reset-mod-set", who)
}
func PurgeCourt(cur realm, courtSlug string, categoryCode string) {
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
	fire, code := approveAction(d.pending, "purgecourt:"+c.id, who, categoryCode, d.purgeM)
	if !fire {
		return
	}
	cm.courtPurged = true
	cm.courtTombstone = code
	emitPurge(c.id, 0, code, who)
}
func courtIsPurged(c *Court) bool {
	return c.mod != nil && c.mod.courtPurged
}
func CourtPurged(courtSlug string) bool {
	return courtIsPurged(mustCourt(courtSlug))
}
func setMetaBit(c *Court, claimID uint64, by address) {
	cm := ensureMod(c)
	clm := ensureClaimMod(c, cm, claimID)
	clm.meta = true
	clm.executedAt = heightNow()
	clm.executedAtTime = nowTime()
	clm.appendLog(by, "meta-hide", "")
	emitModAct(c.id, claimID, "meta-hide", by)
}
func clearMetaBit(c *Court, claimID uint64, by address) {
	cm := ensureMod(c)
	clm := lookupClaimMod(cm, claimID)
	if clm == nil || !clm.meta {
		return
	}
	clm.meta = false
	clm.appendLog(by, "meta-clear", "")
	emitModAct(c.id, claimID, "meta-clear", by)
}
func clearCourtBitByMeta(c *Court, claimID uint64, by address) {
	cm := ensureMod(c)
	clm := lookupClaimMod(cm, claimID)
	if clm == nil || !clm.court {
		return
	}
	clm.court = false
	clm.executedAt = heightNow()
	clm.executedAtTime = nowTime()
	clm.appendLog(by, "meta-unhide", "")
	emitModAct(c.id, claimID, "meta-unhide", by)
}
func suspendSet(c *Court, by address) {
	cm := ensureMod(c)
	cm.suspended = true
	cm.suspendedAt = heightNow()
	cm.suspendedSetID = currentSetID(cm)
	cm.suspendedM = cm.m
	emitModAct(c.id, 0, "suspend", by)
}
func currentSetID(cm *courtMod) string {
	s := ""
	cm.members.Iterate("", "", func(k string, _ any) bool {
		s += k + ","
		return false
	})
	return s
}
func unsuspendSet(c *Court, by address) {
	cm := ensureMod(c)
	cm.suspended = false
	emitModAct(c.id, 0, "unsuspend", by)
}
func HiddenFromListing(courtSlug string, claimID uint64) bool {
	c := mustCourt(courtSlug)
	if c.mod == nil {
		return false
	}
	clm := lookupClaimMod(c.mod, claimID)
	if clm == nil {
		return false
	}
	return clm.court || clm.meta || clm.global
}
func TextRedacted(courtSlug string, claimID uint64) bool {
	c := mustCourt(courtSlug)
	if c.mod == nil {
		return false
	}
	clm := lookupClaimMod(c.mod, claimID)
	if clm == nil {
		return false
	}
	return clm.global || clm.purged
}
func ClaimPurged(courtSlug string, claimID uint64) bool {
	c := mustCourt(courtSlug)
	if c.mod == nil {
		return false
	}
	clm := lookupClaimMod(c.mod, claimID)
	return clm != nil && clm.purged
}
func PurgeModLogRow(cur realm, courtSlug string, claimID, rowID uint64, categoryCode string) {
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
	clm := lookupClaimMod(cm, claimID)
	if clm == nil {
		panic("kourtv2: that claim has no moderation log")
	}
	idx := -1
	for i := range clm.log {
		if clm.log[i].rowID == rowID {
			idx = i
			break
		}
	}
	if idx < 0 {
		panic("kourtv2: no such moderation-log row")
	}
	if clm.log[idx].purged {
		return
	}
	key := "purgerow:" + c.id + ":" + strconv.FormatUint(claimID, 10) + ":" +
		strconv.FormatUint(rowID, 10)
	fire, code := approveAction(d.pending, key, who, categoryCode, d.purgeM)
	if !fire {
		return
	}
	clm.log[idx].purged = true
	clm.log[idx].reason = ""
	clm.appendLog(who, "purgerow:"+code, "")
	emitPurge(c.id, claimID, code, who)
}
func PendingApproval(courtSlug, actionKey string) (approvals int, expiresAt, expiresAtHeight int64) {
	var pending *bptree.BPTree
	if courtSlug == "" {
		if globalDAO == nil {
			return 0, 0, 0
		}
		pending = globalDAO.pending
	} else {
		c := mustCourt(courtSlug)
		if c.mod == nil {
			return 0, 0, 0
		}
		pending = c.mod.pending
	}
	v := pending.Get(actionKey)
	if v == nil {
		return 0, 0, 0
	}
	a := v.(*approval)
	if approvalStale(a) {
		return 0, 0, 0
	}
	return a.approvers.Size(),
		deadlineTime(a.openedAtTime, blocksToSecs(pendingTTLBlocks)),
		a.openedAt + pendingTTLBlocks
}
func CourtSuspended(courtSlug string) bool {
	c := mustCourt(courtSlug)
	return c.mod != nil && c.mod.suspended
}
func IsCourtMod(courtSlug string, who address) bool {
	c := mustCourt(courtSlug)
	if c.mod == nil {
		return who == c.admin
	}
	return c.mod.members.Has(who.String())
}
func ModThreshold(courtSlug string) (m, n int) {
	c := mustCourt(courtSlug)
	if c.mod == nil {
		return 1, 1
	}
	return c.mod.m, c.mod.n
}
func GlobalModCount() int {
	if globalDAO == nil {
		return 0
	}
	return globalDAO.n
}
func ModLogLen(courtSlug string, claimID uint64) int {
	c := mustCourt(courtSlug)
	if c.mod == nil {
		return 0
	}
	clm := lookupClaimMod(c.mod, claimID)
	if clm == nil {
		return 0
	}
	return len(clm.log)
}
func emitModAct(slug string, claimID uint64, code string, actor address) {
	chain.Emit(modActEvent,
		"court", slug,
		"claim", strconv.FormatUint(claimID, 10),
		"act", code,
		"by", actor.String(),
		"height", eventHeight(),
	)
}
func emitGlobalAct(slug string, claimID uint64, code string, actor address) {
	chain.Emit(globalActEvent,
		"court", slug,
		"claim", strconv.FormatUint(claimID, 10),
		"act", code,
		"by", actor.String(),
		"height", eventHeight(),
	)
}
func emitPurge(slug string, claimID uint64, categoryCode string, actor address) {
	chain.Emit(purgeEvent,
		"court", slug,
		"claim", strconv.FormatUint(claimID, 10),
		"code", categoryCode,
		"by", actor.String(),
		"height", eventHeight(),
	)
}
