package kourt
import (
	"chain"
	"strconv"
	grc20votes "gno.land/p/g13khfsjnnq6g3lz2e997jejc9kvlz2x5yx08dr0/grc20votes/v0"
	bptree "gno.land/p/nt/bptree/v0"
)
const (
	nominationWindow = int64(17_280)
	maxBallotLines = 64
	electionBondBps = int64(50)
)
func mustElectionInvariants() {
	if electionBondBps <= 0 {
		panic("kourtv2: the election bond must be positive")
	}
	if electionBondBps >= quorumSupplyBps {
		panic("kourtv2: the election bond must stay below the quorum floor — else affording the ballot is harder than winning the vote (incumbency lock by price)")
	}
	if nominationWindow < 17_280 {
		panic("kourtv2: the nomination window must be at least a day")
	}
}
func init() { mustElectionInvariants() }
type modCandidate struct {
	id      uint64
	members []address
	m       int
	by      address
	at      int64
}
type ballotLine struct {
	candID uint64
	weight int64
	nomAt  int64
	bond   int64
	poster address
}
type election struct {
	seq         uint64
	epoch       uint32
	openedAt    int64
	nominateEnd int64
	voteEnd     int64
	nominateEndTime int64
	voteEndTime     int64
	floor       int64
	bond        int64
	lines       *bptree.BPTree
	retainW     int64
	nominators  *bptree.BPTree
	voters      *bptree.BPTree
	approvals   *bptree.BPTree
	turnout     int64
	resolved    bool
}
func electionFloor(c *Court, at uint32) int64 {
	f := mulDiv128(votableAt(c, at), quorumSupplyBps, grc20votes.Bps)
	if f < 1 {
		f = 1
	}
	return f
}
func votableAt(c *Court, at uint32) int64 {
	v := c.coin.PastTotal(at) - c.coin.PastVotes(c.escrow, at)
	if v < 0 {
		v = 0
	}
	return v
}
func electionBond(c *Court, at uint32) int64 {
	b := mulDiv128(votableAt(c, at), electionBondBps, grc20votes.Bps)
	if b < carrotClampMinCC {
		b = carrotClampMinCC
	}
	if f := electionFloor(c, at); b > f {
		b = f
	}
	return b
}
func RegisterModCandidate(cur realm, courtSlug string, m int, members ...address) uint64 {
	if !cur.IsCurrent() {
		panic(errStaleRealm)
	}
	who := cur.Previous().Address()
	c := mustCourt(courtSlug)
	cm := ensureMod(c)
	canon := canonicalMembers(members)
	if len(canon) == 0 {
		panic("kourtv2: a candidate set may not be empty")
	}
	if m < 1 || m > len(canon) {
		panic("kourtv2: the m-of-n threshold must be in 1..n")
	}
	if cm.candidates == nil {
		cm.candidates = bptree.NewBPTree32()
	}
	cm.candSeq++
	id := cm.candSeq
	cm.candidates.Set(beClaimKey(id), &modCandidate{
		id: id, members: canon, m: m, by: who, at: heightNow(),
	})
	return id
}
func canonicalMembers(in []address) []address {
	if len(in) > maxModSetSize {
		panic("kourtv2: a moderator set is at most 32 members")
	}
	out := []address{}
	for _, a := range in {
		if a == "" {
			panic("kourtv2: a moderator address may not be zero")
		}
		if !a.IsValid() {
			panic("kourtv2: not a valid address for a moderator set")
		}
		dup := false
		for _, b := range out {
			if b == a {
				dup = true
				break
			}
		}
		if dup {
			continue
		}
		pos := len(out)
		out = append(out, a)
		for pos > 0 && out[pos-1].String() > a.String() {
			out[pos] = out[pos-1]
			pos--
		}
		out[pos] = a
	}
	return out
}
func (cm *courtMod) mustCandidate(id uint64) *modCandidate {
	if cm.candidates == nil {
		panic("kourtv2: no such candidate")
	}
	v := cm.candidates.Get(beClaimKey(id))
	if v == nil {
		panic("kourtv2: no such candidate")
	}
	return v.(*modCandidate)
}
func electionCooldownOpen(cm *courtMod) bool {
	passed, known := pastDeadline(cm.electionCooldownUntilTime, 0)
	return (known && !passed) || (!known && heightNow() < cm.electionCooldownUntil)
}
func nominationClosed(e *election) bool {
	passed, known := pastDeadline(e.nominateEndTime, 0)
	return (known && passed) || (!known && heightNow() >= e.nominateEnd)
}
func votingClosed(e *election) bool {
	passed, known := pastDeadline(e.voteEndTime, 0)
	return (known && passed) || (!known && heightNow() >= e.voteEnd)
}
func OpenElection(cur realm, courtSlug string, candidateID uint64) uint64 {
	if !cur.IsCurrent() {
		panic(errStaleRealm)
	}
	who := cur.Previous().Address()
	c := mustCourt(courtSlug)
	cm := ensureMod(c)
	if cm.election != nil && !cm.election.resolved {
		panic("kourtv2: an election is already open for this court")
	}
	now := heightNow()
	if electionCooldownOpen(cm) {
		panic("kourtv2: this court is in its post-election cooldown")
	}
	cand := cm.mustCandidate(candidateID)
	at := c.coin.Epoch() - 1
	cm.electionSeq++
	e := &election{
		seq:         cm.electionSeq,
		epoch:       at,
		openedAt:    now,
		nominateEnd: now + nominationWindow,
		voteEnd:     now + nominationWindow + c.params.votingBlocks,
		nominateEndTime: nowTime() + blocksToSecs(nominationWindow),
		voteEndTime:     nowTime() + blocksToSecs(nominationWindow+c.params.votingBlocks),
		floor:       electionFloor(c, at),
		bond:        electionBond(c, at),
		lines:       bptree.NewBPTree32(),
		nominators:  bptree.NewBPTree32(),
		voters:      bptree.NewBPTree32(),
		approvals:   bptree.NewBPTree32(),
	}
	cm.election = e
	addNomination(c, cm, e, cand, who)
	return e.seq
}
func NominateCandidate(cur realm, courtSlug string, candidateID uint64) {
	if !cur.IsCurrent() {
		panic(errStaleRealm)
	}
	who := cur.Previous().Address()
	c := mustCourt(courtSlug)
	cm := ensureMod(c)
	e := cm.mustOpenElection()
	if nominationClosed(e) {
		panic("kourtv2: the nomination window has closed")
	}
	cand := cm.mustCandidate(candidateID)
	addNomination(c, cm, e, cand, who)
}
func addNomination(c *Court, cm *courtMod, e *election, cand *modCandidate, who address) {
	if e.lines.Size() >= maxBallotLines {
		panic("kourtv2: this ballot is full; open the next election instead")
	}
	if e.nominators.Has(who.String()) {
		panic("kourtv2: one nomination per address per election")
	}
	if e.lines.Has(beClaimKey(cand.id)) {
		panic("kourtv2: that candidate is already on the ballot")
	}
	mustSpendable(c, who, e.bond)
	c.coin.Transfer(who, c.escrow, e.bond)
	e.nominators.Set(who.String(), true)
	e.lines.Set(beClaimKey(cand.id), &ballotLine{
		candID: cand.id, nomAt: heightNow(), bond: e.bond, poster: who,
	})
}
func (cm *courtMod) mustOpenElection() *election {
	if cm.election == nil || cm.election.resolved {
		panic("kourtv2: no election is open")
	}
	return cm.election
}
func ApproveCandidate(cur realm, courtSlug string, candidateID uint64) {
	if !cur.IsCurrent() {
		panic(errStaleRealm)
	}
	approve(cur.Previous().Address(), courtSlug, candidateID, false)
}
func ApproveRetain(cur realm, courtSlug string) {
	if !cur.IsCurrent() {
		panic(errStaleRealm)
	}
	approve(cur.Previous().Address(), courtSlug, 0, true)
}
func approve(who address, courtSlug string, candidateID uint64, retain bool) {
	c := mustCourt(courtSlug)
	cm := ensureMod(c)
	e := cm.mustOpenElection()
	if !nominationClosed(e) {
		panic("kourtv2: voting opens when the nomination window closes")
	}
	if votingClosed(e) {
		panic("kourtv2: voting has closed")
	}
	var w int64
	if prior := e.voters.Get(who.String()); prior != nil {
		w = prior.(int64)
	} else {
		var snapshot int64
		w, snapshot = votingWeight(c, who, e.epoch)
		if snapshot <= 0 {
			panic("kourtv2: no voting weight at the pinned epoch")
		}
		if w <= 0 {
			panic("kourtv2: you no longer hold the coin you would vote with")
		}
	}
	key := beClaimKey(candidateID) + who.String()
	if retain {
		key = "retain" + who.String()
	}
	if e.approvals.Has(key) {
		panic("kourtv2: already approved that line")
	}
	if !retain {
		v := e.lines.Get(beClaimKey(candidateID))
		if v == nil {
			panic("kourtv2: that candidate is not on the ballot")
		}
		line := v.(*ballotLine)
		line.weight += w
	} else {
		e.retainW += w
	}
	e.approvals.Set(key, true)
	if !e.voters.Has(who.String()) {
		e.voters.Set(who.String(), w)
		e.turnout += w
		lockVote(c, who, voteLockElection, int64(e.seq), 0, w)
	}
}
func ResolveElection(cur realm, courtSlug string) {
	if !cur.IsCurrent() {
		panic(errStaleRealm)
	}
	c := mustCourt(courtSlug)
	cm := ensureMod(c)
	e := cm.mustOpenElection()
	now := heightNow()
	if !votingClosed(e) {
		panic("kourtv2: the voting window has not closed")
	}
	e.resolved = true
	maxW := int64(0)
	e.lines.Iterate("", "", func(_ string, v any) bool {
		if l, ok := v.(*ballotLine); ok && l.weight > maxW {
			maxW = l.weight
		}
		return false
	})
	install := maxW > 0 && e.turnout >= e.floor && maxW-e.retainW >= e.floor
	var winner *ballotLine
	if install {
		e.lines.Iterate("", "", func(_ string, v any) bool {
			l, ok := v.(*ballotLine)
			if !ok || l.weight < maxW-e.floor || l.weight-e.retainW < e.floor {
				return false
			}
			if winner == nil || l.nomAt < winner.nomAt ||
				(l.nomAt == winner.nomAt && l.candID < winner.candID) {
				winner = l
			}
			return false
		})
	}
	e.lines.Iterate("", "", func(_ string, v any) bool {
		l, ok := v.(*ballotLine)
		if !ok || l.bond <= 0 {
			return false
		}
		if winner != nil && l.candID == winner.candID {
			c.coin.Transfer(c.escrow, l.poster, l.bond)
		} else {
			half := l.bond / 2
			if half > 0 {
				c.coin.Transfer(c.escrow, l.poster, half)
			}
			if burn := l.bond - half; burn > 0 {
				c.coin.Burn(c.escrow, burn)
			}
		}
		l.bond = 0
		return false
	})
	if winner != nil {
		cand := cm.mustCandidate(winner.candID)
		installModSet(c, cm, cand, now, true)
		chain.Emit("ModSetInstalled",
			"court", c.id, "by", "election",
			"candidate", strconv.FormatUint(cand.id, 10),
			"height", strconv.FormatInt(now, 10),
		)
		return
	}
	cm.electionCooldownUntil = now + decideWindowBlocks
	cm.electionCooldownUntilTime = nowTime() + blocksToSecs(decideWindowBlocks)
}
func installModSet(c *Court, cm *courtMod, cand *modCandidate, at int64, byElection bool) {
	fresh := bptree.NewBPTree32()
	for _, a := range cand.members {
		fresh.Set(a.String(), true)
	}
	cm.members = fresh
	cm.n = len(cand.members)
	cm.m = cand.m
	clearPendingOnMembershipChange(&cm.pending)
	cm.setActHeight = at
	cm.installedByMeta = !byElection
	if currentSetID(cm) != cm.suspendedSetID || cm.m > cm.suspendedM {
		cm.suspended = false
		cm.suspendedSetID = ""
		cm.suspendedM = 0
	}
	if byElection {
		cm.lastElectionAt = at
		cm.creatorUnseated = true
	}
}
func mustModRead(courtSlug string) *courtMod {
	c := mustCourt(courtSlug)
	if c.mod == nil {
		panic("kourtv2: this court has no moderation state yet")
	}
	return c.mod
}
func ElectionOpen(courtSlug string) bool {
	c := mustCourt(courtSlug)
	return c.mod != nil && c.mod.election != nil && !c.mod.election.resolved
}
func ElectionWindows(courtSlug string) (int64, int64) {
	e := mustModRead(courtSlug).mustOpenElection()
	return e.nominateEnd, e.voteEnd
}
func ElectionFloorOf(courtSlug string) int64 {
	return mustModRead(courtSlug).mustOpenElection().floor
}
func ElectionBondOf(courtSlug string) int64 {
	return mustModRead(courtSlug).mustOpenElection().bond
}
func ElectionTally(courtSlug string, candidateID uint64) (candW, retainW, turnout int64) {
	e := mustModRead(courtSlug).mustOpenElection()
	if v := e.lines.Get(beClaimKey(candidateID)); v != nil {
		candW = v.(*ballotLine).weight
	}
	return candW, e.retainW, e.turnout
}
func CandidateMembers(courtSlug string, candidateID uint64) []address {
	cand := mustModRead(courtSlug).mustCandidate(candidateID)
	out := make([]address, len(cand.members))
	copy(out, cand.members)
	return out
}
func CandidateThreshold(courtSlug string, candidateID uint64) int {
	return mustModRead(courtSlug).mustCandidate(candidateID).m
}
func ElectionCooldownUntil(courtSlug string) int64 {
	c := mustCourt(courtSlug)
	if c.mod == nil {
		return 0
	}
	return c.mod.electionCooldownUntil
}
