package gauntlet

import (
	"strconv"
	"strings"
	"time"

	"gno.land/p/g188c5k6v0tmfyevfzj962jkajjqt4ddtml8zw0x/gauntlet"
	txlink "gno.land/p/moul/txlink/v0"
	"gno.land/p/nt/markdown/sanitize/v0"
)

// Render serves the board in gnoweb.
//
//	""             open bounties and recent winners
//	"c/<id>"       one challenge: spec, tests, queue, result
//	"u/<address>"  a solver's or poster's profile
//	"leaderboard"  top earners
//	"judges"       registered judges
//	"solve"        how to submit a solution
func Render(path string) string {
	now := time.Now()
	switch {
	case path == "":
		return renderHome(now)
	case strings.HasPrefix(path, "c/"):
		id, err := strconv.ParseUint(path[2:], 10, 64)
		if err != nil {
			return "# Not found\n\n[Back to the board](" + home() + ")"
		}
		return renderChallenge(id, now)
	case strings.HasPrefix(path, "u/"):
		a := address(path[2:])
		if !a.IsValid() {
			return "# Not found\n\n[Back to the board](" + home() + ")"
		}
		return renderProfile(a)
	case path == "leaderboard":
		return renderLeaderboard()
	case path == "judges":
		return renderJudges()
	case path == "solve":
		return renderSolveGuide()
	}
	return "# Not found\n\n[Back to the board](" + home() + ")"
}

func self() string { return webPath(selfPkgPath()) }
func home() string { return self() }

// tx builds a transaction link to this realm, whatever path it is deployed at.
func tx(fn string) *txlink.TxBuilder { return txlink.Realm(selfPkgPath()).NewLink(fn) }

func nav() string {
	return "[Board](" + home() + ") · [Leaderboard](" + self() + ":leaderboard) · [Judges](" + self() +
		":judges) · [How to solve](" + self() + ":solve)\n\n"
}

func renderHome(now time.Time) string {
	var b strings.Builder
	b.WriteString("# Gauntlet\n\n")
	b.WriteString("**Coding bounties graded by the chain, not by people.** Post a challenge with a GNOT reward. ")
	b.WriteString("Solvers deploy a function, this realm runs the tests on-chain, and the earliest passing commit is paid instantly. ")
	b.WriteString("No reviewer can refuse to pay, and copying someone's deployed code never wins.\n\n")
	b.WriteString(nav())

	open, escrow, solvers := 0, int64(0), profiles.Size()
	board.Iterate(func(c *gauntlet.Challenge) bool {
		if c.Status == gauntlet.Open {
			open++
			escrow += c.Pot()
		}
		return false
	})
	b.WriteString("| Open bounties | In escrow | Paid to solvers | Players |\n|---|---|---|---|\n")
	b.WriteString("| " + strconv.Itoa(open) + " | " + gnot(escrow) + " | " + gnot(totalPaid) + " | " + strconv.Itoa(solvers) + " |\n\n")

	b.WriteString("## Open bounties\n\n")
	if open == 0 {
		b.WriteString("_No open bounties right now. [Post one](" + tx("Post").URL() + ")._\n\n")
	} else {
		b.WriteString("| # | Challenge | Reward | Graded by | Attempts | Time |\n|---|---|---|---|---|---|\n")
		board.Iterate(func(c *gauntlet.Challenge) bool {
			if c.Status == gauntlet.Open {
				b.WriteString("| " + itoa(c.ID) + " | [" + sanitize.TableCell(c.Title) + "](" + self() + ":c/" + itoa(c.ID) + ") | " +
					gnot(c.Pot()) + " | " + gradedBy(c) + " | " + strconv.Itoa(len(c.Attempts)) + " | " + left(now, c.Deadline) + " |\n")
			}
			return false
		})
		b.WriteString("\n")
	}

	b.WriteString("## Recent winners\n\n")
	if len(paidOut) == 0 {
		b.WriteString("_Nobody has won yet. Be first._\n\n")
	} else {
		for i := len(paidOut) - 1; i >= 0 && i >= len(paidOut)-10; i-- {
			p := paidOut[i]
			c := board.Get(p.ChallengeID)
			b.WriteString("- [" + short(p.To) + "](" + self() + ":u/" + p.To.String() + ") won **" + gnot(p.Amount) +
				"** on [" + sanitize.InlineText(c.Title) + "](" + self() + ":c/" + itoa(c.ID) + ")\n")
		}
		b.WriteString("\n")
	}

	closed := 0
	b.WriteString("## Finished\n\n")
	board.Iterate(func(c *gauntlet.Challenge) bool {
		if c.Status != gauntlet.Open {
			closed++
			b.WriteString("- [#" + itoa(c.ID) + " " + sanitize.InlineText(c.Title) + "](" + self() + ":c/" + itoa(c.ID) + ") · " + c.Status.String() + "\n")
		}
		return closed >= 20
	})
	if closed == 0 {
		b.WriteString("_None yet._\n")
	}
	b.WriteString("\n---\n\n[Post a bounty with test cases](" + tx("Post").URL() + ") · " +
		"[Post a judged bounty](" + tx("PostJudged").URL() + ")\n")
	return b.String()
}

