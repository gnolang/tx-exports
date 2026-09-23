package crowdfunding

import (
	"time"

	"gno.land/p/nt/avl/v0"
	"gno.land/p/nt/ufmt/v0"
)

// maxInt64 bounds the checked-integer arithmetic on campaign totals.
const maxInt64 = 1<<63 - 1

// Campaign holds the immutable terms and mutable funding state of a single
// crowdfunding campaign.
type Campaign struct {
	id           int64
	creator      address
	title        string
	targetUgnot  int64
	deadlineUnix int64
	totalRaised  int64
	withdrawn    bool

	// updates holds the creator's append-only progress notes, bounded by
	// maxUpdateBytes and maxUpdatesPerCampaign (see crowdfunding.gno). The
	// String() view only reports a count, never iterates the slice, so
	// rendering a campaign stays O(1) regardless of update history.
	updates []string

	// contributions maps a contributor address (string(address)) to their
	// cumulative contribution in ugnot. Zeroed on refund, never removed,
	// so a repeat Refund call reliably finds a zero balance.
	contributions avl.Tree
}

func (c *Campaign) status() string {
	now := time.Now().Unix()
	switch {
	case c.withdrawn:
		return "withdrawn"
	case now < c.deadlineUnix:
		return "active"
	case c.totalRaised >= c.targetUgnot:
		return "successful"
	default:
		return "failed"
	}
}

func (c *Campaign) String() string {
	return ufmt.Sprintf(
		"- id: %d\n- title: %s\n- creator: %s\n- target: %dugnot\n- raised: %dugnot\n- deadline: %s\n- status: %s\n- updates: %d",
		c.id, c.title, c.creator, c.targetUgnot, c.totalRaised,
		time.Unix(c.deadlineUnix, 0).UTC().Format(time.RFC3339), c.status(), len(c.updates),
	)
}
