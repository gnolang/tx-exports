package vault

import (
	"strconv"
	"strings"
	"time"
)

// CodeVersion is the on-chain code marker, used to confirm that a redeploy
// actually took effect.
const CodeVersion = "0.2.0"

// realmPath is the on-chain path of this package. It is needed to build absolute
// links to vault pages: gnoweb copies markdown link targets verbatim, so a bare
// "0" resolves against the parent directory and returns 404.
const realmPath = "gno.land/r/g1rq2w5mqrlw8lnjlnsqcwf4kxejs2jxqgplxqx0/vault"

// ugnotPerGnot is the denomination ratio between the chain unit and GNOT.
const ugnotPerGnot = 1000000

// Render renders the gnoweb page for the given path.
//
// Parameters:
//   - path: Empty for the vault index, or a vault ID for the detail page.
//
// Returns:
//   - string: Markdown page.
func Render(path string) string {
	if path == "" {
		return renderIndex()
	}
	id, err := strconv.Atoi(path)
	if err != nil {
		return "# GuardianVault\n\n" +
			"Path must be a vault ID, for example `:0`. Got `" + path + "`.\n\n" +
			"[All vaults](" + indexLink() + ")\n"
	}
	return renderVault(id)
}

// renderIndex renders the vault list page.
//
// Returns:
//   - string: Markdown page.
func renderIndex() string {
	out := "# GuardianVault\n\n"
	out += "A social-recovery vault. Name 1–10 guardians when you create it; if you "
	out += "lose your key, they can return the funds to the **backup address you "
	out += "registered in advance** — and they can never send them anywhere else.\n\n"

	out += "## How it works\n\n"
	out += "1. **Create** a vault, choose its guardians and the threshold of votes.\n"
	out += "2. **Deposit** ugnot. Only the owner can withdraw it.\n"
	out += "3. **Recover** if the key is lost: a guardian opens a recovery, guardians "
	out += "vote, and once the threshold is met and the window elapsed anyone can "
	out += "execute it. The balance goes to the backup address.\n"
	out += "4. **Cancel** while you still have the key: the owner can veto any "
	out += "recovery during the window.\n\n"

	if len(vaults) == 0 {
		out += "---\n\n**No vaults yet.** The first one is created with `CreateVault`.\n"
		return out + versionLine()
	}

	var total int64
	var recovering int
	for _, v := range vaults {
		total += v.Balance
		if v.State == RECOVERING {
			recovering++
		}
	}

	out += "## Vaults\n\n"
	out += "**" + countText(len(vaults), "vault") + "** · " + gnotText(total) +
		" locked · " + strconv.Itoa(recovering) + " recovering\n\n"
	out += "| Vault | Owner | Balance | State | Recovery |\n"
	out += "| --- | --- | --- | --- | --- |\n"
	for _, v := range vaults {
		out += "| [#" + strconv.Itoa(v.ID) + "](" + vaultLink(v.ID) + ") "
		out += "| `" + shortAddr(v.Owner) + "` "
		out += "| " + gnotText(v.Balance) + " "
		out += "| " + stateLabel(v) + " "
		out += "| " + indexRecoveryText(v) + " |\n"
	}

	return out + versionLine()
}

// renderVault renders the detail page of one vault.
//
// Parameters:
//   - id: Vault identifier. Returns a not-found page if it is out of range.
//
// Returns:
//   - string: Markdown page.
func renderVault(id int) string {
	if id < 0 || id >= len(vaults) {
		return "# Vault not found\n\nNo vault with ID " + strconv.Itoa(id) +
			".\n\n[All vaults](" + indexLink() + ")\n"
	}
	v := vaults[id]

	out := "# Vault #" + strconv.Itoa(v.ID) + "\n\n"
	out += "**" + stateLabel(v) + ".** " + summaryText(v) + "\n\n"

	out += "## Funds\n\n"
	out += "| | |\n| --- | --- |\n"
	out += "| Balance | **" + gnotText(v.Balance) + "** (" + commas(v.Balance) + " ugnot) |\n"
	out += "| Owner | `" + v.Owner.String() + "` |\n"
	out += "| Backup address | `" + v.BackupAddr.String() + "` |\n\n"
	out += "The backup address is where a recovery pays out. Guardians cannot "
	out += "redirect funds to themselves: the owner or the backup address are the "
	out += "only possible recipients.\n\n"

	out += "## Guardians\n\n"
	if len(v.Guardians) == 0 {
		out += "No guardians configured. The owner can set a new set with "
		out += "`SetGuardians`.\n\n"
	} else {
		out += "| Guardian | Voted |\n| --- | --- |\n"
		for _, g := range v.Guardians {
			voted := "—"
			if v.hasVoted(g) {
				voted = "voted"
			}
			out += "| `" + g.String() + "` | " + voted + " |\n"
		}
		out += "\nThreshold **" + strconv.Itoa(v.Threshold) + " of " +
			strconv.Itoa(len(v.Guardians)) + "** · window **" + windowText(v.WindowSecs) +
			"** · completed recoveries **" + strconv.Itoa(v.RecoveryCount) + "**\n\n"
		if v.Threshold == 1 && len(v.Guardians) > 1 {
			out += "> Threshold 1 means a single guardian is enough. That is a "
			out += "single point of trust, not a distributed one.\n\n"
		}
	}

	if v.State == RECOVERING {
		out += recoveryBlock(v)
	}

	out += "## What you can do\n\n"
	out += actionTable(v)

	out += "\n[All vaults](" + indexLink() + ")\n"
	return out + versionLine()
}

