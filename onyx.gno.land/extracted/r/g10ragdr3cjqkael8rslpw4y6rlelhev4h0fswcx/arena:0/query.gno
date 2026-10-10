package arena

import (
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

const hotWindow = 30

type scoredPost struct {
	p     *Article
	score int64
}

func insertRank(top []scoredPost, row scoredPost, limit int) []scoredPost {
	if len(top) == limit && row.score <= top[len(top)-1].score {
		return top
	}
	top = append(top, row)
	for i := len(top) - 1; i > 0; i-- {
		if top[i].score <= top[i-1].score {
			break
		}
		top[i], top[i-1] = top[i-1], top[i]
	}
	if len(top) > limit {
		top = top[:limit]
	}
	return top
}

func recentPosts(before, limit int) []*Article {
	end := ""
	if before > 0 {
		end = pad(before)
	}
	out := make([]*Article, 0, limit)
	state.feed.ReverseIterate("", end, func(key string, value any) bool {
		id, ok := value.(int)
		if !ok {
			panic("feed type")
		}
		if before > 0 && id >= before {
			return false
		}
		p := postByID(id)
		if p == nil || p.Deleted || p.ReplyTo != 0 {
			return false
		}
		out = append(out, p)
		return len(out) >= limit
	})
	return out
}
