package mequest

// JSON views for the website, served through Render("api/...").
// Read them with the RPC query vm/qrender, e.g. "<pkgpath>:api/quests".

import (
	"strconv"
	"strings"
	"time"

	"gno.land/r/sys/users"
)

func renderAPI(path string) string {
	switch {
	case path == "stats":
		return apiStats()
	case path == "quests":
		out := make([]string, 0, len(quests))
		for _, q := range quests {
			out = append(out, questJSON(q, false))
		}
		return "[" + strings.Join(out, ",") + "]"
	case strings.HasPrefix(path, "q/"):
		id, err := strconv.Atoi(path[2:])
		if err != nil || id < 1 || id > len(quests) {
			return "null"
		}
		return questJSON(quests[id-1], true)
	case strings.HasPrefix(path, "p/"):
		return passportJSON(address(path[2:]))
	case path == "top":
		return topJSON()
	case path == "feed":
		out := []string{}
		for i := len(log) - 1; i >= 0; i-- {
			out = append(out, "{\"at\":"+i64(log[i].At)+",\"msg\":"+js(log[i].Msg)+"}")
		}
		return "[" + strings.Join(out, ",") + "]"
	case path == "receipts":
		out := []string{}
		for i := len(receipts) - 1; i >= 0; i-- {
			r := receipts[i]
			out = append(out, "{\"n\":"+strconv.Itoa(r.N)+",\"quest\":"+strconv.Itoa(r.Quest)+
				",\"title\":"+js(quests[r.Quest-1].Title)+",\"who\":"+who(r.Who)+",\"ok\":"+strconv.FormatBool(r.Ok)+
				",\"check\":"+js(r.Check)+",\"paid\":"+i64(r.Paid)+",\"rarity\":"+strconv.Itoa(quests[r.Quest-1].Rarity)+
				",\"art\":"+js(quests[r.Quest-1].Art)+",\"height\":"+i64(r.Height)+",\"at\":"+i64(r.At)+"}")
		}
		return "[" + strings.Join(out, ",") + "]"
	case path == "projects":
		out := []string{}
		for a, on := range projects {
			if on {
				out = append(out, who(a))
			}
		}
		return "{\"admin\":" + js(string(admin)) + ",\"approved\":[" + strings.Join(out, ",") + "]}"
	}
	return "null"
}

func apiStats() string {
	locked := int64(0)
	open := 0
	now := time.Now().Unix()
	for _, q := range quests {
		locked += q.Pool
		if now < q.Expires && len(q.Winners) < q.Max {
			open++
		}
	}
	return "{\"quests\":" + strconv.Itoa(len(quests)) + ",\"open\":" + strconv.Itoa(open) +
		",\"locked\":" + i64(locked) + ",\"paid\":" + i64(paidOut) +
		",\"cards\":" + strconv.Itoa(minted) + ",\"players\":" + strconv.Itoa(len(players)) + ",\"joined\":" + strconv.Itoa(joined) +
		",\"season\":" + js(Season) + ",\"now\":" + i64(now) + "}"
}

func questJSON(q *Quest, full bool) string {
	s := "{\"id\":" + strconv.Itoa(q.ID) + ",\"title\":" + js(q.Title) + ",\"desc\":" + js(q.Desc) +
		",\"art\":" + js(q.Art) + ",\"funder\":" + who(q.Funder) + ",\"rarity\":" + strconv.Itoa(q.Rarity) +
		",\"kind\":" + js(q.Kind) + ",\"arg\":" + js(q.Arg) + ",\"pay\":" + js(q.Pay) +
		",\"reward\":" + i64(q.Reward) + ",\"pool\":" + i64(q.Pool) + ",\"funded\":" + i64(q.Funded) +
		",\"max\":" + strconv.Itoa(q.Max) + ",\"claimed\":" + strconv.Itoa(len(q.Winners)) +
		",\"pending\":" + strconv.Itoa(len(q.pending)) + ",\"expires\":" + i64(q.Expires) +
		",\"settled\":" + strconv.FormatBool(q.Settled)
	if full {
		w := []string{}
		for i, a := range q.Winners {
			w = append(w, "{\"serial\":"+strconv.Itoa(i+1)+",\"who\":"+who(a)+"}")
		}
		p := []string{}
		for a, proof := range q.pending {
			p = append(p, "{\"who\":"+who(a)+",\"proof\":"+js(proof)+"}")
		}
		s += ",\"winners\":[" + strings.Join(w, ",") + "],\"queue\":[" + strings.Join(p, ",") + "]"
	}
	return s + "}"
}

