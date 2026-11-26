package tavernboard

import (
	"strings"
	"testing"
)

// otherAuthor is a fixed second address used to seed messages from
// someone other than the test caller.
const otherAuthor = address("g1magld5ptgzaktqcexxq0pgq5lmdf0kz6re8hlv")

func resetBoard() {
	messages = nil
}

func mustPanic(t *testing.T, what string, fn func()) {
	t.Helper()
	defer func() {
		if recover() == nil {
			t.Fatalf("expected panic for %s, got none", what)
		}
	}()
	fn()
}

func TestPostMessage(cur realm, t *testing.T) {
	resetBoard()
	id := PostMessage(cross(cur), "  hello tavern  ")
	if id != 0 {
		t.Fatalf("first message id: got %d, want 0", id)
	}
	if MessageCount() != 1 {
		t.Fatalf("message count: got %d, want 1", MessageCount())
	}
	author, text, height, likes := GetMessage(0)
	// In tests the caller is the test realm itself, so the stored
	// author must be cur.Address(). On chain, a gnokey MsgCall makes
	// cur.Previous() the signing account instead.
	if author != cur.Address().String() {
		t.Fatalf("author: got %q, want caller %q", author, cur.Address().String())
	}
	if text != "hello tavern" {
		t.Fatalf("text should be trimmed: got %q", text)
	}
	if height < 0 {
		t.Fatalf("height should be non-negative: got %d", height)
	}
	if likes != 0 {
		t.Fatalf("likes: got %d, want 0", likes)
	}
	id2 := PostMessage(cross(cur), "second round")
	if id2 != 1 || MessageCount() != 2 {
		t.Fatalf("second post: id %d, count %d, want id 1 count 2", id2, MessageCount())
	}
}

func TestPostMessageRejectsBadText(cur realm, t *testing.T) {
	resetBoard()
	// Panics across a realm crossing abort the whole test run and
	// cannot be recovered, so the text rules are exercised through
	// the cleanText helper that PostMessage itself calls.
	mustPanic(t, "empty message", func() { cleanText("") })
	mustPanic(t, "blank message", func() { cleanText("   ") })
	tooLong := strings.Repeat("a", MaxMessageLen+1)
	mustPanic(t, "over-long message", func() { cleanText(tooLong) })
	if got := cleanText("  padded  "); got != "padded" {
		t.Fatalf("cleanText should trim: got %q", got)
	}
	exact := strings.Repeat("b", MaxMessageLen)
	if id := PostMessage(cross(cur), exact); id != 0 {
		t.Fatalf("max-length message should post with id 0, got %d", id)
	}
}

func TestLikeMessage(cur realm, t *testing.T) {
	resetBoard()
	PostMessage(cross(cur), "cheer me")
	who := cur.Address()
	if HasLiked(0, who) {
		t.Fatal("caller should not have liked before cheering")
	}
	n := LikeMessage(cross(cur), 0)
	if n != 1 {
		t.Fatalf("like count after first cheer: got %d, want 1", n)
	}
	if !HasLiked(0, who) {
		t.Fatal("caller should have liked after cheering")
	}
	_, _, _, likes := GetMessage(0)
	if likes != 1 {
		t.Fatalf("stored likes: got %d, want 1", likes)
	}
	// Repeat-cheer rejection is checked through checkCanLike, the
	// same guard LikeMessage runs before recording a cheer.
	mustPanic(t, "repeat cheer by same address", func() { checkCanLike(0, who) })
}

func TestLikeMessageOtherAuthor(cur realm, t *testing.T) {
	resetBoard()
	// Seed a message from a different author, then cheer it as the
	// test caller. This proves cheers are tracked per address.
	messages = append(messages, Message{
		Author:  otherAuthor,
		Text:    "posted by someone else",
		Height:  42,
		Likes:   0,
		LikedBy: map[address]bool{},
	})
	if HasLiked(0, otherAuthor) {
		t.Fatal("author should not count as having cheered their own post")
	}
	if n := LikeMessage(cross(cur), 0); n != 1 {
		t.Fatalf("cheering another author's post: got %d, want 1", n)
	}
	author, _, height, _ := GetMessage(0)
	if author != otherAuthor.String() || height != 42 {
		t.Fatalf("seeded fields changed: author %q height %d", author, height)
	}
}

func TestBadIDs(cur realm, t *testing.T) {
	resetBoard()
	PostMessage(cross(cur), "only post")
	// ID guards run inside LikeMessage, GetMessage, and HasLiked;
	// they are exercised here through checkID and checkCanLike
	// because crossing-call panics cannot be recovered in tests.
	mustPanic(t, "unknown id", func() { checkID(7) })
	mustPanic(t, "negative id", func() { checkID(-1) })
	mustPanic(t, "like unknown id", func() { checkCanLike(7, otherAuthor) })
	mustPanic(t, "get unknown id", func() { GetMessage(7) })
	mustPanic(t, "hasliked unknown id", func() { HasLiked(7, otherAuthor) })
}

func TestRender(cur realm, t *testing.T) {
	resetBoard()
	empty := Render("")
	if !strings.Contains(empty, "Total messages: 0") || !strings.Contains(empty, "No messages yet") {
		t.Fatalf("empty render missing expected text:\n%s", empty)
	}
	PostMessage(cross(cur), "first post here")
	PostMessage(cross(cur), "second post here")
	LikeMessage(cross(cur), 1)
	board := Render("")
	if !strings.Contains(board, "# TavernBoard") || !strings.Contains(board, "Total messages: 2") {
		t.Fatalf("board render missing header or count:\n%s", board)
	}
	// Newest first: the second post must appear before the first.
	iSecond := strings.Index(board, "second post here")
	iFirst := strings.Index(board, "first post here")
	if iSecond < 0 || iFirst < 0 || iSecond > iFirst {
		t.Fatalf("board should list newest first:\n%s", board)
	}
	if !strings.Contains(board, "Cheers: 1") {
		t.Fatalf("board should show the cheer count:\n%s", board)
	}
	one := Render("/0")
	if !strings.Contains(one, "first post here") || strings.Contains(one, "second post here") {
		t.Fatalf("single render should show only message 0:\n%s", one)
	}
	missing := Render("/99")
	if !strings.Contains(missing, "Message not found") {
		t.Fatalf("unknown id should render not-found text:\n%s", missing)
	}
	garbage := Render("/hello")
	if !strings.Contains(garbage, "Message not found") {
		t.Fatalf("non-numeric path should render not-found text:\n%s", garbage)
	}
}
