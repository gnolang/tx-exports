package blog

import (
	"strings"
	"testing"
)

func TestBlog(cur realm, t *testing.T) {
	posts = nil
	postID := CreatePost(cross(cur), "Hello PERUN")
	if postID != 1 {
		t.Fatalf("expected post ID 1, got %d", postID)
	}
	replyID := ReplyToPost(cross(cur), postID, "Hello back")
	if replyID != 1 {
		t.Fatalf("expected reply ID 1, got %d", replyID)
	}
	got := Render("")
	if !strings.Contains(got, "Hello PERUN") || !strings.Contains(got, "Hello back") {
		t.Fatalf("rendered blog does not contain the post and reply")
	}
}

func TestBlogIsChronological(cur realm, t *testing.T) {
	posts = nil
	CreatePost(cross(cur), "first")
	CreatePost(cross(cur), "second")
	got := Render("")
	if strings.Index(got, "first") >= strings.Index(got, "second") {
		t.Fatalf("posts are not rendered oldest first")
	}
}
