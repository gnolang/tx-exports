// Doorwarden is an on-chain security checklist and review registry for
// Gno realms: the bouncer at the tavern door. Builders (or reviewers)
// submit a per-check verdict for a realm path; Doorwarden scores it
// against a canonical list of Gno security pitfalls and publishes the
// result on a public leaderboard.
//
// A review is encoded as one character per checklist item, in order:
// 'P' = pass, 'F' = fail, 'N' = not applicable.
package doorwarden

import (
	"strconv"
	"strings"
)

// Check is one item of the canonical security checklist.
type Check struct {
	ID       string
	Title    string
	Severity string
	Weight   int
	Guidance string
}

// Review is one reviewer's verdict on one realm path.
type Review struct {
	RealmPath string
	Reviewer  string
	Results   string
	Note      string
	Score     int
	Seq       int
}

const (
	maxPathLen  = 128
	maxNoteLen  = 280
	maxBoardOut = 25
	maxRecent   = 10
)

// checks is the canonical Doorwarden checklist. Order matters: review
// result strings are positional against this list.
var checks = []Check{
	{ID: "caller-auth", Title: "Caller authentication", Severity: "Critical", Weight: 3,
		Guidance: "State-changing crossing functions derive caller identity from cur.Previous() and authorize explicitly; never trust caller-supplied addresses or tx-origin style assumptions."},
	{ID: "payment-guard", Title: "Payment verification", Severity: "Critical", Weight: 3,
		Guidance: "Functions that credit value verify the coins actually sent (denom and amount) in the same call and require a direct user call; never credit on promised payment."},
	{ID: "render-sanitize", Title: "Render output safety", Severity: "High", Weight: 2,
		Guidance: "Render() treats its path argument and all stored user strings as attacker-controlled; markdown metacharacters are escaped before output."},
	{ID: "bounds-dos", Title: "Bounds and DoS resistance", Severity: "High", Weight: 2,
		Guidance: "All inputs are length-capped, loops over user-grown state are bounded or paginated, and storage growth per call is priced in."},
	{ID: "cross-realm-trust", Title: "Cross-realm trust", Severity: "High", Weight: 2,
		Guidance: "Calls from other realms are not trusted by pkgpath or arguments alone; pointers to mutable realm state are never returned to callers."},
	{ID: "arithmetic", Title: "Arithmetic safety", Severity: "Medium", Weight: 1,
		Guidance: "Arithmetic is bounds-checked; division by zero and overflow paths are handled explicitly."},
	{ID: "init-admin", Title: "Initialization and admin", Severity: "Medium", Weight: 1,
		Guidance: "Deployment-time state (owner/admin) is set correctly, and realm immutability is planned for with explicit versioning."},
	{ID: "tests", Title: "Test coverage", Severity: "Medium", Weight: 1,
		Guidance: "The realm ships _test.gno tests covering crossing functions, authorization failures, and invalid inputs."},
}

var (
	reviews       []Review
	reviewedPaths []string
	bestScores    []int // parallel to reviewedPaths
	reviewCounts  []int // parallel to reviewedPaths
	seq           int
)

// CheckCount returns the number of checklist items. A valid results
// string has exactly this many characters.
func CheckCount() int {
	return len(checks)
}

// ScoreResults scores a results string against the checklist.
// 'P' earns the check's weight, 'F' earns nothing, 'N' excludes the
// check. The score is a rounded percentage; a review with no
// applicable checks scores 0. Panics on malformed input.
func ScoreResults(results string) int {
	score, _ := scoreOf(results)
	return score
}

func scoreOf(results string) (int, int) {
	if len(results) != len(checks) {
		panic("results must have exactly " + strconv.Itoa(len(checks)) + " characters, one per check")
	}
	earned := 0
	possible := 0
	for i := 0; i < len(results); i++ {
		switch results[i] {
		case 'P', 'p':
			earned += checks[i].Weight
			possible += checks[i].Weight
		case 'F', 'f':
			possible += checks[i].Weight
		case 'N', 'n':
		default:
			panic("results may only contain P, F or N")
		}
	}
	if possible == 0 {
		return 0, 0
	}
	return (earned*100 + possible/2) / possible, possible
}

// Verdict maps a score to the door verdict.
func Verdict(score int) string {
	switch {
	case score >= 90:
		return "Tavern-ready"
	case score >= 70:
		return "Mostly sound"
	case score >= 40:
		return "Needs work"
	default:
		return "Turned away"
	}
}

// SubmitReview records (or updates) the caller's review of a realm
// path. One review per reviewer per path: resubmitting replaces the
// previous verdict. Returns a one-line summary.
func SubmitReview(cur realm, realmPath string, results string, note string) string {
	if !validPkgPath(realmPath) {
		panic("realmPath must be a gno.land/r/ or gno.land/p/ package path")
	}
	if len(note) > maxNoteLen {
		panic("note exceeds " + strconv.Itoa(maxNoteLen) + " characters")
	}
	score, possible := scoreOf(results)
	reviewer := cur.Previous().Address().String()
	seq++

	idx := findReview(realmPath, reviewer)
	if idx >= 0 {
		reviews[idx].Results = results
		reviews[idx].Note = note
		reviews[idx].Score = score
		reviews[idx].Seq = seq
	} else {
		reviews = append(reviews, Review{
			RealmPath: realmPath,
			Reviewer:  reviewer,
			Results:   results,
			Note:      note,
			Score:     score,
			Seq:       seq,
		})
	}
	recomputePath(realmPath)

	verdict := Verdict(score)
	if possible == 0 {
		verdict = "No applicable checks"
	}
	return realmPath + " scored " + strconv.Itoa(score) + "/100 - " + verdict +
		" (review #" + strconv.Itoa(seq) + ")"
}

