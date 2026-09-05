package zdex

import "gno.land/p/nt/ufmt/v0"

// Height is the current chain height (for UI deadlines).
func Height() int64 {
	return height()
}

// PoolList returns one pool id per line.
func PoolList() string {
	out := ""
	pools.Iterate("", "", func(k string, _ any) bool {
		if out != "" {
			out += "\n"
		}
		out += k
		return false
	})
	return out
}

// PoolSnapshot is a single-line UI record:
// id;symbol;name;reserveU;reserveT;virtualU;totalLP;feeBps;launched;unlockH;snipeUntil;snipeMaxBps;creator
func PoolSnapshot(poolID string) string {
	p := getPool(poolID)
	return ufmt.Sprintf("%s;%s;%s;%d;%d;%d;%d;%d;%d;%d;%d;%d;%s",
		p.ID, p.Symbol, p.Name,
		p.ReserveU, p.ReserveT, p.VirtualU, p.TotalLP, p.FeeBps,
		btoi(p.Launched), p.UnlockHeight, p.SnipeUntil, p.SnipeMaxBps,
		p.Creator.String())
}

// OrderList returns one order per line:
// id;pool;side;giveAmt;wantAmt;expireH;allOrNone;maker
func OrderList() string {
	out := ""
	orders.Iterate("", "", func(_ string, v any) bool {
		o := v.(*Order)
		side := "ask"
		if o.GiveUgnot {
			side = "bid"
		}
		line := ufmt.Sprintf("%d;%s;%s;%d;%d;%d;%d;%s",
			int64(o.ID), o.PoolID, side, o.GiveAmt, o.WantAmt, o.ExpireH, btoi(o.AllOrNone), o.Maker.String())
		if out != "" {
			out += "\n"
		}
		out += line
		return false
	})
	return out
}
