package gnocial

import (
	"std"
	"strings"
)

type Post struct {
	Author  std.Address
	Content string
	Time    int64
}

type DirectMessage struct {
	Sender   std.Address
	Receiver std.Address
	Content  string
	Time     int64
}

var posts []Post
var directMessages []DirectMessage

func CreatePost(content string) {
	newPost := Post{
		Author:  std.GetOrigCaller(),
		Content: content,
		Time:    std.GetBlock().Time,
	}
	posts = append(posts, newPost)
}

func SendDirectMessage(receiver std.Address, content string) {
	newDM := DirectMessage{
		Sender:   std.GetOrigCaller(),
		Receiver: receiver,
		Content:  content,
		Time:     std.GetBlock().Time,
	}
	directMessages = append(directMessages, newDM)
}

func Render(path string) string {
	parts := strings.Split(path, "/")
	switch parts[0] {
	case "posts":
		return renderPosts()
	case "dms":
		return renderDMs()
	default:
		return "Welcome to GnoSocial! Use /posts to view all posts or /dms to view your messages."
	}
}

func renderPosts() string {
	var output strings.Builder
	output.WriteString("<h1>All Posts</h1>")
	for _, post := range posts {
		output.WriteString("<div>")
		output.WriteString(fmt.Sprintf("<p><a href='/user/%s'>%s</a>: %s</p>", post.Author, post.Author, post.Content))
		output.WriteString(fmt.Sprintf("<small>Posted at: %s</small>", time.Unix(post.Time, 0).String()))
		output.WriteString("</div><hr>")
	}
	return output.String()
}

func renderDMs() string {
	var output strings.Builder
	output.WriteString("<h1>Your Direct Messages</h1>")
	caller := std.GetOrigCaller()
	for _, dm := range directMessages {
		if dm.Sender == caller || dm.Receiver == caller {
			output.WriteString("<div>")
			output.WriteString(fmt.Sprintf("<p>From: <a href='/user/%s'>%s</a> To: <a href='/user/%s'>%s</a></p>", dm.Sender, dm.Sender, dm.Receiver, dm.Receiver))
			output.WriteString(fmt.Sprintf("<p>Message: %s</p>", dm.Content))
			output.WriteString(fmt.Sprintf("<small>Sent at: %s</small>", time.Unix(dm.Time, 0).String()))
			output.WriteString("</div><hr>")
		}
	}
	return output.String()
}
