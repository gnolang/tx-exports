package guildhall

import (
	"strconv"
	"strings"

	"chain/runtime"

	"gno.land/p/nt/markdown/sanitize/v0"
	"gno.land/p/nt/mux/v0"
	"gno.land/p/nt/ufmt/v0"
	"gno.land/p/nym-ololade001/guild/v0"
)

const (
	realmPath = "gno.land/r/nym-ololade001/guildhall/v1"
	realmURL  = "/r/nym-ololade001/guildhall/v1"
	rpcURL    = "https://rpc.onyx.testnets.gno.land:443"
	chainID   = "onyx-1"
)

var router = mux.NewRouter()

func init() {
	router.HandleFunc("", boardHandler)
	router.HandleFunc("q/{id}", questHandler)
	router.HandleFunc("u/{addr}", profileHandler)
	router.HandleFunc("about", aboutHandler)
	router.SetNotFoundHandler(notFoundHandler)
}

// Render serves the board through gnoweb; there is no other UI.
func Render(path string) string {
	return router.Render(path)
}

func boardHandler(res *mux.ResponseWriter, req *mux.Request) {
	h := runtime.ChainHeight()
	var open, live []*guild.Quest
	active.Iterate("", "", func(_ string, value any) bool {
		q, ok := value.(*guild.Quest)
		if !ok || q == nil {
			return false
		}
		switch q.StatusAt(h) {
		case guild.Open:
			open = append(open, q)
		case guild.Claimed, guild.Submitted:
			live = append(live, q)
		}
		return false
	})
	sortByRewardDesc(open)

	var b strings.Builder
	b.WriteString("# Guildhall\n\n")
	b.WriteString("Post a quest, lock the GNOT, and the realm pays whoever does the work, human or agent.\n\n")
	b.WriteString(ufmt.Sprintf("**Board:** %d open quests · %s in escrow · %s paid out\n\n",
		len(open), formatGNOT(escrowTotal), formatGNOT(paidTotal)))

	b.WriteString("## Open quests\n\n")
	if len(open) == 0 {
		b.WriteString("No open quests yet.\n\n")
	} else {
		b.WriteString("| Quest | Reward | Lease | Deadline |\n")
		b.WriteString("|---|---|---|---|\n")
		for _, q := range open {
			b.WriteString(ufmt.Sprintf("| [%s](%s:q/%d) | %s | %d blocks | %d |\n",
				sanitize.TableCell(q.Title), realmURL, q.ID, formatGNOT(q.Reward), q.LeaseBlocks, q.Deadline))
		}
		b.WriteString("\n")
	}

	if len(live) > 0 {
		b.WriteString("## In progress\n\n")
		for _, q := range live {
			who := ufmt.Sprintf("[%s](%s:u/%s)", q.Worker.String(), realmURL, q.Worker.String())
			if q.Status == guild.Claimed {
				b.WriteString(ufmt.Sprintf("- [%s](%s:q/%d) — claimed by %s, lease ends at block %d\n",
					sanitize.InlineText(q.Title), realmURL, q.ID, who, q.LeaseEnd))
			} else {
				b.WriteString(ufmt.Sprintf("- [%s](%s:q/%d) — submitted by %s, review ends at block %d\n",
					sanitize.InlineText(q.Title), realmURL, q.ID, who, q.ReviewEnd()))
			}
		}
		b.WriteString("\n")
	}
	b.WriteString(ufmt.Sprintf("[About Guildhall](%s:about)\n", realmURL))
	res.Write(b.String())
}