// recoveryBlock renders the recovery state of a vault in progress.
//
// Parameters:
//   - v: Vault in the RECOVERING state.
//
// Returns:
//   - string: Markdown section.
func recoveryBlock(v *Vault) string {
	now := time.Now().Unix()
	ends := v.RequestedAt + v.WindowSecs
	elapsed := now >= ends
	enough := len(v.Votes) >= v.Threshold

	out := "## Recovery in progress\n\n"
	if enough {
		if elapsed {
			out += "**Threshold reached and the window has elapsed — ready to execute.**\n\n"
		} else {
			out += "**Threshold reached — waiting for the window to elapse.**\n\n"
		}
	} else {
		need := v.Threshold - len(v.Votes)
		out += "**" + countText(need, "more vote") + " needed** of " +
			strconv.Itoa(v.Threshold) + ".\n\n"
	}

	out += "| | |\n| --- | --- |\n"
	out += "| Requested by | `" + v.Requestor.String() + "` |\n"
	out += "| Votes | " + strconv.Itoa(len(v.Votes)) + " of " +
		strconv.Itoa(v.Threshold) + " required |\n"
	if elapsed {
		out += "| Window | **elapsed** (" + windowText(v.WindowSecs) + " after the request) |\n"
	} else {
		out += "| Window | **" + windowText(ends-now) + " left** · ends " +
			time.Unix(ends, 0).Format("2006-01-02 15:04 MST") + " |\n"
	}
	out += "\nConfiguration changes and withdrawals are frozen until this recovery "
	out += "ends. The owner can cancel it at any time during the window.\n\n"

	return out
}

// actionTable renders the actions available to each kind of caller.
//
// Parameters:
//   - v: Vault to describe.
//
// Returns:
//   - string: Markdown table.
func actionTable(v *Vault) string {
	out := "| If you are | You can |\n| --- | --- |\n"

	if v.State == RECOVERING {
		out += "| the owner | `CancelRecovery` — veto it and reset the votes |\n"
		if len(v.Votes) < v.Threshold {
			out += "| a guardian who has not voted | `Vote` |\n"
		} else {
			out += "| a guardian | nothing more — the threshold is reached |\n"
		}
		if time.Now().Unix() >= v.RequestedAt+v.WindowSecs && len(v.Votes) >= v.Threshold {
			out += "| anyone | `Execute` — pay the balance to the backup address |\n"
		} else {
			out += "| anyone | `Execute` once the threshold is met and the window has elapsed |\n"
		}
		out += "| — | no withdrawals, no configuration changes until this ends |\n"
		return out
	}

	if len(v.Guardians) == 0 {
		out += "| the owner | `SetGuardians` to restore protection, `Deposit`, `Withdraw` |\n"
		out += "| anyone | `Deposit` |\n"
		return out
	}

	out += "| the owner | `Deposit`, `Withdraw`, `AddGuardian`, `SetGuardians`, `SetBackup` |\n"
	out += "| a guardian | `RequestRecovery` when the key is lost, then `Vote` |\n"
	out += "| anyone | `Deposit`, or `RequestRecovery` — a recovery can be opened by anyone, "
	out += "but it only succeeds with guardian votes |\n"
	return out
}

// summaryText returns the one-sentence description shown under the title.
//
// Parameters:
//   - v: Vault to describe.
//
// Returns:
//   - string: Sentence without a trailing newline.
func summaryText(v *Vault) string {
	switch {
	case v.State == RECOVERING:
		return "A recovery is open: " + strconv.Itoa(len(v.Votes)) + " of " +
			strconv.Itoa(v.Threshold) + " votes, " + recoveryTimeText(v) + "."
	case len(v.Guardians) == 0:
		return "Recovered and left unprotected: the guardian set was cleared. " +
			"The owner can configure a new one."
	default:
		return strconv.Itoa(v.Threshold) + " of " + strconv.Itoa(len(v.Guardians)) +
			" guardians must agree to recover it. A recovery stays open for " +
			windowText(v.WindowSecs) + ", during which the owner can veto it."
	}
}

