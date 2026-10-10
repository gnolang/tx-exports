package arena

import (
	"strconv"
	"strings"
)

// Holding is one creator's tickets in a wallet. It is a copy.
type Holding struct {
	Creator address
	Handle  string
	Amount  int
}

func mustLimit(n int) int {
	if n < 1 || n > 20 {
		panic("limit")
	}
	return n
}

// Feed lists newest top-level posts with id < before. before 0 starts at the newest.
func Feed(before, limit int) []Article {
	limit = mustLimit(limit)
	posts := recentPosts(before, limit)
	out := make([]Article, len(posts))
	for i, p := range posts {
		out[i] = *p
	}
	return out
}

// PostsBy lists one member's newest top-level posts with id < before.
func PostsBy(addr address, before, limit int) []Article {
	limit = mustLimit(limit)
	prefix := addr.String() + "/"
	out := make([]Article, 0, limit)
	state.byAuthor.ReverseIterate(prefix, prefix+"~", func(key string, value any) bool {
		id, ok := value.(int)
		if !ok {
			panic("author type")
		}
		if before > 0 && id >= before {
			return false
		}
		p := postByID(id)
		if p == nil || p.Deleted {
			return false
		}
		out = append(out, *p)
		return len(out) >= limit
	})
	return out
}

// Replies lists direct replies of parent with id > after, oldest first.
func Replies(parent, after, limit int) []Article {
	limit = mustLimit(limit)
	if parent <= 0 {
		panic("id")
	}
	prefix := pad(parent) + "/"
	start := prefix
	if after > 0 {
		start = prefix + pad(after) + "\x00"
	}
	out := make([]Article, 0, limit)
	state.replies.Iterate(start, prefix+"~", func(key string, value any) bool {
		id, ok := value.(int)
		if !ok {
			panic("reply type")
		}
		p := postByID(id)
		if p == nil || p.Deleted {
			return false
		}
		out = append(out, *p)
		return len(out) >= limit
	})
	return out
}

// Handles lists profiles in handle order, strictly after the given handle.
func Handles(after string, limit int) []Profile {
	limit = mustLimit(limit)
	start := ""
	after = strings.ToLower(strings.TrimSpace(after))
	if after != "" {
		start = after + "\x00"
	}
	out := make([]Profile, 0, limit)
	state.byHandle.Iterate(start, "", func(key string, value any) bool {
		p, ok := value.(*Profile)
		if !ok {
			panic("profile type")
		}
		out = append(out, *p)
		return len(out) >= limit
	})
	return out
}

// FollowingList lists profiles `who` follows, in address order, after `after`.
func FollowingList(who, after address, limit int) []Profile {
	return edgeList(who, after, limit, ">")
}

// FollowerList lists profiles that follow `who`, in address order, after `after`.
func FollowerList(who, after address, limit int) []Profile {
	return edgeList(who, after, limit, "<")
}

func edgeList(who, after address, limit int, sep string) []Profile {
	limit = mustLimit(limit)
	if !who.IsValid() {
		panic("bad address")
	}
	prefix := who.String() + sep
	start := prefix
	if after.IsValid() {
		start = prefix + after.String() + "\x00"
	}
	out := make([]Profile, 0, limit)
	tree := state.follows
	if sep == "<" {
		tree = state.fans
	}
	tree.Iterate(start, prefix+"~", func(key string, value any) bool {
		i := strings.LastIndex(key, sep)
		if i < 0 {
			return false
		}
		p := profileByAddr(address(key[i+1:]))
		if p == nil {
			return false
		}
		out = append(out, *p)
		return len(out) >= limit
	})
	return out
}

// Holdings lists ticket balances of holder, after the given creator address.
func Holdings(holder, after address, limit int) []Holding {
	limit = mustLimit(limit)
	if !holder.IsValid() {
		panic("bad address")
	}
	prefix := holder.String() + "/"
	start := prefix
	if after.IsValid() {
		start = prefix + after.String() + "\x00"
	}
	out := make([]Holding, 0, limit)
	state.shares.Iterate(start, prefix+"~", func(key string, value any) bool {
		n, ok := value.(int)
		if !ok {
			panic("share type")
		}
		i := strings.LastIndex(key, "/")
		if i < 0 || n < 1 {
			return false
		}
		creator := address(key[i+1:])
		handle := ""
		if p := profileByAddr(creator); p != nil {
			handle = p.Handle
		}
		out = append(out, Holding{Creator: creator, Handle: handle, Amount: n})
		return len(out) >= limit
	})
	return out
}