func questHandler(res *mux.ResponseWriter, req *mux.Request) {
	idStr := req.GetVar("id")
	id, err := strconv.ParseUint(idStr, 10, 64)
	if err != nil {
		notFoundHandler(res, req)
		return
	}
	q, ok := quests.Get(questKey(id)).(*guild.Quest)
	if !ok || q == nil {
		notFoundHandler(res, req)
		return
	}
	h := runtime.ChainHeight()
	st := q.StatusAt(h)

	var b strings.Builder
	b.WriteString(ufmt.Sprintf("# %s\n\n", sanitize.InlineText(q.Title)))
	b.WriteString(ufmt.Sprintf("- **Status:** %s\n", st.String()))
	b.WriteString(ufmt.Sprintf("- **Reward:** %s\n", formatGNOT(q.Reward)))
	b.WriteString(ufmt.Sprintf("- **Poster:** [%s](%s:u/%s)\n", q.Poster.String(), realmURL, q.Poster.String()))
	if q.Worker.IsValid() {
		b.WriteString(ufmt.Sprintf("- **Worker:** [%s](%s:u/%s)\n", q.Worker.String(), realmURL, q.Worker.String()))
	}
	b.WriteString(ufmt.Sprintf("- **Lease:** %d blocks", q.LeaseBlocks))
	if q.Status == guild.Claimed {
		if left := q.LeaseEnd - h; left > 0 {
			b.WriteString(ufmt.Sprintf(", ends at block %d (%d left)", q.LeaseEnd, left))
		} else {
			b.WriteString(ufmt.Sprintf(", expired at block %d", q.LeaseEnd))
		}
	}
	b.WriteString("\n")
	b.WriteString(ufmt.Sprintf("- **Review window:** %d blocks", q.ReviewBlocks))
	if q.Status == guild.Submitted {
		if left := q.ReviewEnd() - h; left >= 0 {
			b.WriteString(ufmt.Sprintf(", ends at block %d (%d left)", q.ReviewEnd(), left))
		} else {
			b.WriteString(ufmt.Sprintf(", closed at block %d", q.ReviewEnd()))
		}
	}
	b.WriteString("\n")
	b.WriteString(ufmt.Sprintf("- **Deadline:** block %d\n", q.Deadline))
	if q.AutoPaid {
		b.WriteString("- **Paid:** automatically, after the poster's silence\n")
	}
	if q.ProofURL != "" {
		if u := sanitize.URL(q.ProofURL); u != "" {
			b.WriteString(ufmt.Sprintf("- **Proof:** [%s](%s)\n", sanitize.InlineText(q.ProofURL), u))
		} else {
			b.WriteString(ufmt.Sprintf("- **Proof:** %s\n", sanitize.InlineText(q.ProofURL)))
		}
	}
	if q.Note != "" {
		b.WriteString(ufmt.Sprintf("- **Note:** %s\n", sanitize.InlineText(q.Note)))
	}

	if q.Spec != "" {
		b.WriteString("\n## Spec\n")
		// HTMLEscape neutralizes inline raw HTML (Block only guards
		// line-leading hazards); Block then strips block-level injection.
		b.WriteString(sanitize.Block(sanitize.HTMLEscape(q.Spec)))
		b.WriteString("\n")
	}

	b.WriteString("\n## History\n\n")
	for _, e := range q.History {
		line := ufmt.Sprintf("- block %d — `%s` %s", e.Height, e.Actor.String(), e.Action)
		if e.Detail != "" {
			line += " — " + sanitize.InlineText(e.Detail)
		}
		b.WriteString(line + "\n")
	}

	cmds := questCommands(q, st, h)
	if len(cmds) > 0 {
		b.WriteString("\n## Commands\n\n")
		b.WriteString("Replace `<key>` with your gnokey name:\n\n")
		b.WriteString("```sh\n")
		for _, c := range cmds {
			b.WriteString(c + "\n")
		}
		b.WriteString("```\n")
	}
	b.WriteString(ufmt.Sprintf("\n[Back to the board](%s)\n", realmURL))
	res.Write(b.String())
}

func profileHandler(res *mux.ResponseWriter, req *mux.Request) {
	addrStr := req.GetVar("addr")
	a := address(addrStr)
	if !a.IsValid() {
		notFoundHandler(res, req)
		return
	}
	var b strings.Builder
	b.WriteString(ufmt.Sprintf("# `%s`\n\n", a.String()))
	p := findProfile(a)
	if p == nil {
		b.WriteString("No Guildhall activity for this address yet.\n")
		res.Write(b.String())
		return
	}
	b.WriteString(ufmt.Sprintf("- **Quests posted:** %d\n", p.Posted))
	b.WriteString(ufmt.Sprintf("- **Quests paid:** %d (%d accepted, %d auto-accepted)\n",
		p.Paid, p.Accepted, p.AutoAccepted))
	b.WriteString(ufmt.Sprintf("- **GNOT earned:** %s\n", formatGNOT(p.Earned)))
	b.WriteString(ufmt.Sprintf("- **GNOT spent:** %s\n", formatGNOT(p.Spent)))
	writeIDList(&b, "Recently posted", p.PostedIDs)
	writeIDList(&b, "Recently paid", p.PaidIDs)
	b.WriteString(ufmt.Sprintf("\n[Back to the board](%s)\n", realmURL))
	res.Write(b.String())
}

