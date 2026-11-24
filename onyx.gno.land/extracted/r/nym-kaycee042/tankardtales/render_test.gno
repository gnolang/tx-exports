package tankardtales

import (
	"strconv"
	"strings"
	"testing"

	"gno.land/p/nt/uassert/v0"
)

func TestRenderHome(cur realm, t *testing.T) {
	out := Render("")
	if !strings.Contains(out, "Tankard & Tales") {
		t.Fatalf("home render missing tavern name:\n%s", out)
	}
	if !strings.Contains(out, "guestbook") {
		t.Fatalf("home render missing guestbook link:\n%s", out)
	}
}

func TestRenderBoardAndGuestbook(cur realm, t *testing.T) {
	// Put something on the board and in the book.
	testing.SetRealm(testing.NewUserRealm(alice))
	SignGuestbook(cross(cur), "Alice", "Lovely tavern.")
	postQuest(alice, "Render the roof", "So the judges can see it.", 2000)

	board := Render("quests")
	if !strings.Contains(board, "Render the roof") {
		t.Fatalf("board render missing quest title:\n%s", board)
	}

	book := Render("guestbook")
	// Note: the sanitizer markdown-escapes the trailing period
	// ("Lovely tavern\."), so match on the unescaped prefix.
	if !strings.Contains(book, "Alice") || !strings.Contains(book, "Lovely tavern") {
		t.Fatalf("guestbook render missing entry:\n%s", book)
	}

	regs := Render("regulars")
	if !strings.Contains(regs, "The Regulars") {
		t.Fatalf("regulars render missing heading:\n%s", regs)
	}
}

func TestRenderQuestDetail(cur realm, t *testing.T) {
	id := postQuest(bob, "Detail page quest", "Shown on its own page.", 2500)
	out := Render("quests/" + strconv.Itoa(id))
	if !strings.Contains(out, "Detail page quest") || !strings.Contains(out, "OPEN") {
		t.Fatalf("quest detail render wrong:\n%s", out)
	}

	missing := Render("quests/424242")
	if !strings.Contains(missing, "No such quest") {
		t.Fatalf("missing-quest render wrong:\n%s", missing)
	}
}

func TestRenderSanitizesUserText(cur realm, t *testing.T) {
	// A title crafted to break out of its markdown slot must be escaped
	// in the board listing, not interpreted as structure.
	postQuest(carol, "Evil ](https://example.com) title", "Perfectly normal details.", 2000)
	board := Render("quests")
	if strings.Contains(board, "](https://example.com)") {
		t.Fatalf("board render contains unsanitized link injection:\n%s", board)
	}
	uassert.Equal(t, strings.Contains(board, "Evil"), true)
}
