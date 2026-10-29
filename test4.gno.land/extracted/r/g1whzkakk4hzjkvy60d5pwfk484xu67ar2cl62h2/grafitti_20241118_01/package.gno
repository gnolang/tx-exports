package grafitti_20241118_01

import "gno.land/p/demo/ufmt"
import "strings"
import "std"

type Post struct {
	Author  std.Address
	Content string
}
var posts []Post

func CreatePost(content string) {
	newPost := Post{
		Author:  std.GetOrigCaller(),
		Content: content,
	}
	posts = append(posts, newPost)
}

func Render(path string) string {
	var output strings.Builder
	for _, post := range posts {
		output.WriteString(ufmt.Sprintf("* %s: %s", post.Author, post.Content))
	}
	return output.String()
}