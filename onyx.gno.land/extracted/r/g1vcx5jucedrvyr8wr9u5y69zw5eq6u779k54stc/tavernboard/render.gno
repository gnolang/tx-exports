package tavernboard

import (
	"chain/runtime"
	"strconv"
	"strings"
)

// RealmPath is the on-chain path of this realm (set at deploy time).
const RealmPath = "gno.land/r/g1vcx5jucedrvyr8wr9u5y69zw5eq6u779k54stc/tavernboard"

// formatGnot renders an ugnot amount as human-readable GNOT
// (1 GNOT = 1,000,000 ugnot), trimming trailing zeros.
func formatGnot(ugnot int64) string {
	whole := ugnot / 1000000
	frac := ugnot % 1000000
	if frac < 0 {
		frac = -frac
	}
	if frac == 0 {
		return strconv.FormatInt(whole, 10) + " GNOT"
	}
	fracStr := strconv.FormatInt(frac, 10)
	for len(fracStr) < 6 {
		fracStr = "0" + fracStr
	}
	fracStr = strings.TrimRight(fracStr, "0")
	return strconv.FormatInt(whole, 10) + "." + fracStr + " GNOT"
}

// shortAddr shortens a bech32 address for display.
func shortAddr(a address) string {
	s := a.String()
	if len(s) <= 16 {
		return s
	}
	return s[:10] + "..." + s[len(s)-6:]
}

// sanitize strips characters that could break Markdown tables or inject
// links/images from user-supplied text (titles, descriptions, proofs).
// It replaces them with a space so nothing is silently concatenated.
func sanitize(s string) string {
	s = strings.ReplaceAll(s, "|", " ")
	s = strings.ReplaceAll(s, "\n", " ")
	s = strings.ReplaceAll(s, "\r", " ")
	s = strings.ReplaceAll(s, "[", "(")
	s = strings.ReplaceAll(s, "]", ")")
	s = strings.ReplaceAll(s, "`", "'")
	s = strings.ReplaceAll(s, "<", "(")
	s = strings.ReplaceAll(s, ">", ")")
	return s
}

// deadlineText renders a task deadline as a block height or "none".
func deadlineText(deadline int64) string {
	if deadline == 0 {
		return "none"
	}
	return "block " + strconv.FormatInt(deadline, 10)
}

// Render serves the realm's web UI (gnoweb renders the returned Markdown).
// Routes: "" (home), "task/<id>", "stats", "guide".
func Render(path string) string {
	trimmed := strings.Trim(path, "/")
	switch {
	case trimmed == "":
		return renderHome()
	case trimmed == "stats":
		return renderStats()
	case trimmed == "guide":
		return renderGuide()
	case strings.HasPrefix(trimmed, "task/"):
		idStr := strings.TrimPrefix(trimmed, "task/")
		id, err := strconv.ParseInt(idStr, 10, 64)
		if err != nil {
			return "# Invalid Task ID\n\nExpected `/task/<numeric-id>`."
		}
		return renderTask(id)
	default:
		return "# 404 — Route Not Found\n\nAvailable routes: [Home](?) | [Stats](?:stats) | [Guide](?:guide)"
	}
}