// stateLabel returns the display name of a vault's state. A vault whose
// guardians were cleared by a completed recovery is reported as unprotected
// rather than as "active with threshold 0 of 0".
//
// Parameters:
//   - v: Vault to describe.
//
// Returns:
//   - string: Display name.
func stateLabel(v *Vault) string {
	if v.State == RECOVERING {
		return "Recovering"
	}
	if len(v.Guardians) == 0 {
		return "Unprotected"
	}
	return "Active"
}

// indexRecoveryText returns the recovery cell of the index table.
//
// Parameters:
//   - v: Vault to describe.
//
// Returns:
//   - string: Cell text.
func indexRecoveryText(v *Vault) string {
	if v.State != RECOVERING {
		return "—"
	}
	text := strconv.Itoa(len(v.Votes)) + " of " + strconv.Itoa(v.Threshold)
	return text + " votes · " + recoveryTimeText(v)
}

// recoveryTimeText returns the time left in the open recovery window.
//
// Parameters:
//   - v: Vault in the RECOVERING state.
//
// Returns:
//   - string: Duration or elapsed marker.
func recoveryTimeText(v *Vault) string {
	left := v.RequestedAt + v.WindowSecs - time.Now().Unix()
	if left <= 0 {
		return "window elapsed"
	}
	return windowText(left) + " left"
}

// versionLine renders the code version footer.
//
// Returns:
//   - string: Markdown line.
func versionLine() string {
	return "\n---\n\n_Live code: " + CodeVersion + "_\n"
}

// indexLink returns the path of the index page.
//
// Returns:
//   - string: Absolute path understood by gnoweb.
func indexLink() string {
	return "/" + strings.TrimPrefix(realmPath, "gno.land/")
}

// vaultLink returns the path of a vault detail page.
//
// Parameters:
//   - id: Vault identifier.
//
// Returns:
//   - string: Absolute path understood by gnoweb.
func vaultLink(id int) string {
	return indexLink() + ":" + strconv.Itoa(id)
}

// countText formats a count with a singular or plural noun.
//
// Parameters:
//   - n: Count.
//   - noun: Singular noun.
//
// Returns:
//   - string: For example "3 vaults".
func countText(n int, noun string) string {
	if n == 1 {
		return "1 " + noun
	}
	return strconv.Itoa(n) + " " + noun + "s"
}

// gnotText formats an ugnot amount as GNOT, trimming trailing zeros.
//
// Parameters:
//   - amount: Amount in ugnot.
//
// Returns:
//   - string: For example "1.5 GNOT".
func gnotText(amount int64) string {
	whole := amount / ugnotPerGnot
	frac := amount % ugnotPerGnot
	if frac == 0 {
		return commas(whole) + " GNOT"
	}
	digits := strconv.FormatInt(frac, 10)
	for len(digits) < 6 {
		digits = "0" + digits
	}
	return commas(whole) + "." + strings.TrimRight(digits, "0") + " GNOT"
}

// commas formats a non-negative integer with thousands separators.
//
// Parameters:
//   - n: Integer to format.
//
// Returns:
//   - string: For example "1500000" as "1,500,000".
func commas(n int64) string {
	s := strconv.FormatInt(n, 10)
	if len(s) <= 3 {
		return s
	}
	var out strings.Builder
	lead := len(s) % 3
	if lead > 0 {
		out.WriteString(s[:lead])
	}
	for i := lead; i < len(s); i += 3 {
		if out.Len() > 0 {
			out.WriteString(",")
		}
		out.WriteString(s[i : i+3])
	}
	return out.String()
}

// windowText formats a duration in seconds, e.g. 72 hours or 1h 30m.
//
// Parameters:
//   - secs: Duration in seconds.
//
// Returns:
//   - string: Human-readable duration.
func windowText(secs int64) string {
	h := secs / 3600
	m := (secs % 3600) / 60
	s := secs % 60

	if m == 0 && s == 0 {
		if h == 1 {
			return "1 hour"
		}
		return strconv.FormatInt(h, 10) + " hours"
	}

	out := strconv.FormatInt(h, 10) + "h"
	if m > 0 {
		out += " " + strconv.FormatInt(m, 10) + "m"
	}
	if s > 0 {
		out += " " + strconv.FormatInt(s, 10) + "s"
	}
	return out
}

// shortAddr compresses an address to the g1abc…wxyz form.
//
// Parameters:
//   - a: Address to compress.
//
// Returns:
//   - string: Compressed address.
func shortAddr(a address) string {
	s := a.String()
	if len(s) <= 12 {
		return s
	}
	return s[:8] + "…" + s[len(s)-4:]
}