// BestScore returns the highest review score for a realm path, or -1
// if the path has never been reviewed.
func BestScore(realmPath string) int {
	for i, p := range reviewedPaths {
		if p == realmPath {
			return bestScores[i]
		}
	}
	return -1
}

// ReviewCount returns how many distinct reviewers have reviewed a
// realm path.
func ReviewCount(realmPath string) int {
	for i, p := range reviewedPaths {
		if p == realmPath {
			return reviewCounts[i]
		}
	}
	return 0
}

// TotalReviews returns the number of reviews ever submitted,
// counting updates.
func TotalReviews() int {
	return seq
}

func findReview(realmPath string, reviewer string) int {
	for i, r := range reviews {
		if r.RealmPath == realmPath && r.Reviewer == reviewer {
			return i
		}
	}
	return -1
}

func recomputePath(realmPath string) {
	best := -1
	count := 0
	for _, r := range reviews {
		if r.RealmPath == realmPath {
			count++
			if r.Score > best {
				best = r.Score
			}
		}
	}
	for i, p := range reviewedPaths {
		if p == realmPath {
			bestScores[i] = best
			reviewCounts[i] = count
			return
		}
	}
	reviewedPaths = append(reviewedPaths, realmPath)
	bestScores = append(bestScores, best)
	reviewCounts = append(reviewCounts, count)
}

func validPkgPath(path string) bool {
	if len(path) > maxPathLen {
		return false
	}
	if !strings.HasPrefix(path, "gno.land/r/") && !strings.HasPrefix(path, "gno.land/p/") {
		return false
	}
	for i := 0; i < len(path); i++ {
		c := path[i]
		ok := (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') ||
			(c >= '0' && c <= '9') || c == '/' || c == '.' || c == '_' || c == '-'
		if !ok {
			return false
		}
	}
	return true
}

// sanitize strips markdown metacharacters from user-controlled text
// before it reaches Render output.
func sanitize(s string) string {
	out := ""
	for i := 0; i < len(s); i++ {
		switch s[i] {
		case '`', '*', '_', '[', ']', '(', ')', '<', '>', '#', '|', '\\', '~', '\n', '\r':
			out += " "
		default:
			out += s[i : i+1]
		}
	}
	return out
}

// Render serves the realm's public pages: "" (home), "checks",
// "leaderboard" and "reviews".
func Render(path string) string {
	switch path {
	case "checks":
		return renderChecks()
	case "leaderboard":
		return renderLeaderboard()
	case "reviews":
		return renderReviews()
	default:
		return renderHome()
	}
}

func renderHome() string {
	out := "# Doorwarden\n\n"
	out += "The bouncer for your realm. Doorwarden scores Gno realms against a canonical " +
		"security checklist and publishes the verdict on-chain.\n\n"
	out += "Submit a review with SubmitReview: one character per check below, in order - " +
		"P (pass), F (fail), N (not applicable).\n\n"
	out += "## The checklist\n\n"
	out += checklistTable()
	out += "\nPages: checks (full guidance), leaderboard (best scores), reviews (latest verdicts).\n"
	return out
}

func checklistTable() string {
	out := "| # | Check | Severity | Weight |\n|---|---|---|---|\n"
	for i, c := range checks {
		out += "| " + strconv.Itoa(i+1) + " | " + c.ID + " - " + c.Title + " | " +
			c.Severity + " | " + strconv.Itoa(c.Weight) + " |\n"
	}
	return out
}

func renderChecks() string {
	out := "# Doorwarden checklist\n\n"
	for i, c := range checks {
		out += "## " + strconv.Itoa(i+1) + ". " + c.ID + " - " + c.Title + "\n\n"
		out += "Severity: " + c.Severity + " | Weight: " + strconv.Itoa(c.Weight) + "\n\n"
		out += c.Guidance + "\n\n"
	}
	return out
}

func renderLeaderboard() string {
	out := "# Doorwarden leaderboard\n\n"
	if len(reviewedPaths) == 0 {
		return out + "No realms reviewed yet. Be the first to face the door.\n"
	}
	order := sortedPaths()
	out += "| Realm | Best score | Verdict | Reviews |\n|---|---|---|---|\n"
	shown := 0
	for _, i := range order {
		if shown >= maxBoardOut {
			break
		}
		out += "| " + sanitize(reviewedPaths[i]) + " | " + strconv.Itoa(bestScores[i]) +
			" | " + Verdict(bestScores[i]) + " | " + strconv.Itoa(reviewCounts[i]) + " |\n"
		shown++
	}
	return out
}

func sortedPaths() []int {
	order := make([]int, len(reviewedPaths))
	for i := range order {
		order[i] = i
	}
	for i := 0; i < len(order); i++ {
		for j := i + 1; j < len(order); j++ {
			a, b := order[i], order[j]
			if bestScores[b] > bestScores[a] ||
				(bestScores[b] == bestScores[a] && reviewedPaths[b] < reviewedPaths[a]) {
				order[i], order[j] = b, a
			}
		}
	}
	return order
}

func renderReviews() string {
	out := "# Latest reviews\n\n"
	if len(reviews) == 0 {
		return out + "No reviews yet.\n"
	}
	shown := 0
	for i := len(reviews) - 1; i >= 0 && shown < maxRecent; i-- {
		r := reviews[i]
		out += "- " + sanitize(r.RealmPath) + " - " + strconv.Itoa(r.Score) + "/100 (" +
			Verdict(r.Score) + ") by " + sanitize(r.Reviewer)
		if r.Note != "" {
			out += ": " + sanitize(r.Note)
		}
		out += "\n"
		shown++
	}
	return out
}
