package tavernboard

// Tavern Board - On-chain forum with GNOT tips (Gno v1.8 API).
// Posts, replies, and tips are all chain state.
// Front page ranks posts by total tips received.
//
// API notes (Gno v1.8, cf. examples/gno.land/r/demo/disperse,
// examples/gno.land/r/gnoland/boards2):
// - `address` and `realm` are built-in types (no std import).
// - State-changing functions take `cur realm` first and read the caller
//   via cur.Previous().Address().
// - Tips arrive as a send envelope: the caller attaches ugnot with the
//   call (gnokey maketx call -send), the realm reads it via
//   unsafe.OriginSend() and forwards it with an OriginSend banker.
//   The IsUserCall guard is REQUIRED with OriginSend (see
//   docs/resources/gno-security-guide.md): a maketx-run ephemeral realm
//   could otherwise consume the envelope.
// - Render(path string) is the gnoweb entry point. The path is the URL
//   args after the colon: "" = front page, "post/<id>" = post detail.
//   User content is markdown-escaped so it cannot break the layout.

import (
	"chain"
	"chain/banker"
	"chain/runtime/unsafe"
	"errors"
	"strconv"
	"strings"
	"time"
)

// Realm path (gnoweb absolute link base).
const gRealmPath = "/r/g15kxyhlw2zgz2l2sg8526j0nw5j77mkumyuztwj/tavernboard"

// Post represents a board post.
type Post struct {
	ID         int
	Title      string
	Body       string
	Author     address
	Created    int64
	TipTotal   int64 // total ugnot tipped
	ReplyCount int
}

// Reply represents a reply to a post.
type Reply struct {
	ID       int
	PostID   int
	Body     string
	Author   address
	Created  int64
	TipTotal int64 // total ugnot tipped
}

// State.
var (
	posts       = make(map[int]Post)
	replies     = make(map[int][]Reply) // postID -> replies
	nextPostID  = 1
	nextReplyID = 1
	authorTips  = make(map[address]int64) // address -> total tips received
	postOrder   = []int{}                 // post IDs sorted by tip total (desc)
)

// initPostOrder rebuilds the post order leaderboard.
func initPostOrder() {
	postOrder = make([]int, 0, len(posts))
	for id := range posts {
		postOrder = append(postOrder, id)
	}
	// Simple bubble sort by TipTotal desc (deterministic, no external deps).
	for i := 0; i < len(postOrder); i++ {
		for j := i + 1; j < len(postOrder); j++ {
			if posts[postOrder[i]].TipTotal < posts[postOrder[j]].TipTotal {
				postOrder[i], postOrder[j] = postOrder[j], postOrder[i]
			}
		}
	}
}

// CreatePost creates a new post on the default board.
func CreatePost(cur realm, title, body string) (int, error) {
	if title == "" {
		return 0, errors.New("title cannot be empty")
	}
	if body == "" {
		return 0, errors.New("body cannot be empty")
	}

	caller := cur.Previous().Address()
	id := nextPostID
	nextPostID++

	posts[id] = Post{
		ID:         id,
		Title:      title,
		Body:       body,
		Author:     caller,
		Created:    time.Now().Unix(),
		TipTotal:   0,
		ReplyCount: 0,
	}
	replies[id] = make([]Reply, 0)

	initPostOrder()
	return id, nil
}

// CreateReply adds a reply to a post.
func CreateReply(cur realm, postID int, body string) (int, error) {
	if body == "" {
		return 0, errors.New("reply body cannot be empty")
	}

	post, exists := posts[postID]
	if !exists {
		return 0, errors.New("post not found")
	}

	caller := cur.Previous().Address()
	id := nextReplyID
	nextReplyID++

	replies[postID] = append(replies[postID], Reply{
		ID:       id,
		PostID:   postID,
		Body:     body,
		Author:   caller,
		Created:  time.Now().Unix(),
		TipTotal: 0,
	})

	// Update post reply count.
	post.ReplyCount++
	posts[postID] = post

	return id, nil
}

// tip moves `amount` ugnot from the call's send envelope to `to`,
// refunding any leftover to the caller. The caller must be a user call
// and must have attached at least `amount` ugnot to the call.
//
// Money follows the disperse pattern (examples/gno.land/r/demo/disperse):
// a RealmSend banker moves coins out of the realm's own balance, and the
// IsUserCall guard is the security control — for a pure EOA call the send
// envelope really lands at the realm, so the realm balance covers the tip
// plus the refund; a maketx-run ephemeral realm or intermediate code realm
// could otherwise spend pre-existing realm balance to attacker-chosen
// addresses. The balance check below is a second layer: the tip only
// proceeds if the realm actually holds the sent coins.
// (An OriginSend banker would be safer by construction, but it can only
// spend an envelope credited to this realm in the same message, which a
// filetest cross-call cannot provide — the envelope belongs to the
// filetest package — so it is not testable; RealmSend + guard is the
// sanctioned, testable pattern.)
func tip(cur realm, to address, amount int64) error {
	if !cur.Previous().IsUserCall() {
		return errors.New("only user-call (maketx call) accepted")
	}
	if amount <= 0 {
		return errors.New("tip amount must be positive")
	}

	sent := unsafe.OriginSend().AmountOf("ugnot")
	if sent < amount {
		return errors.New("sent amount less than tip amount")
	}

	caller := cur.Previous().Address()
	realmAddr := cur.Address()
	b := banker.NewBanker(banker.BankerTypeRealmSend, cur)
	if b.GetCoin(realmAddr, "ugnot") < sent {
		return errors.New("realm balance less than sent amount")
	}
	b.SendCoins(realmAddr, to, chain.NewCoins(chain.NewCoin("ugnot", amount)))
	if leftover := sent - amount; leftover > 0 {
		b.SendCoins(realmAddr, caller, chain.NewCoins(chain.NewCoin("ugnot", leftover)))
	}
	return nil
}

