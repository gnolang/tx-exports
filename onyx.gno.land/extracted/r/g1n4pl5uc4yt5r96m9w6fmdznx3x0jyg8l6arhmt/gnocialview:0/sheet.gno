package gnocialview

import (
	"strconv"
	"strings"

	gnocial "gno.land/r/g1n4pl5uc4yt5r96m9w6fmdznx3x0jyg8l6arhmt/gnocial"
)

const pageSize = 8

// Sheet is the stable text board the website reads.
// kind selects the page. a, b, and c are cursors or decimal limits.
// Gated bodies are left empty. The fund realm still stores them.
func Sheet(kind, a, b, c string) string {
	var body string
	switch kind {
	case "feed":
		body = sheetPosts(gnocial.Feed(atoiOpt(a), atoiLimit(b)), false)
	case "author":
		p, ok := gnocial.ProfileByHandle(a)
		if !ok {
			panic("unknown handle")
		}
		body = sheetPosts(gnocial.PostsBy(p.Addr, atoiOpt(b), atoiLimit(c)), false)
	case "replies":
		body = sheetPosts(gnocial.Replies(atoiReq(a), atoiOpt(b), atoiLimit(c)), true)
	case "post":
		body = sheetOne(atoiReq(a))
	case "people":
		body = sheetProfiles(gnocial.Handles(a, atoiLimit(b)))
	case "profile":
		body = sheetProfile(a)
	case "account":
		body = sheetAccount(a)
	case "hot":
		body = sheetPosts(gnocial.Hot(atoiLimit(a)), false)
	case "followfeed":
		body = sheetFollowFeed(a, atoiLimit(b))
	case "graph":
		body = sheetProfiles(gnocial.FollowingList(mustAddr(a), optAddr(b), atoiLimit(c)))
	case "fans":
		body = sheetProfiles(gnocial.FollowerList(mustAddr(a), optAddr(b), atoiLimit(c)))
	case "holdings":
		body = sheetHoldings(gnocial.Holdings(mustAddr(a), optAddr(b), atoiLimit(c)))
	case "meta":
		body = sheetMeta()
	case "quotebuy":
		body = quoteLine(true, a, b, c)
	case "quotesell":
		body = quoteLine(false, a, b, c)
	case "shares":
		body = strconv.Itoa(gnocial.SharesOf(mustAddr(a), b))
	default:
		panic("kind")
	}
	return "v1\n" + body
}

func sheetPosts(posts []gnocial.Article, full bool) string {
	var b strings.Builder
	for i, p := range posts {
		if i > 0 {
			b.WriteString("\n")
		}
		if full {
			b.WriteString(postLine(p))
		} else {
			b.WriteString(cardLine(p))
		}
	}
	return b.String()
}

func sheetOne(id int) string {
	p, ok := gnocial.GetPost(id)
	if !ok {
		return ""
	}
	return postLine(p)
}

func sheetProfile(handle string) string {
	p, ok := gnocial.ProfileByHandle(handle)
	if !ok {
		return ""
	}
	return profileLine(p)
}

func sheetAccount(raw string) string {
	who := optAddr(raw)
	if !who.IsValid() {
		return ""
	}
	p, ok := gnocial.ProfileOf(who)
	if !ok {
		return ""
	}
	return profileLine(p)
}

func sheetProfiles(rows []gnocial.Profile) string {
	var b strings.Builder
	for i, p := range rows {
		if i > 0 {
			b.WriteString("\n")
		}
		b.WriteString(p.Handle + "\t" + esc(p.Name) + "\t" + strconv.Itoa(p.Followers) + "\t" + strconv.Itoa(p.Posts))
	}
	return b.String()
}

func sheetHoldings(rows []gnocial.Holding) string {
	var b strings.Builder
	for i, h := range rows {
		if i > 0 {
			b.WriteString("\n")
		}
		b.WriteString(h.Creator.String() + "\t" + esc(h.Handle) + "\t" + strconv.Itoa(h.Amount))
	}
	return b.String()
}

func sheetFollowFeed(raw string, limit int) string {
	who := mustAddr(raw)
	posts := gnocial.Feed(0, limit)
	var b strings.Builder
	n := 0
	for _, p := range posts {
		prof, ok := gnocial.ProfileOf(p.Author)
		if !ok || !gnocial.Following(who, prof.Handle) {
			continue
		}
		if n > 0 {
			b.WriteString("\n")
		}
		b.WriteString(cardLine(p))
		n++
	}
	return b.String()
}

func sheetMeta() string {
	paused := "0"
	if gnocial.Paused() {
		paused = "1"
	}
	return strings.Join([]string{
		gnocial.Version(),
		gnocial.Successor(),
		paused,
		strconv.FormatInt(gnocial.TotalReserve(), 10),
		gnocial.Admin().String(),
		gnocial.Treasury().String(),
		strconv.Itoa(gnocial.MemberCount()),
		strconv.Itoa(gnocial.FeedCount()),
		strconv.Itoa(gnocial.LatestID()),
	}, "\t")
}