func renderHome() string {
	var b strings.Builder
	b.WriteString("# 🍺 Tavern Board — Open Task Board with GNOT Escrow\n\n")
	b.WriteString("Post a task, lock its reward in escrow, and let anyone in the tavern claim it. ")
	b.WriteString("The worker submits proof, you approve, and the escrow pays out — all on-chain, no middleman.\n\n")
	b.WriteString("[Open Tasks](?) | [Stats](?:stats) | [How to Use](?:guide)\n\n")

	open, claimed, submitted, done, cancelled, expired, locked, paid, refunded, deposited := Stats()
	b.WriteString("## Live Board Snapshot\n\n")
	b.WriteString("| Metric | Value |\n|---|---|\n")
	b.WriteString("| Tasks ever posted | " + strconv.FormatInt(TaskCount(), 10) + " |\n")
	b.WriteString("| Open | " + strconv.FormatInt(open, 10) + " |\n")
	b.WriteString("| Claimed (in progress) | " + strconv.FormatInt(claimed, 10) + " |\n")
	b.WriteString("| Awaiting approval | " + strconv.FormatInt(submitted, 10) + " |\n")
	b.WriteString("| Done | " + strconv.FormatInt(done, 10) + " |\n")
	b.WriteString("| Cancelled | " + strconv.FormatInt(cancelled, 10) + " |\n")
	b.WriteString("| Expired | " + strconv.FormatInt(expired, 10) + " |\n")
	b.WriteString("| Escrowed right now | **" + formatGnot(locked) + "** |\n")
	b.WriteString("| Paid out to workers | " + formatGnot(paid) + " |\n")
	b.WriteString("| Refunded to posters | " + formatGnot(refunded) + " |\n")
	b.WriteString("| Ever deposited | " + formatGnot(deposited) + " |\n\n")
	b.WriteString("Current block height: **" + strconv.FormatInt(runtime.ChainHeight(), 10) + "** (deadlines are block heights — post with a deadline above this number).\n\n")

	b.WriteString("## Open Tasks\n\n")
	openTasks := ListTasks(int64(StatusOpen), 20)
	if len(openTasks) == 0 {
		b.WriteString("_No open tasks right now — post the first one from the [guide](?:guide)._\n\n")
	} else {
		b.WriteString("| ID | Task | Reward | Deadline |\n|---|---|---|---|\n")
		for _, task := range openTasks {
			b.WriteString("| [" + strconv.FormatInt(task.ID, 10) + "](?:task/" + strconv.FormatInt(task.ID, 10) + ") | " + sanitize(task.Title) + " | " + formatGnot(task.Reward) + " | " + deadlineText(task.Deadline) + " |\n")
		}
		b.WriteString("\n")
	}

	b.WriteString("## How it works\n\n")
	b.WriteString("1. **Post** a task with GNOT attached — the reward is escrowed in this realm.\n")
	b.WriteString("2. **Claim** an open task (anyone except the poster).\n")
	b.WriteString("3. **Submit proof** of the work (text + link).\n")
	b.WriteString("4. **Approve** — the poster releases the escrow to the worker.\n")
	b.WriteString("5. If a deadline passes unfinished, **anyone** can release the escrow back to the poster.\n\n")
	b.WriteString("Full commands: [guide](?:guide). Escrow accounting: [stats](?:stats).\n")
	return b.String()
}

func renderTask(id int64) string {
	var b strings.Builder
	task, ok := tasks[id]
	if !ok {
		return "# Task Not Found\n\nNo task with ID " + strconv.FormatInt(id, 10) + " exists on this board."
	}
	b.WriteString("# Task #" + strconv.FormatInt(task.ID, 10) + " — " + sanitize(task.Title) + "\n\n")
	b.WriteString("| Field | Value |\n|---|---|\n")
	b.WriteString("| Status | **" + task.Status.String() + "** |\n")
	b.WriteString("| Poster | " + shortAddr(task.Poster) + " |\n")
	b.WriteString("| Worker | " + workerText(task.Worker) + " |\n")
	b.WriteString("| Reward (escrowed) | **" + formatGnot(task.Reward) + "** (" + strconv.FormatInt(task.Reward, 10) + " ugnot) |\n")
	b.WriteString("| Deadline | " + deadlineText(task.Deadline) + " |\n")
	b.WriteString("| Posted at | block " + strconv.FormatInt(task.CreatedAt, 10) + " |\n")
	if task.Proof != "" {
		b.WriteString("| Proof | " + sanitize(task.Proof) + " |\n")
	}
	b.WriteString("\n## Description\n\n" + sanitize(task.Description) + "\n\n")
	b.WriteString("## Next steps\n\n")
	switch task.Status {
	case StatusOpen:
		b.WriteString("This task is open. Claim it with:\n\n```\ngnokey maketx call -pkgpath \"" + RealmPath + "\" -func \"ClaimTask\" -args \"" + strconv.FormatInt(task.ID, 10) + "\" -gas-fee 2000ugnot -gas-wanted 2000000 -chainid onyx-1 -remote https://rpc.onyx.testnets.gno.land:443 <your-key>\n```\n")
	case StatusClaimed:
		b.WriteString("This task is claimed and in progress. The worker submits proof with `SubmitProof`. If the worker steps back, `Unclaim` re-opens it.\n")
	case StatusSubmitted:
		b.WriteString("Proof has been submitted and awaits the poster's decision: `Approve` releases the escrow to the worker, `RejectProof` sends it back for rework.\n")
	case StatusDone:
		b.WriteString("Completed — the escrow was paid to the worker. 🎉\n")
	case StatusCancelled:
		b.WriteString("Cancelled by the poster — the escrow was refunded in full.\n")
	case StatusExpired:
		b.WriteString("The deadline passed unfinished — the escrow was refunded to the poster.\n")
	}
	b.WriteString("\n[← Back to the board](?)\n")
	return b.String()
}

