package strongbox

import (
	"strconv"
	"strings"
)

// Pages list at most this many items per section, newest first, so that
// rendering stays cheap however much a vault is used.
const (
	maxListed       = 25
	maxVaultsListed = 50
)

// Render serves the gnoweb pages:
//
//	""                 home: what Strongbox is and all vaults
//	"vault/{id}"       one vault: signers, balance, proposals, deposits
//	"signer/{address}" the vaults an address signs for
func Render(path string) string {
	parts := strings.Split(strings.Trim(path, "/"), "/")
	switch {
	case path == "":
		return renderHome()
	case len(parts) == 2 && parts[0] == "vault":
		id, err := strconv.Atoi(parts[1])
		if err != nil {
			return "# Not found\n\nVault ids are numbers."
		}
		v, ok := getVault(id)
		if !ok {
			return "# Not found\n\nThere is no vault " + parts[1] + ".\n\n[Back to all vaults](" + realmURL("") + ")"
		}
		return renderVault(v)
	case len(parts) == 2 && parts[0] == "signer":
		a := normalize(address(parts[1]))
		if !a.IsValid() {
			return "# Not found\n\nThat is not a valid address.\n\n[Back to all vaults](" + realmURL("") + ")"
		}
		return renderSigner(a)
	}
	return "# Not found\n\n[Back to all vaults](" + realmURL("") + ")"
}

func renderHome() string {
	var b strings.Builder
	b.WriteString("# Strongbox\n\n")
	b.WriteString("Multisig team treasuries on gno.land. A team creates a vault with its signers and a threshold, ")
	b.WriteString("for example 2-of-3. Anyone can fund it with GNOT. Any signer can propose a payout, ")
	b.WriteString("and it is sent as soon as enough signers approve. No single person can move the money.\n\n")

	b.WriteString("[Create a vault](" + helpURL("CreateVault", "") + ")")
	b.WriteString(" · Find your vaults: `" + realmURL("signer/") + "<your address>`\n\n")

	b.WriteString("## Vaults\n\n")
	if vaults.Size() == 0 {
		b.WriteString("No vaults yet. Be the first.\n")
		return b.String()
	}
	b.WriteString("| Vault | Rule | Balance | Open proposals | Paid out |\n")
	b.WriteString("| --- | --- | --- | --- | --- |\n")
	// Newest first.
	shown := 0
	vaults.ReverseIterate("", "", func(_ string, raw any) bool {
		if shown == maxVaultsListed {
			return true
		}
		shown++
		v := raw.(*Vault)
		open, paid := len(v.Pending), v.PaidTotal
		b.WriteString("| [#" + strconv.Itoa(v.ID) + " " + esc(v.Name) + "](" + vaultURL(v.ID) + ") | ")
		b.WriteString(strconv.Itoa(v.Threshold) + "-of-" + strconv.Itoa(len(v.Signers)) + " | ")
		b.WriteString(formatGNOT(v.Balance) + " | " + strconv.Itoa(open) + " | " + formatGNOT(paid) + " |\n")
		return false
	})
	if more := vaults.Size() - shown; more > 0 {
		b.WriteString("\n" + strconv.Itoa(more) + " older vaults not shown. Open one directly at `" + realmURL("vault/") + "<id>`.\n")
	}
	return b.String()
}

