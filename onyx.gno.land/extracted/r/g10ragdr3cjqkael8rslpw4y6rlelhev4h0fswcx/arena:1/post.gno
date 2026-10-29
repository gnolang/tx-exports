package arena

import (
	"chain"
	"chain/runtime"
	"math/overflow"
	"strconv"
)

// Post publishes a top-level post and returns its id.
// gated is yes/1/true/khoa to withhold the body from Render.
// The body is still public chain state. Pass an empty gated value for a public post.
func Post(cur realm, body, gated string) int {
	who := caller(cur)
	mustNoPay()
	if state.paused {
		panic("paused")
	}
	author := mustMember(who)
	return writePost(author, 0, body, isYes(gated))
}

// Reply publishes a reply to parent and returns the new id. Replies are public.
func Reply(cur realm, parent int, body string) int {
	who := caller(cur)
	mustNoPay()
	if state.paused {
		panic("paused")
	}
	author := mustMember(who)
	target := postByID(parent)
	if target == nil {
		panic("unknown post")
	}
	if target.Deleted {
		panic("deleted")
	}
	id := writePost(author, parent, body, false)
	target.Replies++
	state.replies.Set(pad(parent)+"/"+pad(id), id)
	return id
}

func writePost(author *Profile, parent int, body string, gated bool) int {
	body = cleanBody(body)
	id := state.nextID
	state.nextID++
	p := &Article{
		ID:      id,
		Author:  author.Addr,
		Body:    body,
		Height:  runtime.ChainHeight(),
		ReplyTo: parent,
		Gated:   gated,
	}
	state.posts.Set(pad(id), p)
	if parent == 0 {
		author.Posts++
		state.feed.Set(pad(id), id)
		state.byAuthor.Set(authorKey(author.Addr, id), id)
		chain.Emit(
			"ArenaPost",
			"id", strconv.Itoa(id),
			"author", author.Addr.String(),
			"handle", author.Handle,
			"gated", yesNo(gated),
		)
	} else {
		chain.Emit(
			"ArenaReply",
			"id", strconv.Itoa(id),
			"parent", strconv.Itoa(parent),
			"author", author.Addr.String(),
			"handle", author.Handle,
		)
	}
	return id
}

func yesNo(v bool) string {
	if v {
		return "yes"
	}
	return "no"
}

// Delete soft-deletes the caller's post and clears its body from current state.
// The original transaction still holds the text in chain history.
func Delete(cur realm, id int) {
	who := caller(cur)
	mustNoPay()
	mustMember(who)
	p := postByID(id)
	if p == nil {
		panic("unknown post")
	}
	if p.Deleted {
		panic("deleted")
	}
	if p.Author != who {
		panic("author only")
	}
	if p.ReplyTo == 0 {
		state.feed.Remove(pad(id))
		state.byAuthor.Remove(authorKey(who, id))
		if author := profileByAddr(who); author != nil && author.Posts > 0 {
			author.Posts--
		}
	} else {
		state.replies.Remove(pad(p.ReplyTo) + "/" + pad(id))
		if parent := postByID(p.ReplyTo); parent != nil && parent.Replies > 0 {
			parent.Replies--
		}
	}
	p.Deleted = true
	p.Body = ""
	p.Gated = false
	chain.Emit("ArenaDelete", "id", strconv.Itoa(id), "author", who.String())
}

// Like adds the caller's like. One like per account.
func Like(cur realm, id int) {
	who := caller(cur)
	mustNoPay()
	mustMember(who)
	p := livePost(id)
	k := likeKey(id, who)
	if state.likes.Has(k) {
		panic("already liked")
	}
	state.likes.Set(k, 1)
	p.Likes++
	chain.Emit("ArenaLike", "id", strconv.Itoa(id), "from", who.String())
}

// Unlike removes the caller's like.
func Unlike(cur realm, id int) {
	who := caller(cur)
	mustNoPay()
	mustMember(who)
	p := livePost(id)
	k := likeKey(id, who)
	if !state.likes.Has(k) {
		panic("not liked")
	}
	state.likes.Remove(k)
	if p.Likes > 0 {
		p.Likes--
	}
	chain.Emit("ArenaUnlike", "id", strconv.Itoa(id), "from", who.String())
}

// Tip forwards the attached ugnot to the post's author. The realm does not keep it.
func Tip(cur realm, id int) {
	who := caller(cur)
	if state.paused {
		panic("paused")
	}
	mustMember(who)
	sent := takeUgnot(cur)
	p := livePost(id)
	author := profileByAddr(p.Author)
	if author == nil {
		panic("register first")
	}
	p.Tips = overflow.Add64p(p.Tips, sent)
	author.TipsIn = overflow.Add64p(author.TipsIn, sent)
	if self := profileByAddr(who); self != nil {
		self.TipsOut = overflow.Add64p(self.TipsOut, sent)
	}
	payout(cur, p.Author, sent, "author")
	chain.Emit(
		"ArenaTip",
		"id", strconv.Itoa(id),
		"from", who.String(),
		"to", p.Author.String(),
		"ugnot", strconv.FormatInt(sent, 10),
	)
}

// GatedBody returns a gated post's text for the author or a current ticket holder.
// Chain storage is public; this only gates the convenience call and Render.
func GatedBody(cur realm, id int) string {
	who := caller(cur)
	mustNoPay()
	mustMember(who)
	p := livePost(id)
	if !p.Gated {
		return p.Body
	}
	if p.Author != who && getShares(who, p.Author) < 1 {
		panic("need a ticket")
	}
	return p.Body
}

func livePost(id int) *Article {
	p := postByID(id)
	if p == nil {
		panic("unknown post")
	}
	if p.Deleted {
		panic("deleted")
	}
	return p
}

// Liked reports whether who liked the post.
func Liked(who address, id int) bool {
	if id <= 0 {
		return false
	}
	return state.likes.Has(likeKey(id, who))
}