// workerText renders the worker field, showing "—" while unclaimed.
func workerText(w address) string {
	if w == emptyAddress {
		return "— (unclaimed)"
	}
	return shortAddr(w)
}

func renderStats() string {
	var b strings.Builder
	b.WriteString("# 📊 Tavern Board — Escrow Accounting\n\n")
	b.WriteString("Every ugnot escrowed in this realm has exactly one reachable destination: the worker (on approval) or the poster (on cancel/expiry). The invariant below is checked on every render.\n\n")
	open, claimed, submitted, done, cancelled, expired, locked, paid, refunded, deposited := Stats()
	b.WriteString("| Metric | Value |\n|---|---|\n")
	b.WriteString("| Tasks ever posted | " + strconv.FormatInt(TaskCount(), 10) + " |\n")
	b.WriteString("| Open | " + strconv.FormatInt(open, 10) + " |\n")
	b.WriteString("| Claimed | " + strconv.FormatInt(claimed, 10) + " |\n")
	b.WriteString("| Submitted | " + strconv.FormatInt(submitted, 10) + " |\n")
	b.WriteString("| Done | " + strconv.FormatInt(done, 10) + " |\n")
	b.WriteString("| Cancelled | " + strconv.FormatInt(cancelled, 10) + " |\n")
	b.WriteString("| Expired | " + strconv.FormatInt(expired, 10) + " |\n")
	b.WriteString("| Locked (escrow) | " + formatGnot(locked) + " (" + strconv.FormatInt(locked, 10) + " ugnot) |\n")
	b.WriteString("| Paid to workers | " + formatGnot(paid) + " (" + strconv.FormatInt(paid, 10) + " ugnot) |\n")
	b.WriteString("| Refunded to posters | " + formatGnot(refunded) + " (" + strconv.FormatInt(refunded, 10) + " ugnot) |\n")
	b.WriteString("| Ever deposited | " + formatGnot(deposited) + " (" + strconv.FormatInt(deposited, 10) + " ugnot) |\n\n")

	// Independent cross-check: locked recomputed from task statuses.
	byStatus := lockedByStatus()
	b.WriteString("## Conservation invariant\n\n")
	b.WriteString("`locked + paid + refunded == deposited`\n\n")
	b.WriteString("| Check | Value |\n|---|---|\n")
	b.WriteString("| locked (accounting totals) | " + strconv.FormatInt(locked, 10) + " ugnot |\n")
	b.WriteString("| locked (sum of open task rewards) | " + strconv.FormatInt(byStatus, 10) + " ugnot |\n")
	b.WriteString("| locked + paid + refunded | " + strconv.FormatInt(locked+paid+refunded, 10) + " ugnot |\n")
	b.WriteString("| deposited | " + strconv.FormatInt(deposited, 10) + " ugnot |\n\n")
	if locked == byStatus && locked+paid+refunded == deposited {
		b.WriteString("**✅ Invariant holds: PASS** — no ugnot is missing or unaccounted for.\n")
	} else {
		b.WriteString("**❌ Invariant MISMATCH** — accounting and task state disagree; do not trust this board until fixed.\n")
	}
	b.WriteString("\n[← Back to the board](?)\n")
	return b.String()
}

