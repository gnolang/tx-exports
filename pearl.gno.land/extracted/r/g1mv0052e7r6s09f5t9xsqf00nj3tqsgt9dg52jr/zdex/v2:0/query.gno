package zdex

import (
	"gno.land/p/nt/ufmt/v0"
	"gno.land/r/demo/defi/grc20reg"
)

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
// id;symbol;name;reserveU;reserveT;virtualU;totalLP;feeBps;launched;unlockH;snipeUntil;snipeMaxBps;creator;decimals
func PoolSnapshot(poolID string) string {
	p := getPool(poolID)
	return ufmt.Sprintf("%s;%s;%s;%d;%d;%d;%d;%d;%d;%d;%d;%d;%s;%d",
		p.ID, p.Symbol, p.Name,
		p.ReserveU, p.ReserveT, p.VirtualU, p.TotalLP, p.FeeBps,
		btoi(p.Launched), p.UnlockHeight, p.SnipeUntil, p.SnipeMaxBps,
		p.Creator.String(), p.Decimals)
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

func PointsSnapshot(owner address) string {
	life, ep, cl := PointsOf(owner)
	return ufmt.Sprintf("%d;%d;%d;%d", life, ep, cl, ClaimableFeeShare(owner))
}

func EpochSnapshot() string {
	id, endH, pot, pts, cID, cPot, cPts := EpochInfo()
	return ufmt.Sprintf("%d;%d;%d;%d;%d;%d;%d", id, endH, pot, pts, cID, cPot, cPts)
}

func tokenLine(symbol, name, key string, decimals int64, pooled, internal bool) string {
	if name == "" {
		name = symbol
	}
	return ufmt.Sprintf("%s;%s;%s;%d;%d;%d", symbol, name, key, decimals, btoi(pooled), btoi(internal))
}

// TokenCatalog lists known tokens (internal + pooled), one per line:
// symbol;name;key;decimals;pooled;internal
func TokenCatalog() string {
	out := ""
	seen := map[string]bool{}
	add := func(line, symbol string) {
		if seen[symbol] {
			return
		}
		seen[symbol] = true
		if out != "" {
			out += "\n"
		}
		out += line
	}
	tokens.Iterate("", "", func(k string, v any) bool {
		rec := v.(*tokenRec)
		pooled := tryPool(poolIDFor(k)) != nil
		add(tokenLine(rec.token.GetSymbol(), rec.token.GetName(), rec.token.ID(), int64(rec.token.GetDecimals()), pooled, true), k)
		return false
	})
	pools.Iterate("", "", func(_ string, v any) bool {
		p := v.(*Pool)
		internal := tryTok(p.Symbol) != nil
		add(tokenLine(p.Symbol, p.Name, p.Token, p.Decimals, true, internal), p.Symbol)
		return false
	})
	return out
}

// LookupToken resolves an internal symbol, pool id, or GRC20 registry key.
// Same record as TokenCatalog, or empty if unknown.
func LookupToken(ref string) string {
	if ref == "" {
		return ""
	}
	if p := tryPool(ref); p != nil {
		return tokenLine(p.Symbol, p.Name, p.Token, p.Decimals, true, tryTok(p.Symbol) != nil)
	}
	if rec := tryTok(ref); rec != nil {
		return tokenLine(rec.token.GetSymbol(), rec.token.GetName(), rec.token.ID(), int64(rec.token.GetDecimals()), tryPool(poolIDFor(ref)) != nil, true)
	}
	if p := tryPool(poolIDFor(ref)); p != nil {
		return tokenLine(p.Symbol, p.Name, p.Token, p.Decimals, true, tryTok(p.Symbol) != nil)
	}
	t := grc20reg.Get(ref)
	if t == nil {
		return ""
	}
	sym := t.GetSymbol()
	return tokenLine(sym, t.GetName(), ref, int64(t.GetDecimals()), tryPool(poolIDFor(sym)) != nil, false)
}
