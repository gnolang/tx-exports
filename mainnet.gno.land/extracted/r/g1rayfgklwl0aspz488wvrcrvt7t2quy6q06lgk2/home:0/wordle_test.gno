package home

import (
	"strings"
	"testing"

	"gno.land/p/nt/uassert/v0"
)

func TestWords(t *testing.T) {
	seen := map[string]bool{}
	for _, w := range words {
		uassert.True(t, validGuess(w), "bad word: "+w)
		uassert.False(t, seen[w], "duplicate word: "+w)
		seen[w] = true
	}
	// stride is coprime with the list, so a full cycle hits every word once.
	got := map[string]bool{}
	for n := 1; n <= len(words); n++ {
		got[answer(n)] = true
	}
	uassert.Equal(t, len(words), len(got))
}

func TestScore(t *testing.T) {
	uassert.Equal(t, "🟩🟩🟩🟩🟩", score("REALM", "REALM"))
	uassert.Equal(t, "⬛⬛⬛⬛⬛", score("BUNNY", "REALM"))
	uassert.Equal(t, "🟨🟨🟨🟨🟨", score("EALMR", "REALM"))
	// One E in the answer: the second E in the guess gets nothing.
	uassert.Equal(t, "⬛🟩🟨⬛⬛", score("EERIE", "REALM"))
	uassert.Equal(t, "🟨⬛⬛⬛⬛", score("EXXEX", "REALM"))
	// The exact match claims the letter before a misplaced copy can.
	uassert.Equal(t, "⬛🟩🟩⬛⬛", score("AAXXX", "BAXYZ"))
}

func TestWordleFlow(t *testing.T) {
	setDay(launchDay + 2) // puzzle #3
	ans := answer(3)

	page := Render("wordle")
	uassert.True(t, strings.Contains(page, "# Gnordle #3"))
	uassert.True(t, strings.Contains(page, `<gno-form path="wordle/3">`))

	page = Render("wordle/3?guess=crane")
	uassert.True(t, strings.Contains(page, score("CRANE", ans)+" CRANE"))
	uassert.True(t, strings.Contains(page, `<gno-form path="wordle/3/CRANE">`))
	uassert.True(t, strings.Contains(page, "Guess 2 of 6"))

	page = Render("wordle/3/CRANE?guess=" + ans)
	uassert.True(t, strings.Contains(page, "**Solved in 2/6.**"))
	uassert.True(t, strings.Contains(page, "Gnordle #3 2/6"))
	uassert.False(t, strings.Contains(page, "<gno-form"))

	page = Render("wordle/3?guess=abc")
	uassert.True(t, strings.Contains(page, "> That guess is not five letters, A to Z."))
	uassert.True(t, strings.Contains(page, `<gno-form path="wordle/3">`))

	page = Render("wordle/1")
	uassert.True(t, strings.Contains(page, "[Play today's puzzle]"))
}

func TestWordleLost(t *testing.T) {
	setDay(launchDay)
	ans := answer(1)
	wrong := "ZZZZZ"
	if ans == wrong {
		wrong = "YYYYY"
	}
	path := "wordle/1/" + strings.Repeat(wrong+".", 5) + wrong
	page := Render(path)
	uassert.True(t, strings.Contains(page, "**The word was "+ans+".**"))
	uassert.True(t, strings.Contains(page, "Gnordle #1 X/6"))
}

func TestWordleBadLinks(t *testing.T) {
	setDay(launchDay)
	uassert.True(t, strings.Contains(Render("wordle/2"), "is not out yet"))
	uassert.True(t, strings.Contains(Render("wordle/0"), "no puzzle with that number"))
	uassert.True(t, strings.Contains(Render("wordle/x"), "no puzzle with that number"))
	uassert.True(t, strings.Contains(Render("wordle/1/CRA"), "link is broken"))
	uassert.True(t, strings.Contains(Render("wordle/1/A.B/C"), "link is broken"))
	tooMany := "wordle/1/" + strings.Repeat("CRANE.", 6) + "CRANE"
	uassert.True(t, strings.Contains(Render(tooMany), "link is broken"))
}
