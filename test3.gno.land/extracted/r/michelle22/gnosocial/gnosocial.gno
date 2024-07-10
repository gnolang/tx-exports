package gnosocial

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

// ... (rest of the code)
// Post your thoughts.
//
// Enter a post below, and then press the `Call` button.
//
// The post will be recorded along with your address for everyone else to read.
func CreatePost(content string) {
	newPost := Post{
		Author:  std.GetOrigCaller(),
		Content: content,
		Time:    time.Now(),
	}
	posts = append(posts, newPost)
}

// Talk with someone else! Enter their address, and the message that you want
// to send to them below, and then press the `Call` button.
func SendDirectMessage(receiver std.Address, content string) {
	newDM := DirectMessage{
		Sender:   std.GetOrigCaller(),
		Receiver: receiver,
		Content:  content,
		Time:     time.Now(),
	}
	directMessages = append(directMessages, newDM)
}

// Call this to see all of the current posts.
func RenderPosts() string {
	var output strings.Builder
	output.WriteString("# All Posts")
	for _, post := range posts {
		output.WriteString(ufmt.Sprintf("* %s @ %s: %s", post.Time.String(), post.Author, post.Content))
	}
	return output.String()
}

// Call this to see your messages.
func RenderDMs() string {
	var output strings.Builder
	caller := std.GetOrigCaller()

	if caller == "" {
		output.WriteString("* All Direct Messages")
	} else {
		output.WriteString("* Your Direct Messages")
	}

	for _, dm := range directMessages {
		if caller == "" || dm.Sender == caller || dm.Receiver == caller {
			output.WriteString(ufmt.Sprintf("* From: %s to: %s @ %s: %s", dm.Sender, dm.Receiver, dm.Time.String(), dm.Content))
		}
	}
	return output.String()
}

// Calling Render() with `/posts` will return an HTML string with all of the current posts.
// Calling Render() with `/dms` will return an HTML string with all of the current direct messages.
func Render(path string) string {
	command := ""
	if idx := strings.Index(path, "/"); idx >= 0 {
		command = path[idx+1:]
	}

	switch command {
	case "posts":
		return RenderPosts()
	case "dms":
		return RenderDMs()
	default:
		return "Welcome to GnoSocial! Use /posts to view all posts or /dms to view your messages."
	}
}