func gradedBy(c *gauntlet.Challenge) string {
	if c.Judge != nil {
		return "judge"
	}
	return strconv.Itoa(len(c.Cases)) + " tests"
}

func renderChallenge(id uint64, now time.Time) string {
	c := board.Get(id)
	if c == nil {
		return "# Not found\n\n[Back to the board](" + home() + ")"
	}
	var b strings.Builder
	b.WriteString("# #" + itoa(c.ID) + " " + sanitize.InlineText(c.Title) + "\n\n")
	b.WriteString(nav())

	switch c.Status {
	case gauntlet.Open:
		b.WriteString("> **Open** · reward **" + gnot(c.Pot()) + "** · commits close " + when(c.Deadline) + " (" + left(now, c.Deadline) + ")\n\n")
	case gauntlet.Won:
		w := c.Winner
		b.WriteString("> **Won** by [" + short(w.Solver) + "](" + self() + ":u/" + w.Solver.String() + ") for **" + gnot(c.Pot()) +
			"**. Winning code: [" + webPath(w.PkgPath) + "](" + webPath(w.PkgPath) + "$source)\n\n")
	case gauntlet.Closed:
		b.WriteString("> **Closed.** Nobody passed before the deadline; the reward went back to the poster.\n\n")
	}

	b.WriteString("| Reward | Bond per commit | Reveal window | Posted by | Posted |\n|---|---|---|---|---|\n")
	b.WriteString("| " + gnot(c.Pot()) + " | " + gnot(c.Bond) + " | " + c.Window.String() + " | [" + short(c.Poster) + "](" +
		self() + ":u/" + c.Poster.String() + ") | " + when(c.Created) + " |\n\n")
	if c.Boosts > 0 || c.Forfeited > 0 {
		b.WriteString("_Includes " + gnot(c.Boosts) + " in boosts and " + gnot(c.Forfeited) + " in forfeited bonds._\n\n")
	}

	b.WriteString("## The challenge\n\n")
	if strings.TrimSpace(c.Spec) == "" {
		b.WriteString("_No description._\n\n")
	} else {
		b.WriteString(sanitize.Block(c.Spec) + "\n\n")
	}
	b.WriteString("Write `func Solve(in string) string`.\n\n")

	b.WriteString("## How it is graded\n\n")
	if c.Judge != nil {
		b.WriteString("A **judge** generates fresh inputs at the moment you reveal and checks each answer, so a lookup table cannot pass. ")
		b.WriteString("Read the judge's code: [" + webPath(c.JudgePath) + "](" + webPath(c.JudgePath) + "$source).\n\n")
	}
	if len(c.Cases) > 0 {
		b.WriteString("Every one of these must match exactly:\n\n")
		for i, tc := range c.Cases {
			if i >= 8 {
				b.WriteString("_…and " + strconv.Itoa(len(c.Cases)-8) + " more. See them all in the realm source data or the web app._\n\n")
				break
			}
			b.WriteString(sanitize.CodeBlock("Solve("+strconv.Quote(tc.In)+")\n// want "+strconv.Quote(tc.Want)) + "\n")
		}
	}

	if c.Status == gauntlet.Open {
		b.WriteString("## Enter\n\n")
		b.WriteString("1. Pick a realm path for your solution, e.g. `gno.land/r/<your-address>/solve" + itoa(c.ID) + "`, and a secret salt.\n")
		b.WriteString("2. Get your hash: `HashFor(\"<your realm path>\", \"<salt>\")` and [commit it](" +
			tx("Commit").AddArgs("id", itoa(c.ID)).SetSend(i64toa(c.Bond)+"ugnot").URL() + ") with the " + gnot(c.Bond) + " bond.\n")
		b.WriteString("3. Deploy your realm (template below), then call its `Submit(" + itoa(c.ID) + ", \"<salt>\")` within " + c.Window.String() + ".\n\n")
		b.WriteString(sanitize.LanguageCodeBlock("go", solverTemplate(c.ID)) + "\n\n")
		b.WriteString("[Boost the reward](" + tx("Boost").AddArgs("id", itoa(c.ID)).URL() + ") · " +
			"[Settle](" + tx("Settle").AddArgs("id", itoa(c.ID)).URL() + ")\n\n")
	}

	b.WriteString("## Queue\n\n")
	if len(c.Attempts) == 0 {
		b.WriteString("_No commits yet._\n")
		return b.String()
	}
	b.WriteString("Earlier commits always rank first. A later commit cannot win while an earlier one can still reveal.\n\n")
	b.WriteString("| Place | Solver | Committed | Result | Solution |\n|---|---|---|---|---|\n")
	for i, a := range c.Attempts {
		result := a.State.String()
		if a.State == gauntlet.Passed || a.State == gauntlet.Failed {
			result += " (" + strconv.Itoa(a.Report.Passed) + "/" + strconv.Itoa(a.Report.Total) + ")"
		}
		if c.Winner == a {
			result = "**winner** " + result
		}
		sol := "—"
		if a.PkgPath != "" {
			sol = "[source](" + webPath(a.PkgPath) + "$source)"
		}
		b.WriteString("| " + strconv.Itoa(i+1) + " | [" + short(a.Solver) + "](" + self() + ":u/" + a.Solver.String() + ") | " +
			when(a.CommittedAt) + " | " + result + " | " + sol + " |\n")
	}
	for _, a := range c.Attempts {
		if a.State == gauntlet.Failed && a.Report.FailIn != "" {
			b.WriteString("\n**Failure** (" + short(a.Solver) + "): " + sanitize.InlineCode("Solve("+strconv.Quote(a.Report.FailIn)+")") +
				" returned " + sanitize.InlineCode(strconv.Quote(a.Report.FailGot)))
			if a.Report.FailWant != "" {
				b.WriteString(", wanted " + sanitize.InlineCode(strconv.Quote(a.Report.FailWant)))
			}
			b.WriteString("\n")
		}
	}
	return b.String()
}

