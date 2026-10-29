package kourt
const stakeIdxPage = 64
const stakeIdxEntry = 9
const stakePageMax = 200
type stakeRow struct {
	packed string
}
func stakeIdxKey(who address, claimID uint64) string {
	return string(who) + beClaimKey(claimID/stakeIdxPage)
}
func sideByte(side int) string {
	if side == sideYES {
		return "y"
	}
	return "n"
}
func stakeIdxMine(pre, k string) bool { return len(k) == len(pre)+8 }
func indexPosition(c *Court, claimID uint64, who address, side int) {
	k := stakeIdxKey(who, claimID)
	entry := beClaimKey(claimID) + sideByte(side)
	if v := c.stakeIdx.Get(k); v != nil {
		r := v.(*stakeRow)
		r.packed += entry
		return
	}
	c.stakeIdx.Set(k, &stakeRow{packed: entry})
}
func stakeIdxWalk(c *Court, who address, fn func(claimID uint64, side int) bool) {
	if c.stakeIdx == nil {
		return
	}
	pre := string(who)
	c.stakeIdx.Iterate(pre, pre+"\xff", func(k string, v any) bool {
		if !stakeIdxMine(pre, k) {
			return false
		}
		r, ok := v.(*stakeRow)
		if !ok {
			return false
		}
		for i := 0; i+stakeIdxEntry <= len(r.packed); i += stakeIdxEntry {
			side := sideNO
			if r.packed[i+8] == 'y' {
				side = sideYES
			}
			if fn(beClaimID(r.packed[i:i+8]), side) {
				return true
			}
		}
		return false
	})
}
func stakeIdxCount(c *Court, who address) int {
	if c.stakeIdx == nil {
		return 0
	}
	n, pre := 0, string(who)
	c.stakeIdx.Iterate(pre, pre+"\xff", func(k string, v any) bool {
		if !stakeIdxMine(pre, k) {
			return false
		}
		if r, ok := v.(*stakeRow); ok {
			n += len(r.packed) / stakeIdxEntry
		}
		return false
	})
	return n
}
func StakedSize(courtSlug string, who address) int {
	if !who.IsValid() {
		return 0
	}
	return stakeIdxCount(mustCourt(courtSlug), who)
}
func StakedPage(courtSlug string, who address, offset, limit int) string {
	if !who.IsValid() {
		return ""
	}
	if limit <= 0 || limit > stakePageMax {
		limit = stakePageMax
	}
	c := mustCourt(courtSlug)
	acc := ratePreview(c)
	out, seen, sent := "", 0, 0
	stakeIdxWalk(c, who, func(claimID uint64, side int) bool {
		if seen < offset {
			seen++
			return false
		}
		seen++
		var live, conv int64
		if cv := c.claims.Get(beClaimKey(claimID)); cv != nil {
			cs := cv.(*claimState)
			if pv := cs.stakers.Get(posKey(who, side)); pv != nil {
				pos := pv.(*stakePos)
				live = pos.stake
				conv = convPreviewCC(cs, pos, acc)
			}
		}
		out += ";c:" + itoa(int64(claimID)) + ":" + itoa(int64(side)) +
			":" + itoa(live) + ":" + itoa(conv)
		sent++
		return sent >= limit
	})
	if out == "" {
		return ""
	}
	return out[1:]
}