func renderVault(v *Vault) string {
	var b strings.Builder
	id := strconv.Itoa(v.ID)
	b.WriteString("[All vaults](" + realmURL("") + ")\n\n")
	b.WriteString("# " + esc(v.Name) + "\n\n")
	b.WriteString("**Balance: " + formatGNOT(v.Balance) + "** · ")
	b.WriteString("payouts need **" + strconv.Itoa(v.Threshold) + " of " + strconv.Itoa(len(v.Signers)) + "** signers\n\n")
	b.WriteString("[Deposit](" + helpURL("Deposit", "&vaultID="+id) + ") · ")
	b.WriteString("[Propose a payout](" + helpURL("Propose", "&vaultID="+id) + ")\n\n")

	b.WriteString("## Signers\n\n")
	for _, s := range v.Signers {
		b.WriteString("- " + addrLink(s))
		if s == v.Creator {
			b.WriteString(" (creator)")
		}
		b.WriteString("\n")
	}

	// Newest first. Only pending ids and the newest closed proposals are
	// read, so the cost does not grow with the vault's history.
	pending := []*Proposal{}
	for i := len(v.Pending) - 1; i >= 0 && len(pending) < maxListed; i-- {
		pending = append(pending, getProposal(v, v.Pending[i]))
	}
	closedTotal := v.ProposalCount - len(v.Pending)
	closed := []*Proposal{}
	v.Proposals.ReverseIterate("", "", func(_ string, raw any) bool {
		if p := raw.(*Proposal); p.Status != StatusPending {
			closed = append(closed, p)
		}
		return len(closed) == maxListed
	})

	b.WriteString("\n## Waiting for approval\n\n")
	if len(pending) == 0 {
		b.WriteString("Nothing pending.\n")
	}
	for _, p := range pending {
		pid := strconv.Itoa(p.ID)
		args := "&vaultID=" + id + "&proposalID=" + pid
		b.WriteString("### #" + pid + " · " + formatGNOT(p.Amount) + " to " + short(p.To) + "\n\n")
		if p.Memo != "" {
			b.WriteString("> " + esc(p.Memo) + "\n\n")
		}
		b.WriteString("Approvals: **" + strconv.Itoa(len(p.Approvals)) + "/" + strconv.Itoa(v.Threshold) + "** ")
		b.WriteString(progress(len(p.Approvals), v.Threshold) + "\n\n")
		for _, s := range v.Signers {
			mark := "⬜"
			if contains(p.Approvals, s) {
				mark = "✅"
			}
			b.WriteString("- " + mark + " " + addrLink(s) + "\n")
		}
		b.WriteString("\n")
		if len(p.Approvals) >= v.Threshold && v.Balance < p.Amount {
			b.WriteString("⚠️ **Approved, but the vault is short " + formatGNOT(p.Amount-v.Balance) + ".** ")
			b.WriteString("Any signer can [execute](" + helpURL("Execute", args) + ") it as soon as the vault holds enough, ")
			b.WriteString("including from deposits meant for something else. If it should not be paid any more, revoke your approval or ask the proposer to cancel it.\n\n")
		}
		b.WriteString("Proposed by " + addrLink(p.Proposer) + " at block " + strconv.FormatInt(p.CreatedAt, 10) + " · ")
		b.WriteString("[Approve](" + helpURL("Approve", args) + ") · ")
		b.WriteString("[Revoke](" + helpURL("Revoke", args) + ") · ")
		b.WriteString("[Cancel](" + helpURL("Cancel", args) + ")\n\n")
	}
	if len(v.Pending) > len(pending) {
		b.WriteString(more(len(v.Pending)-len(pending), "older pending proposals"))
	}

	b.WriteString("## History\n\n")
	if closedTotal == 0 {
		b.WriteString("No payouts yet.\n")
	} else {
		b.WriteString("| # | Status | Amount | To | Memo | Block |\n| --- | --- | --- | --- | --- | --- |\n")
		for _, p := range closed {
			b.WriteString("| " + strconv.Itoa(p.ID) + " | " + p.Status.String() + " | " + formatGNOT(p.Amount) + " | ")
			b.WriteString(addrLink(p.To) + " | " + esc(p.Memo) + " | " + strconv.FormatInt(p.ClosedAt, 10) + " |\n")
		}
		if closedTotal > len(closed) {
			b.WriteString(more(closedTotal-len(closed), "older entries"))
		}
	}

	b.WriteString("\n## Deposits\n\n")
	if v.InflowCount == 0 {
		b.WriteString("No deposits yet.\n")
	} else {
		b.WriteString("| From | Amount | Block |\n| --- | --- | --- |\n")
		v.Inflows.ReverseIterateByOffset(0, maxListed, func(_ string, raw any) bool {
			in := raw.(Inflow)
			b.WriteString("| " + addrLink(in.From) + " | " + formatGNOT(in.Amount) + " | " + strconv.FormatInt(in.Height, 10) + " |\n")
			return false
		})
		if v.InflowCount > maxListed {
			b.WriteString(more(v.InflowCount-maxListed, "older deposits"))
		}
	}
	return b.String()
}