func solverTemplate(id uint64) string {
	return "package solve" + itoa(id) + "\n\n" +
		"import \"" + selfPkgPath() + "\"\n\n" +
		"func Solve(in string) string {\n\t// your code\n\treturn in\n}\n\n" +
		"func Submit(cur realm, id uint64, salt string) {\n\tgauntlet.Reveal(cross(cur), id, salt, Solve)\n}"
}

func renderProfile(a address) string {
	var b strings.Builder
	b.WriteString("# " + short(a) + "\n\n" + nav())
	v := profiles.Get(a.String())
	if v == nil {
		b.WriteString("_No activity yet._\n")
		return b.String()
	}
	p := v.(*Profile)
	b.WriteString("`" + a.String() + "`\n\n")
	b.WriteString("| Solved | Earned | Attempts | Posted | Funded |\n|---|---|---|---|---|\n")
	b.WriteString("| " + strconv.Itoa(p.Solved) + " | " + gnot(p.Earned) + " | " + strconv.Itoa(p.Attempts) + " | " +
		strconv.Itoa(p.Posted) + " | " + gnot(p.Funded) + " |\n\n")
	b.WriteString("## Wins\n\n")
	wins := 0
	for _, r := range paidOut {
		if r.To == a {
			c := board.Get(r.ChallengeID)
			b.WriteString("- [" + sanitize.InlineText(c.Title) + "](" + self() + ":c/" + itoa(c.ID) + ") · " + gnot(r.Amount) + "\n")
			wins++
		}
	}
	if wins == 0 {
		b.WriteString("_None yet._\n")
	}
	return b.String()
}