// Hot ranks the newest window the same way Render does. It is not a global index.
func Hot(limit int) []Article {
	limit = mustLimit(limit)
	posts := recentPosts(0, hotWindow)
	top := make([]scoredPost, 0, limit)
	for _, p := range posts {
		score := int64(p.Likes)*1_000_000 + p.Tips
		top = insertRank(top, scoredPost{p: p, score: score}, limit)
	}
	out := make([]Article, len(top))
	for i, row := range top {
		out[i] = *row.p
	}
	return out
}

// MemberCount is the number of registered handles.
func MemberCount() int { return state.byHandle.Size() }

// FeedCount is the number of live top-level posts still in the feed index.
func FeedCount() int { return state.feed.Size() }

// LatestID is the newest post id, or 0 when nothing has been posted.
func LatestID() int {
	if state.nextID <= 1 {
		return 0
	}
	return state.nextID - 1
}

// Sheet is the stable text board the website reads.
// kind selects the page. a, b, and c are cursors or decimal limits.
// Gated bodies are left empty. Chain storage still holds them.
func Sheet(kind, a, b, c string) string {
	var body string
	switch kind {
	case "feed":
		body = sheetPosts(Feed(atoiOpt(a), atoiLimit(b)), false)
	case "author":
		p := lookup(a)
		if p == nil {
			panic("unknown handle")
		}
		body = sheetPosts(PostsBy(p.Addr, atoiOpt(b), atoiLimit(c)), false)
	case "replies":
		body = sheetPosts(Replies(atoiReq(a), atoiOpt(b), atoiLimit(c)), true)
	case "post":
		body = sheetOne(atoiReq(a))
	case "people":
		body = sheetProfiles(Handles(a, atoiLimit(b)))
	case "profile":
		body = sheetProfile(a)
	case "account":
		body = sheetAccount(a)
	case "hot":
		body = sheetPosts(Hot(atoiLimit(a)), false)
	case "followfeed":
		body = sheetFollowFeed(a, atoiLimit(b))
	case "graph":
		body = sheetProfiles(FollowingList(mustAddr(a), optAddr(b), atoiLimit(c)))
	case "fans":
		body = sheetProfiles(FollowerList(mustAddr(a), optAddr(b), atoiLimit(c)))
	case "holdings":
		body = sheetHoldings(Holdings(mustAddr(a), optAddr(b), atoiLimit(c)))
	case "meta":
		body = sheetMeta()
	case "quotebuy":
		due, curve, cf, pf, rf := QuoteBuy(a, atoiReq(b))
		body = join5(due, curve, cf, pf, rf)
	case "quotesell":
		proceeds, curve, cf, pf, rf := QuoteSell(a, atoiReq(b))
		body = join5(proceeds, curve, cf, pf, rf)
	case "shares":
		body = strconv.Itoa(SharesOf(mustAddr(a), b))
	default:
		panic("kind")
	}
	return "v1\n" + body
}

func sheetPosts(posts []Article, full bool) string {
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
	p := postByID(id)
	if p == nil {
		return ""
	}
	return postLine(*p)
}

func sheetProfile(handle string) string {
	p := lookup(handle)
	if p == nil {
		return ""
	}
	return profileLine(*p)
}

func sheetAccount(raw string) string {
	who := optAddr(raw)
	if !who.IsValid() {
		return ""
	}
	p := profileByAddr(who)
	if p == nil {
		return ""
	}
	return profileLine(*p)
}

func sheetProfiles(rows []Profile) string {
	var b strings.Builder
	for i, p := range rows {
		if i > 0 {
			b.WriteString("\n")
		}
		b.WriteString(p.Handle + "\t" + esc(p.Name) + "\t" + strconv.Itoa(p.Followers) + "\t" + strconv.Itoa(p.Posts))
	}
	return b.String()
}

func sheetHoldings(rows []Holding) string {
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
	posts := Feed(0, limit)
	var b strings.Builder
	n := 0
	for _, p := range posts {
		if !state.follows.Has(followKey(who, p.Author)) {
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
	if state.paused {
		paused = "1"
	}
	return strings.Join([]string{
		Version(),
		state.successor,
		paused,
		strconv.FormatInt(state.totalReserve, 10),
		state.admin.String(),
		state.treasury.String(),
		strconv.Itoa(MemberCount()),
		strconv.Itoa(FeedCount()),
		strconv.Itoa(LatestID()),
	}, "\t")
}

func profileLine(p Profile) string {
	supply, reserve, holders := SupplyOf(p.Handle)
	next := "-1"
	if supply < MaxSupply {
		due, _, _, _, _ := QuoteBuy(p.Handle, 1)
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
	}, "\t")
}

func cardLine(p Article) string {
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

func postLine(p Article) string {
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
	handle = handleOf(a)
	name = handle
	if p := profileByAddr(a); p != nil {
		name = p.Name
	}
	return
}

func openPreview(p Article) string {
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
	return mustLimit(n)
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