func renderGuide() string {
	var b strings.Builder
	b.WriteString("# 🧭 How to Use Tavern Board\n\n")
	b.WriteString("Realm: `" + RealmPath + "` — testnet Onyx (`onyx-1`), web: https://onyx.testnets.gno.land/r/g1vcx5jucedrvyr8wr9u5y69zw5eq6u779k54stc/tavernboard\n\n")
	b.WriteString("All commands use `gnokey` against the Onyx RPC. Replace `<your-key>` with your key name. 1 GNOT = 1,000,000 ugnot.\n\n")
	b.WriteString("## 1. Post a task (escrow the reward)\n\n")
	b.WriteString("Attach the reward with `-send`. The deadline is a block height (`0` = no deadline).\n\n```\ngnokey maketx call -pkgpath \"" + RealmPath + "\" -func \"PostTask\" -args \"Write a README for my realm\" -args \"One page, English, with setup steps\" -args \"0\" -send 5000000ugnot -gas-fee 2000ugnot -gas-wanted 2000000 -chainid onyx-1 -remote https://rpc.onyx.testnets.gno.land:443 <your-key>\n```\n\n")
	b.WriteString("## 2. Claim an open task\n\n```\ngnokey maketx call -pkgpath \"" + RealmPath + "\" -func \"ClaimTask\" -args \"1\" -gas-fee 2000ugnot -gas-wanted 2000000 -chainid onyx-1 -remote https://rpc.onyx.testnets.gno.land:443 <your-key>\n```\n\n")
	b.WriteString("## 3. Submit proof of work\n\n```\ngnokey maketx call -pkgpath \"" + RealmPath + "\" -func \"SubmitProof\" -args \"1\" -args \"Done: https://github.com/example/repo/pull/7\" -gas-fee 2000ugnot -gas-wanted 2000000 -chainid onyx-1 -remote https://rpc.onyx.testnets.gno.land:443 <your-key>\n```\n\n")
	b.WriteString("## 4. Approve (poster) — releases the escrow to the worker\n\n```\ngnokey maketx call -pkgpath \"" + RealmPath + "\" -func \"Approve\" -args \"1\" -gas-fee 2000ugnot -gas-wanted 2000000 -chainid onyx-1 -remote https://rpc.onyx.testnets.gno.land:443 <your-key>\n```\n\n")
	b.WriteString("If the proof is not good enough, the poster can send it back with `RejectProof` (worker may submit again).\n\n")
	b.WriteString("## 5. Cancel / expire — refunds go back to the poster\n\n```\n# Cancel an OPEN task you posted:\ngnokey maketx call -pkgpath \"" + RealmPath + "\" -func \"CancelTask\" -args \"2\" -gas-fee 2000ugnot -gas-wanted 2000000 -chainid onyx-1 -remote https://rpc.onyx.testnets.gno.land:443 <your-key>\n\n# Release escrow of a task past its deadline (anyone may call):\ngnokey maketx call -pkgpath \"" + RealmPath + "\" -func \"ReleaseExpired\" -args \"3\" -gas-fee 2000ugnot -gas-wanted 2000000 -chainid onyx-1 -remote https://rpc.onyx.testnets.gno.land:443 <your-key>\n\n# Step back from a task you claimed (before submitting proof):\ngnokey maketx call -pkgpath \"" + RealmPath + "\" -func \"Unclaim\" -args \"1\" -gas-fee 2000ugnot -gas-wanted 2000000 -chainid onyx-1 -remote https://rpc.onyx.testnets.gno.land:443 <your-key>\n```\n\n")
	b.WriteString("## Read-only queries (no gas, no key needed)\n\n```\ngnokey query vm/qeval -remote https://rpc.onyx.testnets.gno.land:443 -data '" + RealmPath + ".TaskCount()'\ngnokey query vm/qeval -remote https://rpc.onyx.testnets.gno.land:443 -data '" + RealmPath + ".Stats()'\n```\n\n")
	b.WriteString("Get free testnet GNOT at https://faucet.gno.land (paste your `g1...` address, pick Onyx).\n\n[← Back to the board](?)\n")
	return b.String()
}
