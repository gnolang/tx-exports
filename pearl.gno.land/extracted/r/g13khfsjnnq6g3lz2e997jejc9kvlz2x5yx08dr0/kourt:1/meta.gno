package kourt
import (
	"chain"
	"strconv"
	"strings"
	unsafe "chain/runtime/unsafe"
	"math/overflow"
	bptree "gno.land/p/nt/bptree/v0"
)
const metaRealmPath = "gno.land/r/g13khfsjnnq6g3lz2e997jejc9kvlz2x5yx08dr0/kourt"
const (
	metaPrefix   = "mod:"
	metaCourtNm  = "Meta"
	metaExecuted = "MetaExecuted"
)
const (
	verbUnhide    = "unhide"
	verbClear     = "clear"
	verbHide      = "hide"
	verbSuspend   = "suspend"
	verbUnsuspend = "unsuspend"
	verbSetmods   = "setmods"
	verbNewset = "newset"
)
func verbIsAggressive(v string) bool {
	return v == verbHide || v == verbSuspend || v == verbUnsuspend || v == verbSetmods
}
type modParse struct {
	valid     bool
	verb      string
	court     string
	target    uint64
	hasTarget bool
	poisoned  bool
}
type metaState struct {
	parses   *bptree.BPTree
	bindings *bptree.BPTree
	latches  *bptree.BPTree
	executed *bptree.BPTree
}
var meta = &metaState{
	parses:   bptree.NewBPTree32(),
	bindings: bptree.NewBPTree32(),
	latches:  bptree.NewBPTree32(),
	executed: bptree.NewBPTree32(),
}
func init() {
	startCourt(unsafe.OriginCaller(), chain.PackageAddress(metaRealmPath), metaSlug, metaCourtNm, 0)
}
func parseModTitle(title string) modParse {
	p := modParse{}
	if !strings.HasPrefix(title, metaPrefix) {
		return p
	}
	rest := title[len(metaPrefix):]
	slash := strings.Index(rest, ":")
	if slash < 0 {
		return p
	}
	verb := rest[:slash]
	arg := rest[slash+1:]
	switch verb {
	case verbUnhide, verbClear, verbHide, verbSetmods, verbNewset:
		cut := strings.Index(arg, "/")
		if cut <= 0 || cut == len(arg)-1 {
			return p
		}
		id, err := strconv.ParseUint(arg[cut+1:], 10, 64)
		if err != nil || id == 0 {
			return p
		}
		p.court, p.target, p.hasTarget = arg[:cut], id, true
	case verbSuspend, verbUnsuspend:
		if arg == "" || strings.Contains(arg, "/") {
			return p
		}
		p.court = arg
	default:
		return p
	}
	for i := 0; i < len(p.court); i++ {
		ch := p.court[i]
		if !((ch >= 'a' && ch <= 'z') || (ch >= '0' && ch <= '9') || ch == '-') {
			return modParse{}
		}
	}
	p.verb, p.valid = verb, true
	return p
}
func latchKey(p modParse) string {
	switch p.verb {
	case verbSetmods:
		return "set:" + p.court
	case verbNewset:
		return "fold:" + p.court
	case verbSuspend, verbUnsuspend:
		return "sus:" + p.court
	default:
		return "item:" + p.court + ":" + strconv.FormatUint(p.target, 10)
	}
}
func onClaimOpened(c *Court, cs *claimState) {
	if c.id != metaSlug {
		return
	}
	p := parseModTitle(cs.title)
	meta.parses.Set(beClaimKey(cs.id), &p)
	cs.noAccuracy = p.valid && p.verb == verbNewset
	if p.valid {
		pendingEnter(c, cs)
	}
}
func onTitleEdited(c *Court, cs *claimState) {
	if c.id != metaSlug {
		return
	}
	p := parseModTitle(cs.title)
	if prev := meta.parses.Get(beClaimKey(cs.id)); prev != nil && prev.(*modParse).poisoned {
		p.poisoned = true
	}
	meta.parses.Set(beClaimKey(cs.id), &p)
	cs.noAccuracy = p.valid && p.verb == verbNewset
	if p.valid || cs.seeded {
		pendingEnter(c, cs)
	} else {
		pendingExit(c, cs)
	}
}
func onClaimAnswered(c *Court, cs *claimState) {
	if c.id != metaSlug {
		return
	}
	v := meta.parses.Get(beClaimKey(cs.id))
	if v == nil {
		return
	}
	p := v.(*modParse)
	if !p.valid || p.poisoned {
		return
	}
	k := latchKey(*p)
	if held := meta.latches.Get(k); held != nil {
		if held.(uint64) != cs.id {
			panic("kourtv2: another appeal already holds this target's review slot")
		}
	}
	meta.latches.Set(k, cs.id)
	bind := *p
	meta.bindings.Set(beClaimKey(cs.id), &bind)
}
func releaseMetaLatchIfMeta(c *Court, cs *claimState) {
	if c.id != metaSlug {
		return
	}
	releaseMetaLatch(cs)
}
func releaseMetaLatch(cs *claimState) {
	v := meta.bindings.Get(beClaimKey(cs.id))
	if v == nil {
		return
	}
	k := latchKey(*v.(*modParse))
	if held := meta.latches.Get(k); held != nil && held.(uint64) == cs.id {
		meta.latches.Remove(k)
	}
}
func poisonMetaParse(claimID uint64) {
	if v := meta.parses.Get(beClaimKey(claimID)); v != nil {
		v.(*modParse).poisoned = true
	}
}
func metaVerdictExpired(cs *claimState, votingBlocks int64) bool {
	passed, known := pastDeadline(cs.verdictAtTime, blocksToSecs(votingBlocks)+1)
	return (known && passed) || (!known && heightNow() > cs.verdictAt+votingBlocks)
}
func ExecuteMetaVerdict(cur realm, metaClaimID uint64) {
	if !cur.IsCurrent() {
		panic(errStaleRealm)
	}
	mc := mustCourt(metaSlug)
	cs := mustClaim(mc, metaClaimID)
	bv := meta.bindings.Get(beClaimKey(metaClaimID))
	if bv == nil {
		panic("kourtv2: this claim carries no binding appeal")
	}
	p := *bv.(*modParse)
	if !Exists(p.court) {
		panic("kourtv2: the target court does not exist")
	}
	tc := mustCourt(p.court)
	if tc.createdAt >= cs.openedAt {
		panic("kourtv2: the target court does not predate this appeal")
	}
	var target *claimState
	if p.hasTarget && p.verb != verbSetmods && p.verb != verbNewset {
		target = mustClaim(tc, p.target)
		if target.openedAt >= cs.openedAt {
			panic("kourtv2: the target claim does not predate this appeal")
		}
	}
	if p.verb == verbSetmods {
		if cand := ensureMod(tc).mustCandidate(p.target); cand.at >= cs.openedAt {
			panic("kourtv2: the candidate set does not predate this appeal")
		}
	}
	if p.verb == verbNewset {
		if prop := ensureMod(tc).mustFolderProposal(p.target); prop.at >= cs.openedAt {
			panic("kourtv2: the folder proposal does not predate this appeal")
		}
	}
	if cs.verdictAt == 0 || cs.provClose {
		panic("kourtv2: no final verdict")
	}
	if int(cs.provisional) != sideYES {
		panic("kourtv2: the verdict was not YES")
	}
	if verbIsAggressive(p.verb) {
		if cs.route != "vote" || cs.decidedRounds == 0 {
			panic("kourtv2: this verb needs a decided contested vote, not silence")
		}
		if p.verb != verbHide && !cs.credEligible {
			panic("kourtv2: a manufactured contest cannot seize authority — this verb needs weight voted against it")
		}
	}
	if meta.executed.Has(beClaimKey(metaClaimID)) {
		panic("kourtv2: already executed")
	}
	if metaVerdictExpired(cs, mc.params.votingBlocks) {
		panic("kourtv2: this verdict has expired; re-appeal")
	}
	cm := ensureMod(tc)
	switch p.verb {
	case verbSetmods:
		if cm.setActHeight > cs.verdictAt {
			panic("kourtv2: the moderator set changed after this verdict; re-appeal")
		}
		if cm.suspended && cm.suspendActByGlobal > cs.openedAt {
			panic("kourtv2: the global DAO changed this court's suspension under this appeal; re-appeal")
		}
	case verbSuspend, verbUnsuspend:
		if cm.lastElectionAt > cs.openedAt || cm.setActHeight > cs.verdictAt {
			panic("kourtv2: the moderator set changed under this appeal; re-appeal")
		}
		if cm.suspendActByGlobal > cs.openedAt &&
			cm.suspended == (p.verb == verbUnsuspend) {
			panic("kourtv2: the global DAO changed this court's suspension under this appeal; re-appeal")
		}
	case verbUnhide:
		if cm.lastElectionAt > cs.openedAt {
			panic("kourtv2: the moderator set changed under this appeal; re-appeal")
		}
	}
	meta.executed.Set(beClaimKey(metaClaimID), true)
	applyMetaVerb(mc, tc, cm, p, cs, target)
	releaseMetaLatch(cs)
	chain.Emit(metaExecuted,
		"appeal", strconv.FormatUint(metaClaimID, 10),
		"verb", p.verb, "court", p.court,
		"target", strconv.FormatUint(p.target, 10),
	)
}
func applyMetaVerb(mc, tc *Court, cm *courtMod, p modParse, cs, target *claimState) {
	by := cs.answerer
	switch p.verb {
	case verbUnhide:
		clm := lookupClaimMod(cm, p.target)
		if clm == nil || !clm.court {
			return
		}
		clearCourtBitByMeta(tc, p.target, by)
	case verbClear:
		clearMetaBit(tc, p.target, by)
	case verbHide:
		setMetaBit(tc, p.target, by)
	case verbSuspend:
		suspendSet(tc, by)
	case verbUnsuspend:
		unsuspendSet(tc, by)
	case verbNewset:
		prop := cm.mustFolderProposal(p.target)
		if folderNameTaken(cm, prop.name) {
			panic("kourtv2: a folder by that name already exists")
		}
		if prop.parent != 0 {
			if pf := cm.mustFolder(prop.parent); pf.retired || pf.purged {
				panic("kourtv2: the parent heading is no longer in the tree")
			}
		}
		fid := newFolderCore(cm, prop.name, prop.desc, prop.parent)
		emitModAct(tc.id, 0, "folder-create", by)
		chain.Emit("FolderCreated",
			"court", tc.id, "by", "meta",
			"folder", strconv.FormatUint(fid, 10),
			"proposal", strconv.FormatUint(p.target, 10),
			"height", eventHeight(),
		)
	case verbSetmods:
		cand := cm.mustCandidate(p.target)
		installModSet(tc, cm, cand, heightNow(), false)
		chain.Emit("ModSetInstalled",
			"court", tc.id, "by", "meta",
			"candidate", strconv.FormatUint(cand.id, 10),
			"height", eventHeight(),
		)
	}
}
func AppealParse(claimID uint64) (verb, court string, target uint64, valid bool) {
	v := meta.parses.Get(beClaimKey(claimID))
	if v == nil {
		return "", "", 0, false
	}
	p := v.(*modParse)
	return p.verb, p.court, p.target, p.valid
}
func AppealExecuted(claimID uint64) bool { return meta.executed.Has(beClaimKey(claimID)) }
func AppealLatchHolder(verb, court string, target uint64) uint64 {
	p := modParse{verb: verb, court: court, target: target}
	if v := meta.latches.Get(latchKey(p)); v != nil {
		return v.(uint64)
	}
	return 0
}
var franchise = bptree.NewBPTree32()
func accrueFranchise(c *Court, who address, spent int64) {
	if c.id == metaSlug || spent <= 0 {
		return
	}
	k := who.String()
	prev := int64(0)
	if v := franchise.Get(k); v != nil {
		prev = v.(int64)
	}
	sum, ok := overflow.Add64(prev, spent)
	if !ok {
		return
	}
	franchise.Set(k, sum)
}
func ClaimMetaFranchise(cur realm) int64 {
	if !cur.IsCurrent() {
		panic(errStaleRealm)
	}
	who := cur.Previous().Address()
	k := who.String()
	v := franchise.Get(k)
	if v == nil {
		return 0
	}
	owed := v.(int64)
	if owed <= 0 {
		return 0
	}
	mc := mustCourt(metaSlug)
	touch(mc)
	delta, used := mc.crv.Minted(mc.minted, owed)
	if delta <= 0 {
		return 0
	}
	mc.minted += delta
	recordPrice(mc)
	mc.coin.Mint(who, delta)
	if used >= owed {
		franchise.Remove(k)
	} else {
		franchise.Set(k, owed-used)
	}
	chain.Emit("FranchiseClaimed",
		"who", who.String(),
		"burned", strconv.FormatInt(used, 10),
		"minted", strconv.FormatInt(delta, 10),
	)
	return delta
}
func FranchiseOf(who address) int64 {
	if v := franchise.Get(who.String()); v != nil {
		return v.(int64)
	}
	return 0
}
