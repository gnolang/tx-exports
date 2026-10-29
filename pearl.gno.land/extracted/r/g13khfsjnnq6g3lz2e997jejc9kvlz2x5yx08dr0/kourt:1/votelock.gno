package kourt
import "gno.land/p/nt/bptree/v0"
const (
	voteLockDispute  = "d"
	voteLockElection = "e"
)
func voteLockKey(who address, kind string, id, sub uint64) string {
	return string(who) + kind + beClaimKey(id) + beClaimKey(sub)
}
func voteLockParts(who address, key string) (kind string, id, sub uint64, ok bool) {
	tail := key[len(string(who)):]
	if len(tail) != 1+8+8 {
		return "", 0, 0, false
	}
	return tail[0:1], beClaimID(tail[1:9]), beClaimID(tail[9:17]), true
}
func voteLockOpen(c *Court, who address, key string) bool {
	kind, id, sub, ok := voteLockParts(who, key)
	if !ok {
		return false
	}
	switch kind {
	case voteLockDispute:
		v := c.claims.Get(beClaimKey(id))
		if v == nil {
			return false
		}
		cs := v.(*claimState)
		return cs.disputeOpen && cs.proposalID == int64(sub)
	case voteLockElection:
		if c.mod == nil || c.mod.election == nil {
			return false
		}
		e := c.mod.election
		return e.seq == id && !e.resolved
	}
	return false
}
func voteLockedOf(c *Court, who address) int64 {
	if c.voteLocks == nil {
		return 0
	}
	var most int64
	pre := string(who)
	c.voteLocks.Iterate(pre, pre+"\xff", func(k string, v any) bool {
		if w := v.(int64); w > most && voteLockOpen(c, who, k) {
			most = w
		}
		return false
	})
	return most
}
func lockVote(c *Court, who address, kind string, id, sub, amount int64) {
	if amount <= 0 {
		return
	}
	if c.voteLocks == nil {
		c.voteLocks = bptree.NewBPTree32()
	}
	pruneVoteLocks(c, who)
	c.voteLocks.Set(voteLockKey(who, kind, uint64(id), uint64(sub)), amount)
}
func pruneVoteLocks(c *Court, who address) int {
	if c.voteLocks == nil {
		return 0
	}
	var stale []string
	pre := string(who)
	c.voteLocks.Iterate(pre, pre+"\xff", func(k string, _ any) bool {
		if _, _, _, ok := voteLockParts(who, k); !ok {
			return false
		}
		if !voteLockOpen(c, who, k) {
			stale = append(stale, k)
		}
		return false
	})
	for _, k := range stale {
		c.voteLocks.Remove(k)
	}
	return len(stale)
}
func beClaimID(s string) uint64 {
	var v uint64
	for i := 0; i < 8; i++ {
		v = v<<8 | uint64(s[i])
	}
	return v
}
func PruneVoteLocks(cur realm, courtSlug string, who address) int {
	if !cur.IsCurrent() {
		panic(errStaleRealm)
	}
	if !who.IsValid() {
		panic("kourtv2: that is not a valid address")
	}
	return pruneVoteLocks(mustCourt(courtSlug), who)
}
func CommitmentsOf(courtSlug string, who address) string {
	c := mustCourt(courtSlug)
	out := "stake:" + itoa(lockedOf(c, who)) +
		";vote:" + itoa(voteLockedOf(c, who)) +
		";free:" + itoa(disposable(c, who))
	if c.voteLocks == nil {
		return out
	}
	pre := string(who)
	c.voteLocks.Iterate(pre, pre+"\xff", func(k string, v any) bool {
		if !voteLockOpen(c, who, k) {
			return false
		}
		kind, id, sub, ok := voteLockParts(who, k)
		if !ok {
			return false
		}
		out += ";q:" + kind + ":" + itoa(int64(id)) + ":" + itoa(int64(sub)) +
			":" + itoa(v.(int64))
		return false
	})
	return out
}
func VoteLockedOf(courtSlug string, who address) int64 {
	return voteLockedOf(mustCourt(courtSlug), who)
}
