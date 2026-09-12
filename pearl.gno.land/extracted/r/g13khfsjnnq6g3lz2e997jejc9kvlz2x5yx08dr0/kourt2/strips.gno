package kourt2
import bptree "gno.land/p/nt/bptree/v0"
const stripActorCap = 5
type stripRow struct {
	slug    string
	claimID uint64
}
var globalStripIdx = bptree.NewBPTree32()
func beHeightKey(h int64) string {
	if h < 0 {
		h = 0
	}
	return beClaimKey(uint64(h))
}
func stripDeadline(cs *claimState) int64 { return cs.answerHeight + settleDelay }
func stripKey(cs *claimState) string {
	return beHeightKey(stripDeadline(cs)) + beClaimKey(cs.id)
}
func globalStripKey(slug string, cs *claimState) string {
	return beHeightKey(stripDeadline(cs)) + slug + beClaimKey(cs.id)
}
func pendingKey(cs *claimState) string {
	return beHeightKey(cs.openedAt) + beClaimKey(cs.id)
}
func stripEnter(c *Court, cs *claimState) {
	if cs.inStrip {
		return
	}
	if c.stripIdx == nil {
		c.stripIdx = bptree.NewBPTree32()
	}
	c.stripIdx.Set(stripKey(cs), cs.id)
	globalStripIdx.Set(globalStripKey(c.id, cs), &stripRow{slug: c.id, claimID: cs.id})
	cs.inStrip = true
}
func stripExit(c *Court, cs *claimState) {
	if !cs.inStrip {
		return
	}
	if c.stripIdx != nil {
		c.stripIdx.Remove(stripKey(cs))
	}
	globalStripIdx.Remove(globalStripKey(c.id, cs))
	cs.inStrip = false
}
func pendingEnter(c *Court, cs *claimState) {
	if cs.inPending {
		return
	}
	if c.pendingIdx == nil {
		c.pendingIdx = bptree.NewBPTree32()
	}
	c.pendingIdx.Set(pendingKey(cs), cs.id)
	cs.inPending = true
}
func pendingExit(c *Court, cs *claimState) {
	if !cs.inPending {
		return
	}
	if c.pendingIdx != nil {
		c.pendingIdx.Remove(pendingKey(cs))
	}
	cs.inPending = false
}
func stripPageIDs(c *Court, offset, limit int) []uint64 {
	out := []uint64{}
	if c.stripIdx == nil || limit <= 0 {
		return out
	}
	capBinds := c.stripIdx.Size() > renderPageSize
	perAnswerer := map[string]int{}
	perAuthor := map[string]int{}
	skipped := 0
	c.stripIdx.Iterate("", "", func(_ string, v any) bool {
		id, ok := v.(uint64)
		if !ok {
			return false
		}
		cv := c.claims.Get(beClaimKey(id))
		if cv == nil {
			return false
		}
		cs := cv.(*claimState)
		if capBinds && !cs.seeded {
			a := cs.answerer.String()
			b := cs.author.String()
			if perAnswerer[a] >= stripActorCap || perAuthor[b] >= stripActorCap {
				return false
			}
			perAnswerer[a]++
			perAuthor[b]++
		}
		if skipped < offset {
			skipped++
			return false
		}
		out = append(out, id)
		return len(out) >= limit
	})
	return out
}
func StripPage(courtSlug string, offset, limit int) []uint64 {
	return stripPageIDs(mustCourt(courtSlug), offset, limit)
}
func StripSize(courtSlug string) int {
	c := mustCourt(courtSlug)
	if c.stripIdx == nil {
		return 0
	}
	return c.stripIdx.Size()
}
func PendingPage(courtSlug string, offset, limit int) []uint64 {
	out := []uint64{}
	c := mustCourt(courtSlug)
	if c.pendingIdx == nil || limit <= 0 {
		return out
	}
	c.pendingIdx.IterateByOffset(offset, limit, func(_ string, v any) bool {
		if id, ok := v.(uint64); ok {
			out = append(out, id)
		}
		return false
	})
	return out
}
func PendingSize(courtSlug string) int {
	c := mustCourt(courtSlug)
	if c.pendingIdx == nil {
		return 0
	}
	return c.pendingIdx.Size()
}
func DirectoryStripPage(offset, limit int) ([]string, []uint64) {
	slugs := []string{}
	ids := []uint64{}
	if limit <= 0 {
		return slugs, ids
	}
	capBinds := globalStripIdx.Size() > renderPageSize
	perCourt := map[string]int{}
	skipped := 0
	globalStripIdx.Iterate("", "", func(_ string, v any) bool {
		r, ok := v.(*stripRow)
		if !ok {
			return false
		}
		if capBinds {
			if perCourt[r.slug] >= stripActorCap {
				return false
			}
			perCourt[r.slug]++
		}
		if skipped < offset {
			skipped++
			return false
		}
		slugs = append(slugs, r.slug)
		ids = append(ids, r.claimID)
		return len(slugs) >= limit
	})
	return slugs, ids
}
func DirectoryStripSize() int { return globalStripIdx.Size() }
func OnStrip(courtSlug string, claimID uint64) bool {
	return mustClaim(mustCourt(courtSlug), claimID).inStrip
}
func OnPending(courtSlug string, claimID uint64) bool {
	return mustClaim(mustCourt(courtSlug), claimID).inPending
}