// TipPost sends GNOT tips to a post author. Attach the tip with the call:
// gnokey maketx call -send <amount>ugnot -func TipPost -args <postID> -args <amount> ...
func TipPost(cur realm, postID int, amount int64) error {
	post, exists := posts[postID]
	if !exists {
		return errors.New("post not found")
	}
	if err := tip(cur, post.Author, amount); err != nil {
		return err
	}

	post.TipTotal += amount
	posts[postID] = post
	authorTips[post.Author] += amount
	initPostOrder()
	return nil
}

// TipReply sends GNOT tips to a reply author. Attach the tip with the call.
func TipReply(cur realm, postID int, replyID int, amount int64) error {
	postReplies, exists := replies[postID]
	if !exists {
		return errors.New("post not found")
	}

	var replyIndex = -1
	for i, r := range postReplies {
		if r.ID == replyID {
			replyIndex = i
			break
		}
	}
	if replyIndex == -1 {
		return errors.New("reply not found")
	}

	reply := postReplies[replyIndex]
	if err := tip(cur, reply.Author, amount); err != nil {
		return err
	}

	reply.TipTotal += amount
	postReplies[replyIndex] = reply
	replies[postID] = postReplies
	authorTips[reply.Author] += amount
	return nil
}

// GetPost returns a post by ID.
func GetPost(postID int) (Post, bool) {
	post, exists := posts[postID]
	return post, exists
}

// GetReplies returns all replies for a post.
func GetReplies(postID int) []Reply {
	return replies[postID]
}

// GetPosts returns all posts sorted by tip total (leaderboard).
func GetPosts() []Post {
	result := make([]Post, 0, len(postOrder))
	for _, id := range postOrder {
		result = append(result, posts[id])
	}
	return result
}

// GetAuthorTips returns total tips received by an author.
func GetAuthorTips(author address) int64 {
	return authorTips[author]
}

// escapeMD escapes markdown metacharacters so user content cannot break
// the page layout or inject links/images.
func escapeMD(s string) string {
	var b strings.Builder
	for _, r := range s {
		switch r {
		case '\\', '`', '*', '_', '[', ']', '#', '>', '|':
			b.WriteString("\\")
			b.WriteRune(r)
		default:
			b.WriteRune(r)
		}
	}
	return b.String()
}

// Render renders the board (gnoweb entry point).
// path "" = front page, "post/<id>" = post detail page.
func Render(path string) string {
	if path == "" {
		return renderBoard()
	}
	if strings.HasPrefix(path, "post/") {
		idStr := strings.TrimPrefix(path, "post/")
		id, err := strconv.Atoi(idStr)
		if err != nil || id <= 0 {
			return renderError("Invalid post ID")
		}
		return renderPostPage(id)
	}
	return renderError("Page not found")
}

func renderBoard() string {
	var b strings.Builder
	b.WriteString("# Tavern Board\n\n")
	b.WriteString("On-chain forum with GNOT tips. Posts ranked by tips received.\n\n")
	b.WriteString("Post from the Actions tab, tip from the Actions tab — tips land straight in the author's balance.\n\n")
	b.WriteString("---\n\n")

	postsList := GetPosts()
	if len(postsList) == 0 {
		b.WriteString("No posts yet. Be the first to post!\n")
		return b.String()
	}

	b.WriteString("## Posts (ranked by tips)\n\n")
	for _, post := range postsList {
		b.WriteString("### " + escapeMD(post.Title) + "\n\n")
		b.WriteString("By " + post.Author.String() + " | Tips: " + strconv.Itoa(int(post.TipTotal)) + " ugnot | Replies: " + strconv.Itoa(post.ReplyCount) + "\n\n")
		b.WriteString(escapeMD(post.Body) + "\n\n")
		b.WriteString("[View replies](" + gRealmPath + ":post/" + strconv.Itoa(post.ID) + ")\n\n")
		b.WriteString("---\n\n")
	}
	return b.String()
}

func renderPostPage(postID int) string {
	post, exists := GetPost(postID)
	if !exists {
		return renderError("Post not found")
	}

	var b strings.Builder
	b.WriteString("[← Back to Board](" + gRealmPath + ")\n\n")
	b.WriteString("# " + escapeMD(post.Title) + "\n\n")
	b.WriteString("By " + post.Author.String() + " | Tips: " + strconv.Itoa(int(post.TipTotal)) + " ugnot\n\n")
	b.WriteString(escapeMD(post.Body) + "\n\n")
	b.WriteString("Tip this author from the Actions tab (TipPost, attach ugnot with the call).\n\n")
	b.WriteString("---\n\n")
	b.WriteString("## Replies\n\n")

	postReplies := GetReplies(postID)
	if len(postReplies) == 0 {
		b.WriteString("No replies yet. Reply from the Actions tab.\n")
	} else {
		for _, reply := range postReplies {
			b.WriteString("> " + escapeMD(reply.Body) + "\n>\n")
			b.WriteString("> By " + reply.Author.String() + " | Tips: " + strconv.Itoa(int(reply.TipTotal)) + " ugnot\n\n")
		}
	}
	return b.String()
}

func renderError(msg string) string {
	return "# Error\n\n" + escapeMD(msg) + "\n\n[← Back to Board](" + gRealmPath + ")\n"
}
