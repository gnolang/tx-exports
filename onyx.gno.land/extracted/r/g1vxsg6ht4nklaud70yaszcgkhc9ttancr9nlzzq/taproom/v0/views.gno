package taproom

// Read-only views for the web UI, returned as compact JSON strings so a client can read them
// with one vm/qeval call. Addresses are bech32 and numbers are plain integers, so no escaping is needed.

import (
	"strconv"
	"strings"

	"gno.land/p/g1vxsg6ht4nklaud70yaszcgkhc9ttancr9nlzzq/avatar/v0"
)

func RoundCount() int { return roundCount }

// AvatarSVG draws a player's gnome wearing their equipped items (see the avatar package).
func AvatarSVG(a address) string {
	var equipped [4]int
	if v := players.Get(a.String()); v != nil {
		equipped = v.(*Player).Equipped
	}
	return avatar.Render(a, equipped)
}

func FeeRecipient() address { return feeRecipient }

func FeesAccrued() int64 { return feesAccrued }

// RoundsJSON returns rounds [offset, offset+limit) as a JSON array (limit capped at 100).
func RoundsJSON(offset, limit int) string {
	if limit > 100 {
		limit = 100
	}
	var sb strings.Builder
	sb.WriteString("[")
	for i := offset; i >= 0 && i < roundCount && i < offset+limit; i++ {
		if i > offset {
			sb.WriteString(",")
		}
		writeRound(&sb, getRound(i))
	}
	sb.WriteString("]")
	return sb.String()
}

func RoundJSON(id int) string {
	var sb strings.Builder
	writeRound(&sb, getRound(id))
	return sb.String()
}

// PlayerJSON reports a player as the next Reveal would see them: weeks already missed are applied
// to a copy (freezes spent, or the streak shown as 0). It never changes state.
func PlayerJSON(a address) string {
	p := Player{}
	if v := players.Get(a.String()); v != nil {
		p = *v.(*Player)
	}
	applyMissedWeeks(&p, weekIndex(now()))

	var sb strings.Builder
	sb.WriteString(`{"addr":"` + a.String() + `","lifetime":` + i64(p.Lifetime) + `,"spent":` + i64(p.Spent))
	sb.WriteString(`,"streak":` + i64(p.Streak) + `,"lastWeek":`)
	if p.HasPlayed {
		sb.WriteString(i64(p.LastWeek))
	} else {
		sb.WriteString("null")
	}
	sb.WriteString(`,"freezes":` + strconv.Itoa(p.Freezes) + `,"owned":`)
	writeInts(&sb, p.Owned)
	sb.WriteString(`,"equipped":`)
	writeInts(&sb, p.Equipped[:])
	sb.WriteString(`,"skins":`)
	writeInts(&sb, append([]int{0}, p.Skins...))
	sb.WriteString(`,"claimable":` + i64(Claimable(a)) + "}")
	return sb.String()
}

func writeRound(sb *strings.Builder, r *Round) {
	sb.WriteString(`{"id":` + strconv.Itoa(r.ID) + `,"creator":"` + r.Creator.String() + `","skin":` + strconv.Itoa(r.BoardSkin))
	sb.WriteString(`,"start":` + i64(r.Start) + `,"commitEnd":` + i64(r.Seal.CommitEnd) + `,"revealEnd":` + i64(r.Seal.RevealEnd))
	sb.WriteString(`,"num":` + i64(r.Num) + `,"den":` + i64(r.Den) + `,"settled":` + strconv.FormatBool(r.Settled))
	sb.WriteString(`,"pot":` + i64(r.Pot) + `,"fee":` + i64(r.Fee) + `,"winners":[`)
	for i, w := range r.Winners {
		if i > 0 {
			sb.WriteString(",")
		}
		sb.WriteString(`"` + w.String() + `"`)
	}
	sb.WriteString(`],"entries":[`)
	for i, p := range r.Seal.Players() {
		if i > 0 {
			sb.WriteString(",")
		}
		// a pick and its salt stay hidden until their owner reveals them
		pick, salt, bonus := "null", "null", int64(0)
		if v := r.Entries.Get(p.String()); v != nil {
			e := v.(*Entry)
			pick, salt, bonus = i64(e.Pick), strconv.Quote(e.Salt), e.Bonus
		}
		commit, _ := r.Commits.Get(p.String()).(string)
		sb.WriteString(`{"addr":"` + p.String() + `","commit":"` + commit + `","revealed":` + strconv.FormatBool(r.Seal.IsRevealed(p)))
		sb.WriteString(`,"pick":` + pick + `,"salt":` + salt + `,"bonus":` + i64(bonus) + "}")
	}
	sb.WriteString("]}")
}

func writeInts(sb *strings.Builder, xs []int) {
	sb.WriteString("[")
	for i, x := range xs {
		if i > 0 {
			sb.WriteString(",")
		}
		sb.WriteString(strconv.Itoa(x))
	}
	sb.WriteString("]")
}

func i64(x int64) string { return strconv.FormatInt(x, 10) }