func writeIDList(b *strings.Builder, label string, ids []uint64) {
	if len(ids) == 0 {
		return
	}
	b.WriteString(ufmt.Sprintf("\n## %s\n\n", label))
	start := len(ids) - 20
	if start < 0 {
		start = 0
	}
	for i := len(ids) - 1; i >= start; i-- {
		b.WriteString(ufmt.Sprintf("- [quest %d](%s:q/%d)\n", ids[i], realmURL, ids[i]))
	}
}

func aboutHandler(res *mux.ResponseWriter, req *mux.Request) {
	res.Write(`# About Guildhall

Guildhall is a bounty board on gno.land. Post a quest, lock the GNOT, and
the realm pays whoever does the work, human or agent.

## How it works

1. A poster calls ` + "`Post`" + ` with the reward attached. The realm escrows it.
2. A worker calls ` + "`Claim`" + ` and gets a lease of ` + "`LeaseBlocks`" + ` blocks.
3. The worker calls ` + "`Submit`" + ` with a proof link before the lease ends.
4. The poster calls ` + "`Accept`" + ` to pay, or ` + "`Reject`" + ` inside the
   review window to send the quest back to the board.
5. If the poster says nothing for ` + "`ReviewBlocks`" + ` blocks, the worker
   calls ` + "`ClaimPayout`" + ` and silence counts as acceptance.

## The rules

- A claim lasts LeaseBlocks; once it lapses anyone may claim again.
- While a submission is pending the quest cannot be refunded or cancelled.
- After Deadline the poster may Refund an open or stale-claimed quest.
- Cancel works while the quest is open and returns the escrow at once.
- The poster can never claim their own quest.

## State machine

` + "`open → claimed → submitted → paid`" + `

- ` + "`submitted → open`" + ` (rejected inside the review window)
- ` + "`claimed → open`" + ` (lease expired; shows as open again)
- ` + "`open → refunded`" + ` (poster, after the deadline)
- ` + "`open → cancelled`" + ` (poster, any time before a live claim)

## Import the state machine

` + "```" + `
import "gno.land/p/nym-ololade001/guild/v0"
` + "```" + `

[Back to the board](` + realmURL + `)
`)
}

func notFoundHandler(res *mux.ResponseWriter, req *mux.Request) {
	res.Write("# Not found\n\nNothing lives at this path. [Back to the board](" + realmURL + ")\n")
}

// questCommands lists the gnokey calls that make sense right now.
func questCommands(q *guild.Quest, st guild.Status, h int64) []string {
	id := ufmt.Sprintf("%d", q.ID)
	call := func(fn string, extra ...string) string {
		s := "gnokey maketx call -pkgpath " + realmPath + " -func " + fn + " -args " + id
		for _, a := range extra {
			s += " -args " + a
		}
		return s + " -gas-fee 1000000ugnot -gas-wanted 50000000" +
			" -chainid " + chainID + " -remote " + rpcURL + " <key>"
	}
	var cmds []string
	switch st {
	case guild.Open:
		if h < q.Deadline {
			cmds = append(cmds, call("Claim"))
		}
		if h >= q.Deadline {
			cmds = append(cmds, call("Refund"))
		}
		cmds = append(cmds, call("Cancel"))
	case guild.Claimed:
		cmds = append(cmds, call("Submit", `"<proofURL>"`, `"<note>"`))
	case guild.Submitted:
		if h <= q.ReviewEnd() {
			cmds = append(cmds, call("Accept"), call("Reject", `"<reason>"`))
		} else {
			cmds = append(cmds, call("Accept"), call("ClaimPayout"))
		}
	}
	return cmds
}

// sortByRewardDesc orders quests by reward, highest first, then by id.
func sortByRewardDesc(qs []*guild.Quest) {
	for i := 1; i < len(qs); i++ {
		for j := i; j > 0; j-- {
			a, b := qs[j-1], qs[j]
			if a.Reward > b.Reward || (a.Reward == b.Reward && a.ID < b.ID) {
				break
			}
			qs[j-1], qs[j] = qs[j], qs[j-1]
		}
	}
}

// formatGNOT renders ugnot as GNOT with up to six decimals, trimmed.
func formatGNOT(amt int64) string {
	whole := amt / 1000000
	frac := amt % 1000000
	if frac == 0 {
		return ufmt.Sprintf("%d GNOT", whole)
	}
	fs := strconv.FormatInt(frac, 10)
	for len(fs) < 6 {
		fs = "0" + fs
	}
	fs = strings.TrimRight(fs, "0")
	return ufmt.Sprintf("%d.%s GNOT", whole, fs)
}
