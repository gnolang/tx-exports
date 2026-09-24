package home

import (
	"net/url"
	"strconv"
	"strings"
	"time"
)

// Gnordle: guess the day's five-letter word in six tries. The game keeps no
// state on chain. Past guesses ride in the page path, wordle/<n>/CRANE.SLATE,
// and a gnoweb form adds the next one as ?guess=, so playing needs no wallet.

const (
	wordLen    = 5
	maxGuesses = 6
	launchDay  = 20719 // 2026-09-23, in days since 1970-01-01 UTC: puzzle #1
	stride     = 17    // coprime with len(words), so every word comes up once per cycle
)

// words are the answers, gno and blockchain flavoured.
var words = []string{
	"REALM", "CROSS", "BLOCK", "CHAIN", "TOKEN", "STAKE", "PANIC", "DEFER",
	"SLICE", "ARRAY", "PRINT", "STACK", "QUEUE", "TUPLE", "FLOAT", "CONST",
	"PARSE", "PROOF", "NONCE", "VOTER", "SHARD", "MERGE", "AUDIT", "DEBUG",
	"TRACE", "CACHE", "INDEX", "QUERY", "ROUTE", "VALUE", "RUNES", "ERROR",
	"GUARD", "OWNER", "ADMIN", "TREES", "NODES", "PEERS", "GRAPH", "FORKS",
	"MINTS", "LOGIC", "BYTES", "CLASS", "FIELD", "LOOPS", "PROBE", "SCOPE",
	"TYPED", "BENCH", "CLONE", "PATCH", "EMBED", "FETCH", "LABEL", "LOCAL",
	"PROXY", "SCALE", "SPAWN",
}

// today returns the number of the current puzzle, from the last block's time.
func today() int {
	return int(time.Now().Unix()/86400) - launchDay + 1
}

// answer returns the word of puzzle n.
func answer(n int) string {
	i := ((n-1)*stride%len(words) + len(words)) % len(words)
	return words[i]
}

// score colours a guess against the answer, handling repeated letters the way
// the original game does: a letter is marked present only as many times as it
// is still unmatched in the answer.
func score(guess, ans string) string {
	marks := make([]string, wordLen)
	left := map[byte]int{}
	for i := 0; i < wordLen; i++ {
		if guess[i] == ans[i] {
			marks[i] = "🟩"
		} else {
			left[ans[i]]++
		}
	}
	for i := 0; i < wordLen; i++ {
		if marks[i] != "" {
			continue
		}
		if left[guess[i]] > 0 {
			marks[i] = "🟨"
			left[guess[i]]--
		} else {
			marks[i] = "⬛"
		}
	}
	return strings.Join(marks, "")
}

func validGuess(g string) bool {
	if len(g) != wordLen {
		return false
	}
	for i := 0; i < wordLen; i++ {
		if g[i] < 'A' || g[i] > 'Z' {
			return false
		}
	}
	return true
}

func renderWordle(path string) string {
	path, query, _ := strings.Cut(path, "?")
	parts := strings.Split(path, "/") // "wordle", [n], [guesses]
	n := today()
	var guesses []string
	if len(parts) > 1 {
		v, err := strconv.Atoi(parts[1])
		if err != nil || v < 1 {
			return wordleError("There is no puzzle with that number.")
		}
		n = v
	}
	if n > today() {
		return wordleError("Puzzle #" + strconv.Itoa(n) + " is not out yet.")
	}
	if len(parts) > 2 && parts[2] != "" {
		guesses = strings.Split(parts[2], ".")
	}
	if len(parts) > 3 || len(guesses) > maxGuesses {
		return wordleError("This game link is broken.")
	}
	for _, g := range guesses {
		if !validGuess(g) {
			return wordleError("This game link is broken.")
		}
	}

	ans := answer(n)
	notice := ""
	if q, err := url.ParseQuery(query); err == nil && q.Get("guess") != "" && !solved(guesses, ans) && len(guesses) < maxGuesses {
		g := strings.ToUpper(strings.TrimSpace(q.Get("guess")))
		if validGuess(g) {
			guesses = append(guesses, g)
		} else {
			// The guess is never echoed: it comes from the link, and markdown in
			// it would render on this page under the owner's address.
			notice = "> That guess is not five letters, A to Z.\n\n"
		}
	}

	num := strconv.Itoa(n)
	var b strings.Builder
	b.WriteString("# Gnordle #" + num + "\n\n")
	b.WriteString("Guess the word in six tries. 🟩 right letter, right place. 🟨 in the word, elsewhere. ⬛ not in the word. ")
	b.WriteString("Everyone gets the same word, and a new one comes out every day at 00:00 UTC.\n\n")
	b.WriteString(notice)

	grid := ""
	for _, g := range guesses {
		row := score(g, ans)
		grid += row + "\n"
		b.WriteString(row + " " + g + "\n\n")
	}
	if miss := missing(guesses, ans); miss != "" {
		b.WriteString("Not in the word: " + miss + "\n\n")
	}

	switch {
	case solved(guesses, ans):
		b.WriteString("**Solved in " + strconv.Itoa(len(guesses)) + "/6.** Copy your result:\n\n")
		b.WriteString("```\nGnordle #" + num + " " + strconv.Itoa(len(guesses)) + "/6\n" + grid + "```\n\n")
	case len(guesses) == maxGuesses:
		b.WriteString("**The word was " + ans + ".** Copy your result:\n\n")
		b.WriteString("```\nGnordle #" + num + " X/6\n" + grid + "```\n\n")
	default:
		b.WriteString("<gno-form path=\"wordle/" + num)
		if len(guesses) > 0 {
			b.WriteString("/" + strings.Join(guesses, "."))
		}
		b.WriteString("\">\n  <gno-input name=\"guess\" placeholder=\"Guess " +
			strconv.Itoa(len(guesses)+1) + " of 6: five letters\" />\n</gno-form>\n\n")
	}

	b.WriteString("[Start over](" + home + ":wordle/" + num + ")")
	if n < today() {
		b.WriteString(" · [Play today's puzzle](" + home + ":wordle)")
	}
	b.WriteString(" · [Back home](" + home + ")\n")
	return b.String()
}

func solved(guesses []string, ans string) bool {
	return len(guesses) > 0 && guesses[len(guesses)-1] == ans
}

// missing lists the guessed letters that are not in the answer, in guess order.
func missing(guesses []string, ans string) string {
	var out []string
	seen := map[byte]bool{}
	for _, g := range guesses {
		for i := 0; i < wordLen; i++ {
			c := g[i]
			if !seen[c] && !strings.ContainsRune(ans, rune(c)) {
				out = append(out, string(c))
			}
			seen[c] = true
		}
	}
	return strings.Join(out, " ")
}

func wordleError(msg string) string {
	return "# Gnordle\n\n" + msg + "\n\n[Play today's puzzle](" + home + ":wordle) · [Back home](" + home + ")\n"
}

func renderGameTeaser() string {
	return "## Gnordle\n\nGuess today's five-letter word in six tries. Same word for everyone, " +
		"a new one every day, no wallet needed. [Play puzzle #" + strconv.Itoa(today()) + "](" + home + ":wordle)\n"
}