func profileLine(p gnocial.Profile) string {
	supply, reserve, holders := gnocial.SupplyOf(p.Handle)
	next := "-1"
	if supply < gnocial.MaxSupply {
		due, _, _, _, _ := gnocial.QuoteBuy(p.Handle, 1)
		next = strconv.FormatInt(due, 10)
	}
	ref := ""
	if p.Referrer.IsValid() {
		ref = p.Referrer.String()
	}
	return strings.Join([]string{
		p.Handle,
		esc(p.Name),
		esc(p.Bio),
		p.Addr.String(),
		ref,
		strconv.Itoa(p.Posts),
		strconv.Itoa(p.Followers),
		strconv.Itoa(p.Following),
		strconv.FormatInt(p.TipsIn, 10),
		strconv.FormatInt(p.TipsOut, 10),
		strconv.Itoa(supply),
		strconv.FormatInt(reserve, 10),
		strconv.Itoa(holders),
		next,
		strconv.FormatInt(p.CreatorFee, 10),
	}, "\t")
}

// quoteLine prices a trade. c is an optional buyer or seller address.
// Empty c is the anonymous quote. The first number is the amount due or the proceeds.
func quoteLine(buy bool, handle, amount, trader string) string {
	n := atoiReq(amount)
	var head, curve, cf, pf, rf int64
	trader = strings.TrimSpace(trader)
	if buy {
		if trader == "" {
			head, curve, cf, pf, rf = gnocial.QuoteBuy(handle, n)
		} else {
			head, curve, cf, pf, rf = gnocial.QuoteBuyFor(handle, trader, n)
		}
	} else if trader == "" {
		head, curve, cf, pf, rf = gnocial.QuoteSell(handle, n)
	} else {
		head, curve, cf, pf, rf = gnocial.QuoteSellFor(handle, trader, n)
	}
	return join5(head, curve, cf, pf, rf)
}

func cardLine(p gnocial.Article) string {
	h, name := namesOf(p.Author)
	return strings.Join([]string{
		strconv.Itoa(p.ID),
		esc(h),
		esc(name),
		strconv.Itoa(p.Likes),
		strconv.Itoa(p.Replies),
		strconv.FormatInt(p.Tips, 10),
		bit(p.Gated),
		esc(openPreview(p)),
	}, "\t")
}

func postLine(p gnocial.Article) string {
	h, name := namesOf(p.Author)
	body := ""
	if !p.Gated && !p.Deleted {
		body = p.Body
	}
	return strings.Join([]string{
		strconv.Itoa(p.ID),
		p.Author.String(),
		esc(h),
		esc(name),
		strconv.Itoa(p.ReplyTo),
		strconv.Itoa(p.Likes),
		strconv.Itoa(p.Replies),
		strconv.FormatInt(p.Tips, 10),
		bit(p.Gated),
		bit(p.Deleted),
		strconv.FormatInt(p.Height, 10),
		esc(body),
	}, "\t")
}

func namesOf(a address) (handle, name string) {
	p, ok := gnocial.ProfileOf(a)
	if !ok {
		return a.String(), a.String()
	}
	return p.Handle, p.Name
}

func openPreview(p gnocial.Article) string {
	if p.Gated || p.Deleted {
		return ""
	}
	return preview(strings.ReplaceAll(p.Body, "\n", " "), 160)
}

func bit(v bool) string {
	if v {
		return "1"
	}
	return "0"
}

func esc(s string) string {
	s = strings.ReplaceAll(s, "\\", "\\\\")
	s = strings.ReplaceAll(s, "\r", "")
	s = strings.ReplaceAll(s, "\n", "\\n")
	s = strings.ReplaceAll(s, "\t", "\\t")
	return s
}

func join5(a, b, c, d, e int64) string {
	return strconv.FormatInt(a, 10) + "\t" + strconv.FormatInt(b, 10) + "\t" + strconv.FormatInt(c, 10) + "\t" + strconv.FormatInt(d, 10) + "\t" + strconv.FormatInt(e, 10)
}

func atoiOpt(s string) int {
	s = strings.TrimSpace(s)
	if s == "" {
		return 0
	}
	n, err := strconv.Atoi(s)
	if err != nil || n < 0 {
		panic("cursor")
	}
	return n
}

func atoiReq(s string) int {
	n := atoiOpt(s)
	if n < 1 {
		panic("id")
	}
	return n
}

func atoiLimit(s string) int {
	s = strings.TrimSpace(s)
	if s == "" {
		return pageSize
	}
	n, err := strconv.Atoi(s)
	if err != nil {
		panic("limit")
	}
	if n < 1 || n > 20 {
		panic("limit")
	}
	return n
}

func mustAddr(s string) address {
	a := optAddr(s)
	if !a.IsValid() {
		panic("bad address")
	}
	return a
}

func optAddr(s string) address {
	s = strings.TrimSpace(s)
	if s == "" {
		return address("")
	}
	if len(s) > 60 {
		panic("bad address")
	}
	return address(s)
}

func preview(s string, n int) string {
	if len(s) <= n {
		return s
	}
	i := n
	for i > 0 && s[i]&0xC0 == 0x80 {
		i--
	}
	return s[:i] + "…"
}
