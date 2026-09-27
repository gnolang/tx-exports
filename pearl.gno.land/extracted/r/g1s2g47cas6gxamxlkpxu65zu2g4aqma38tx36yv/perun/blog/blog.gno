package blog

import (
	"chain/runtime/unsafe"
	"strconv"
	"strings"
	"time"

	"gno.land/p/nt/markdown/sanitize/v0"
)

const maxPostLength = 280

type Reply struct {
	ID        int
	Author    string
	Body      string
	CreatedAt time.Time
}

type Post struct {
	ID        int
	Author    string
	Body      string
	CreatedAt time.Time
	Replies   []Reply
}

var posts []Post

func CreatePost(_ realm, body string) int {
	body = validateBody(body)
	id := len(posts) + 1
	posts = append(posts, Post{ID: id, Author: unsafe.OriginCaller().String(), Body: body, CreatedAt: time.Now()})
	return id
}

func ReplyToPost(_ realm, postID int, body string) int {
	body = validateBody(body)
	if postID < 1 || postID > len(posts) {
		panic("post does not exist")
	}
	post := &posts[postID-1]
	replyID := len(post.Replies) + 1
	post.Replies = append(post.Replies, Reply{ID: replyID, Author: unsafe.OriginCaller().String(), Body: body, CreatedAt: time.Now()})
	return replyID
}

func validateBody(body string) string {
	body = strings.TrimSpace(body)
	if body == "" {
		panic("post cannot be empty")
	}
	if characterCount(body) > maxPostLength {
		panic("post is longer than 280 characters")
	}
	return body
}

func characterCount(s string) int {
	count := 0
	for range s {
		count++
	}
	return count
}

func perunURL() string {
	return strings.TrimSuffix(strings.TrimPrefix(unsafe.CurrentRealm().PkgPath(), "gno.land"), "/blog")
}

func blogURL() string {
	return strings.TrimPrefix(unsafe.CurrentRealm().PkgPath(), "gno.land")
}

func createPostURL() string {
	return blogURL() + "$help&func=CreatePost"
}

func replyURL(postID int) string {
	return blogURL() + "$help&func=ReplyToPost&postID=" + strconv.Itoa(postID)
}

func Render(_ string) string {
	var out strings.Builder
	out.WriteString("# ⚡ PERUN Blog\n\n")
	out.WriteString("A public, on-chain feed. Posts and replies are shown oldest first.\n\n")
	out.WriteString("[← PERUN home](" + perunURL() + ") · [Create a post](" + createPostURL() + ")\n\n---\n\n")
	if len(posts) == 0 {
		out.WriteString("No posts yet. Be the first to publish one.\n")
		return out.String()
	}
	for i := 0; i < len(posts); i++ {
		post := posts[i]
		out.WriteString("### Post #" + strconv.Itoa(post.ID) + "\n\n")
		out.WriteString("**" + sanitize.InlineText(post.Author) + "** · " + post.CreatedAt.UTC().Format("2006-01-02 15:04 UTC") + "\n")
		out.WriteString(sanitize.Block(post.Body))
		out.WriteString("[Reply](" + replyURL(post.ID) + ")\n\n")
		for j := 0; j < len(post.Replies); j++ {
			reply := post.Replies[j]
			out.WriteString("> **Reply #" + strconv.Itoa(reply.ID) + " — " + sanitize.InlineText(reply.Author) + "** · " + reply.CreatedAt.UTC().Format("2006-01-02 15:04 UTC") + "  \n")
			out.WriteString("> " + sanitize.InlineText(reply.Body) + "\n\n")
		}
		out.WriteString("---\n\n")
	}
	return out.String()
}