func passportJSON(a address) string {
	cs := []string{}
	for _, c := range cards[a] {
		cs = append(cs, "{\"quest\":"+strconv.Itoa(c.QuestID)+",\"title\":"+js(c.Title)+",\"art\":"+js(c.Art)+
			",\"rarity\":"+strconv.Itoa(c.Rarity)+",\"serial\":"+strconv.Itoa(c.Serial)+
			",\"season\":"+js(c.Season)+",\"at\":"+i64(c.At)+"}")
	}
	pend := []string{}
	for _, q := range quests {
		if _, ok := q.pending[a]; ok {
			pend = append(pend, strconv.Itoa(q.ID))
		}
	}
	best := BestRarity(a)
	day := strconv.FormatInt(time.Now().Unix()/daySecs, 10)
	return "{\"who\":" + who(a) + ",\"rank\":" + js(rankName[best]) + ",\"best\":" + strconv.Itoa(best) +
		",\"points\":" + i64(points[a]) + ",\"today\":" + strconv.Itoa(daily[string(a)+":"+day]) +
		",\"dailyCap\":" + strconv.Itoa(DailyCap) + ",\"streak\":" + strconv.Itoa(StreakOf(a)) +
		",\"checkedToday\":" + strconv.FormatBool(lastDay[a] == time.Now().Unix()/daySecs && streak[a] > 0) +
		",\"joinRank\":" + strconv.Itoa(joinRank[a]) + ",\"invites\":" + strconv.Itoa(invitesDone[a]) +
		",\"hasInviter\":" + strconv.FormatBool(inviter[a] != "") + ",\"projects\":" + strconv.Itoa(ProjectsDone(a)) +
		",\"posted\":" + strconv.Itoa(posted[a]) + ",\"approved\":" + strconv.FormatBool(projects[a] || a == admin) +
		",\"cards\":[" + strings.Join(cs, ",") + "],\"pending\":[" + strings.Join(pend, ",") + "]}"
}

func topJSON() string {
	list := ranked()
	out := []string{}
	for i, a := range list {
		if i == 50 {
			break
		}
		art := ""
		best := 0
		for _, c := range cards[a] {
			if c.Rarity > best {
				best, art = c.Rarity, c.Art
			}
		}
		out = append(out, "{\"who\":"+who(a)+",\"points\":"+i64(points[a])+",\"best\":"+strconv.Itoa(best)+",\"bestArt\":"+js(art)+
			",\"cards\":"+strconv.Itoa(len(cards[a]))+"}")
	}
	return "[" + strings.Join(out, ",") + "]"
}

func ranked() []address {
	list := make([]address, len(players))
	copy(list, players)
	for i := 1; i < len(list); i++ {
		for j := i; j > 0 && points[list[j]] > points[list[j-1]]; j-- {
			list[j], list[j-1] = list[j-1], list[j]
		}
	}
	return list
}

// who returns {"addr":..., "name":...}; name is the wallet's unique
// gno.land username from r/sys/users, or "" if it has none.
func who(a address) string {
	name := ""
	if u := users.ResolveAddress(a); u != nil {
		name = u.Name()
	}
	return "{\"addr\":" + js(string(a)) + ",\"name\":" + js(name) + "}"
}

func i64(n int64) string { return strconv.FormatInt(n, 10) }

// js quotes a string as a JSON string.
func js(s string) string {
	var b strings.Builder
	b.WriteByte('"')
	for _, r := range s {
		switch {
		case r == '"':
			b.WriteString("\\\"")
		case r == '\\':
			b.WriteString("\\\\")
		case r == '\n':
			b.WriteString("\\n")
		case r < 0x20:
			h := strconv.FormatInt(int64(r), 16)
			b.WriteString("\\u" + strings.Repeat("0", 4-len(h)) + h)
		default:
			b.WriteRune(r)
		}
	}
	b.WriteByte('"')
	return b.String()
}
