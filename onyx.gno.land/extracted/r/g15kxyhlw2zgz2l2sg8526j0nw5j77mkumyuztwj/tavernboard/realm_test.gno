package tavernboard

// Unit tests for Tavern Board (Gno v1.8 API).
//
// In _test.gno the only crossable realm is the test frame's own `cur`,
// whose Previous() is the test package realm (a code realm, NOT a user
// call). So these tests cover CreatePost/CreateReply/Render and the
// validation paths. The tip flows (which REQUIRE a user caller for the
// OriginSend guard) are covered by the filetest in
// filetests/z_tip_filetest.gno, where testing.SetRealm works the way the
// boards filetests use it.
//
// Note: realm state is shared across tests in a package run, so tests use
// returned IDs and assert relative order, never absolute IDs or empty state.

import (
	"chain"
	"strconv"
	"strings"
	"testing"
)

// pkgAddr is the test caller: the package address of this realm.
// (In _test.gno, cross(cur) makes Previous() the test package realm.)
var pkgAddr = chain.PackageAddress("gno.land/r/g15kxyhlw2zgz2l2sg8526j0nw5j77mkumyuztwj/tavernboard")

func TestCreatePost(cur realm, t *testing.T) {
	id, err := CreatePost(cross(cur), "Hello Tavern", "First post body")
	if err != nil {
		t.Fatalf("CreatePost failed: %v", err)
	}
	if id <= 0 {
		t.Fatalf("CreatePost returned bad id %d", id)
	}
	post, ok := GetPost(id)
	if !ok {
		t.Fatalf("GetPost(%d) not found after create", id)
	}
	if post.Title != "Hello Tavern" {
		t.Fatalf("title %q != %q", post.Title, "Hello Tavern")
	}
	if post.Body != "First post body" {
		t.Fatalf("body %q != %q", post.Body, "First post body")
	}
	if post.Author != pkgAddr {
		t.Fatalf("author %v != %v", post.Author, pkgAddr)
	}
	if post.TipTotal != 0 {
		t.Fatalf("new post TipTotal %d != 0", post.TipTotal)
	}
	if post.ReplyCount != 0 {
		t.Fatalf("new post ReplyCount %d != 0", post.ReplyCount)
	}
}

func TestCreatePostValidation(cur realm, t *testing.T) {
	if _, err := CreatePost(cross(cur), "", "body"); err == nil {
		t.Fatalf("empty title should fail")
	}
	if _, err := CreatePost(cross(cur), "title", ""); err == nil {
		t.Fatalf("empty body should fail")
	}
}

func TestCreateReply(cur realm, t *testing.T) {
	postID, err := CreatePost(cross(cur), "Reply target", "Post for replies")
	if err != nil {
		t.Fatalf("CreatePost failed: %v", err)
	}
	replyID, err := CreateReply(cross(cur), postID, "First reply")
	if err != nil {
		t.Fatalf("CreateReply failed: %v", err)
	}
	if replyID <= 0 {
		t.Fatalf("CreateReply returned bad id %d", replyID)
	}
	post, _ := GetPost(postID)
	if post.ReplyCount != 1 {
		t.Fatalf("ReplyCount %d != 1", post.ReplyCount)
	}
	replies := GetReplies(postID)
	if len(replies) != 1 {
		t.Fatalf("GetReplies len %d != 1", len(replies))
	}
	if replies[0].Body != "First reply" {
		t.Fatalf("reply body %q != %q", replies[0].Body, "First reply")
	}
	if replies[0].Author != post.Author {
		t.Fatalf("reply author %v != post author %v", replies[0].Author, post.Author)
	}
	if replies[0].TipTotal != 0 {
		t.Fatalf("new reply TipTotal %d != 0", replies[0].TipTotal)
	}
}

func TestCreateReplyValidation(cur realm, t *testing.T) {
	if _, err := CreateReply(cross(cur), 999999, "nope"); err == nil {
		t.Fatalf("reply to missing post should fail")
	}
	postID, err := CreatePost(cross(cur), "Empty reply target", "body")
	if err != nil {
		t.Fatalf("CreatePost failed: %v", err)
	}
	if _, err := CreateReply(cross(cur), postID, ""); err == nil {
		t.Fatalf("empty reply body should fail")
	}
}

func TestRenderBoard(cur realm, t *testing.T) {
	id, err := CreatePost(cross(cur), "Render me", "Render body")
	if err != nil {
		t.Fatalf("CreatePost failed: %v", err)
	}
	res := Render("")
	if !strings.Contains(res, "# Tavern Board") {
		t.Fatalf("board render missing title: %q", res)
	}
	if !strings.Contains(res, "Render me") {
		t.Fatalf("board render missing post title: %q", res)
	}
	if !strings.Contains(res, "post/"+strconv.Itoa(id)) {
		t.Fatalf("board render missing post link: %q", res)
	}
}

func TestRenderPost(cur realm, t *testing.T) {
	id, err := CreatePost(cross(cur), "Detail title", "Detail body text")
	if err != nil {
		t.Fatalf("CreatePost failed: %v", err)
	}
	res := Render("post/" + strconv.Itoa(id))
	if !strings.Contains(res, "Detail title") {
		t.Fatalf("post render missing title: %q", res)
	}
	if !strings.Contains(res, "Detail body text") {
		t.Fatalf("post render missing body: %q", res)
	}
	if !strings.Contains(res, "Back to Board") {
		t.Fatalf("post render missing back link: %q", res)
	}
}

func TestRenderErrors(t *testing.T) {
	if res := Render("post/abc"); !strings.Contains(res, "Invalid post ID") {
		t.Fatalf("bad id render wrong: %q", res)
	}
	if res := Render("post/999999"); !strings.Contains(res, "Post not found") {
		t.Fatalf("missing post render wrong: %q", res)
	}
	if res := Render("unknown/path"); !strings.Contains(res, "Page not found") {
		t.Fatalf("unknown path render wrong: %q", res)
	}
}

func TestRenderEscapesUserContent(cur realm, t *testing.T) {
	id, err := CreatePost(cross(cur), "Title *with* [markdown]", "Body with `code` and # hash")
	if err != nil {
		t.Fatalf("CreatePost failed: %v", err)
	}
	res := Render("post/" + strconv.Itoa(id))
	if strings.Contains(res, "Title *with*") {
		t.Fatalf("title markdown not escaped: %q", res)
	}
	if strings.Contains(res, "`code`") {
		t.Fatalf("body markdown not escaped: %q", res)
	}
}
