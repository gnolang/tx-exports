package bolo

import "chain"

// recordDeadline records a passed deadline (API §3.1): an open campaign whose
// deadline has passed becomes closed, at its deadline, for reason deadline, and
// leaves the active indexes; Closed is emitted, naming the caller there and only
// there. Every crossing function that takes a campaign ID calls it before any other
// precondition; queries and Render compute the same with effective, writing nothing.
func recordDeadline(cur realm, c *campaign) {
	s := c.state
	if s.status != statusOpen || c.deadline == 0 || now() < c.deadline {
		return
	}
	s.status, s.closedAt, s.closeReason = statusClosed, c.deadline, reasonDeadline
	stats.open--
	dropActive(c)
	chain.Emit(evClosed, "id", idString(c.id), "reason", reasonDeadline, "by", cur.Previous().Address().String())
}

// addActive puts c in the two active indexes, which list the open, listed campaigns
// (API §2.5).
func addActive(c *campaign) {
	key := c.id.Binary()
	active.Set(key, true)
	activeByCategory.Set(c.category+"/"+key, true)
}

// dropActive takes c out of the two active indexes (API §2.5).
func dropActive(c *campaign) {
	key := c.id.Binary()
	active.Remove(key)
	activeByCategory.Remove(c.category + "/" + key)
}
