package gnocial7

import (
	"gno.land/p/demo/ufmt"
	"std"
	"strings"
	"time"
)

type Post struct {
	Author  std.Address
	Content string
	Time    time.Time
}

type DirectMessage struct {
	Sender   std.Address
	Receiver std.Address
	Content  string
	Time     time.Time
}

var posts []Post
var directMessages []DirectMessage

func CreatePost(content string) {
	newPost := Post{
		Author:  std.GetOrigCaller(),
		Content: content,
		Time:    time.Now(),
	}
	posts = append(posts, newPost)
}

func SendDirectMessage(receiver std.Address, content string) {
	newDM := DirectMessage{
		Sender:   std.GetOrigCaller(),
		Receiver: receiver,
		Content:  content,
		Time:     time.Now(),
	}
	directMessages = append(directMessages, newDM)
}

func Render(path string) string {
    command := ""
    if idx := strings.Index(path, "/"); idx >= 0 {
        command = path[idx+1:]
    }

	switch command {
	case "posts":
		return renderPosts()
	case "dms":
		return renderDMs(std.GetOrigCaller())
	default:
		return "Welcome to GnoSocial! Use /posts to view all posts or /dms to view your messages.\n"
	}
}


func renderPosts() string {
	var output strings.Builder
	output.WriteString("<h1>All Posts</h1>")
	for _, post := range posts {
		output.WriteString("<div>")
		output.WriteString(ufmt.Sprintf("<p><a href='/user/%s'>%s</a>: %s</p>", post.Author, post.Author, post.Content))
		output.WriteString(ufmt.Sprintf("<small>Posted at: %s</small>", post.Time.String()))
		output.WriteString("</div><hr>")
	}
	return output.String()
}

func renderDMs(caller std.Address) string {
	var output strings.Builder
	output.WriteString("<h1>Your Direct Messages</h1>")
	for _, dm := range directMessages {
        output.WriteString(ufmt.Sprintf("#-- %s / %s / %s / %t", dm.Sender, dm.Receiver, caller, dm.Sender == caller))
		if dm.Sender == caller || dm.Receiver == caller {
			output.WriteString("<div>")
			output.WriteString(ufmt.Sprintf("<p>From: <a href='/user/%s'>%s</a> To: <a href='/user/%s'>%s</a></p>", dm.Sender, dm.Sender, dm.Receiver, dm.Receiver))
			output.WriteString(ufmt.Sprintf("<p>Message: %s</p>", dm.Content))
			output.WriteString(ufmt.Sprintf("<small>Sent at: %s</small>", dm.Time.String()))
			output.WriteString("</div><hr>")
		}
	}
	return output.String()
}