func renderLeaderboard() string {
	var b strings.Builder
	b.WriteString("# Leaderboard\n\n" + nav())
	top := topSolvers(25)
	if len(top) == 0 {
		b.WriteString("_Nobody has solved a bounty yet._\n")
		return b.String()
	}
	b.WriteString("| Rank | Solver | Solved | Earned |\n|---|---|---|---|\n")
	for i, p := range top {
		b.WriteString("| " + strconv.Itoa(i+1) + " | [" + short(p.Addr) + "](" + self() + ":u/" + p.Addr.String() + ") | " +
			strconv.Itoa(p.Solved) + " | " + gnot(p.Earned) + " |\n")
	}
	return b.String()
}

// topSolvers returns profiles with at least one win, by earnings.
func topSolvers(n int) []*Profile {
	var out []*Profile
	profiles.Iterate("", "", func(_ string, v any) bool {
		p := v.(*Profile)
		if p.Solved > 0 {
			out = append(out, p)
		}
		return false
	})
	// insertion sort: small n, no allocations beyond the slice
	for i := 1; i < len(out); i++ {
		for j := i; j > 0 && better(out[j], out[j-1]); j-- {
			out[j], out[j-1] = out[j-1], out[j]
		}
	}
	if len(out) > n {
		out = out[:n]
	}
	return out
}

func better(a, b *Profile) bool {
	if a.Earned != b.Earned {
		return a.Earned > b.Earned
	}
	return a.Solved > b.Solved
}

func renderJudges() string {
	var b strings.Builder
	b.WriteString("# Judges\n\n" + nav())
	b.WriteString("A judge is a realm with two functions: one generates inputs from a seed, one checks an answer. ")
	b.WriteString("It registers itself once and can never change, so anyone can post a bounty graded by it and trust the rules will not move.\n\n")
	if judges.Size() == 0 {
		b.WriteString("_No judges registered yet._\n")
		return b.String()
	}
	b.WriteString("| Judge | About | Used by | Code |\n|---|---|---|---|\n")
	judges.Iterate("", "", func(_ string, v any) bool {
		j := v.(*JudgeInfo)
		b.WriteString("| " + sanitize.TableCell(j.Name) + " | " + sanitize.TableCell(j.About) + " | " + strconv.Itoa(j.Uses) + " bounties | [" +
			webPath(j.Path) + "](" + webPath(j.Path) + "$source) |\n")
		return false
	})
	b.WriteString("\n[Post a judged bounty](" + tx("PostJudged").URL() + ")\n")
	return b.String()
}

func renderSolveGuide() string {
	var b strings.Builder
	b.WriteString("# How to solve a bounty\n\n" + nav())
	b.WriteString("Gauntlet uses **commit, deploy, reveal** so nobody can copy your answer.\n\n")
	b.WriteString("1. **Commit.** Choose your solution's realm path and a secret salt. Compute `HashFor(path, salt)` and call `Commit(id, hash)` with the bond. Your place in line is now fixed.\n")
	b.WriteString("2. **Deploy.** Publish your realm with `Solve` and `Submit` (template below). Anyone can now read it, but anyone who copies it commits after you.\n")
	b.WriteString("3. **Reveal.** Call your realm's `Submit(id, salt)` before your reveal window ends. This realm reads your package path from the runtime, checks the hash, runs the tests and records the result. Your bond comes back either way.\n\n")
	b.WriteString("The earliest commit that passes wins the whole pot. If you skip the reveal, your bond is added to the reward.\n\n")
	b.WriteString(sanitize.LanguageCodeBlock("go", solverTemplate(1)) + "\n\n")
	b.WriteString("## Rules the code enforces\n\n")
	b.WriteString("- Solutions must live in a deployed `/r/` realm, so the winning code stays public on-chain.\n")
	b.WriteString("- One pending commit per address per bounty. Failed? Commit again with a new realm.\n")
	b.WriteString("- Your `Solve` cannot touch this realm's funds or state: Gno runs it under your realm's authority, and it never receives this realm's `cur`.\n")
	b.WriteString("- The poster cannot cancel or change the tests. The reward is locked until someone wins or the deadline passes.\n")
	return b.String()
}