func renderSigner(a address) string {
	var b strings.Builder
	b.WriteString("[All vaults](" + realmURL("") + ")\n\n")
	b.WriteString("# Vaults signed by " + short(a) + "\n\n")
	total, _ := signerCount.Get(a.String()).(int)
	if total == 0 {
		b.WriteString("This address does not sign any vault.\n")
		return b.String()
	}
	// Newest first. Keys are "<address>/<padded id>"; "0" sorts right after "/".
	prefix := a.String() + "/"
	ids := []int{}
	bySigner.ReverseIterate(prefix, a.String()+"0", func(k string, _ any) bool {
		id, _ := strconv.Atoi(strings.TrimLeft(k[len(prefix):], "0"))
		ids = append(ids, id)
		return len(ids) == maxVaultsListed
	})
	for _, id := range ids {
		v, _ := getVault(id)
		// Check at most the newest maxListed pending proposals per vault.
		waiting, checked := 0, 0
		for i := len(v.Pending) - 1; i >= 0 && checked < maxListed; i-- {
			checked++
			if !contains(getProposal(v, v.Pending[i]).Approvals, a) {
				waiting++
			}
		}
		b.WriteString("- [#" + strconv.Itoa(v.ID) + " " + esc(v.Name) + "](" + vaultURL(v.ID) + ") · " + formatGNOT(v.Balance))
		if waiting > 0 {
			n := strconv.Itoa(waiting)
			if len(v.Pending) > checked {
				n += "+"
			}
			b.WriteString(" · **" + n + " waiting for your approval**")
		}
		b.WriteString("\n")
	}
	if total > len(ids) {
		b.WriteString(more(total-len(ids), "older vaults"))
	}
	return b.String()
}

// ---------------------------------------------------------------------------
// Formatting helpers

func more(n int, what string) string {
	return "\n…and " + strconv.Itoa(n) + " " + what + " not shown.\n"
}

// formatGNOT turns ugnot into a GNOT string: 1500000 -> "1.5 GNOT".
func formatGNOT(ugnot int64) string {
	neg := ugnot < 0
	if neg {
		ugnot = -ugnot
	}
	whole := strconv.FormatInt(ugnot/1_000_000, 10)
	frac := ugnot % 1_000_000
	s := whole
	if frac != 0 {
		f := strconv.FormatInt(frac, 10)
		f = strings.Repeat("0", 6-len(f)) + f
		s += "." + strings.TrimRight(f, "0")
	}
	if neg {
		s = "-" + s
	}
	return s + " GNOT"
}

func progress(have, need int) string {
	if have > need {
		have = need
	}
	return strings.Repeat("●", have) + strings.Repeat("○", need-have)
}

func short(a address) string {
	s := a.String()
	if len(s) <= 14 {
		return s
	}
	return s[:8] + "…" + s[len(s)-4:]
}

func addrLink(a address) string {
	return "[" + short(a) + "](" + realmURL("signer/"+a.String()) + ")"
}

// esc neutralizes markdown and HTML in user-supplied text.
func esc(s string) string {
	var b strings.Builder
	for _, r := range s {
		switch r {
		case '\n', '\r', '\t':
			b.WriteRune(' ')
		case '\\', '`', '*', '_', '[', ']', '(', ')', '#', '|', '<', '>', '!', '~':
			b.WriteRune('\\')
			b.WriteRune(r)
		default:
			b.WriteRune(r)
		}
	}
	return b.String()
}

// realmURL gives the gnoweb link for a render path of this realm.
func realmURL(sub string) string {
	base := strings.TrimPrefix(pkgPath, "gno.land")
	if sub == "" {
		return base
	}
	return base + ":" + sub
}

func vaultURL(id int) string { return realmURL("vault/" + strconv.Itoa(id)) }

// helpURL links to gnoweb's transaction form for fn, with args prefilled.
func helpURL(fn, args string) string {
	return strings.TrimPrefix(pkgPath, "gno.land") + "$help&func=" + fn + args
}
