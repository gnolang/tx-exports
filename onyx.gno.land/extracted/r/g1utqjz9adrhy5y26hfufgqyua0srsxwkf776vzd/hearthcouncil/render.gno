package hearthcouncil

// Render is the DAO's UI for gnoweb: proposal list, per-proposal detail,
// and the delegation overview. All user-supplied text (titles,
// descriptions) is sanitized before being printed.

import (
	"strconv"
	"strings"

	"gno.land/p/nt/markdown/sanitize/v0"
	"gno.land/p/nt/ufmt/v0"
	"gno.land/r/g1utqjz9adrhy5y26hfufgqyua0srsxwkf776vzd/hearth"
	"chain/runtime"
)

func Render(path string) string {
	// Detail view: the proposal id arrives as the URL args after ":",
	// e.g. /r/.../hearthcouncil:0 . A leading "/" is tolerated.
	idStr := strings.TrimPrefix(path, "/")
	if idStr != "" {
		if id, err := strconv.Atoi(idStr); err == nil && id >= 0 {
			return renderProposal(uint64(id))
		}
	}
	return renderList()
}

func renderList() string {
	out := "# HearthCouncil — DAO voting realm\n\n"
	out += "Vote weight comes from HEARTH escrowed in this realm (Deposit\n"
	out += "after Approving the DAO on the HEARTH token). Delegation is one\n"
	out += "level: your delegate votes with your deposit.\n\n"
	out += ufmt.Sprintf("- HEARTH total supply: %d\n", hearth.TotalSupply())
	out += ufmt.Sprintf("- Escrowed in the DAO: %d HEARTH\n", TotalDeposited())
	out += ufmt.Sprintf("- Treasury (spendable): %d HEARTH\n", Treasury())
	out += ufmt.Sprintf("- Proposals: %d\n", ProposalCount())
	out += ufmt.Sprintf("- Quorum: %d%% of supply at proposal creation\n", QuorumBps/100)
	out += ufmt.Sprintf("- Voting period: %d blocks, timelock: %d blocks\n", VotingPeriod, TimelockDelay)
	out += ufmt.Sprintf("- Current height: %d\n", runtime.ChainHeight())
	out += "\n## Proposals\n\n"
	if ProposalCount() == 0 {
		out += "No proposals yet. Hold at least 100 HEARTH and call\n"
		out += "CreateProposal to open the first one.\n"
		return out
	}
	out += "| ID | Title | Status | For | Against | Quorum |\n"
	out += "|----|-------|--------|-----|---------|--------|\n"
	proposals.Iterate("", "", func(key string, value any) bool {
		p := value.(*Proposal)
		quorum := "—"
		if p.Quorum > 0 {
			quorum = ufmt.Sprintf("%d%%", (p.ForVotes+p.AgainstVotes)*100/p.Quorum)
		}
		out += ufmt.Sprintf("| %d | %s | %s | %d | %d | %s |\n",
			p.ID, sanitize.InlineText(p.Title), p.Status.String(),
			p.ForVotes, p.AgainstVotes, quorum)
		return false
	})
	out += "\nOpen a proposal's detail page by appending :<id> to this realm's URL (e.g. .../hearthcouncil:0).\n"
	return out
}

func renderProposal(id uint64) string {
	if !proposals.Has(pkey(id)) {
		return ufmt.Sprintf("# Proposal #%d — not found\n\nNo proposal with this ID exists yet.\n", id)
	}
	p := mustProposal(id)
	out := ufmt.Sprintf("# Proposal #%d — %s\n\n", p.ID, sanitize.InlineText(p.Title))
	out += ufmt.Sprintf("- Status: **%s**\n", p.Status.String())
	out += ufmt.Sprintf("- Proposer: %s\n", p.Proposer.String())
	out += ufmt.Sprintf("- Action: %s (target: %s)\n", p.Action, p.Target)
	out += ufmt.Sprintf("- Args: %s\n", sanitize.InlineText(p.Args))
	out += ufmt.Sprintf("- Voting: heights %d–%d (now: %d)\n", p.StartHeight, p.EndHeight, runtime.ChainHeight())
	out += ufmt.Sprintf("- For: %d, Against: %d, Quorum needed: %d\n", p.ForVotes, p.AgainstVotes, p.Quorum)
	if p.Status == StatusQueued {
		out += ufmt.Sprintf("- Timelock ETA: height %d (now: %d)\n", p.ETA, runtime.ChainHeight())
	}
	if p.Status == StatusExecuted {
		out += ufmt.Sprintf("- Executed at height: %d\n", p.ExecutedAt)
	}
	out += "\n## Description\n\n"
	out += sanitize.Block(p.Description)
	out += "\n\n## How to vote\n\n"
	out += "1. Get HEARTH from the hearth realm (Claim or Faucet).\n"
	out += "2. Approve this realm on the HEARTH token, then Deposit.\n"
	out += "3. Call Vote with this proposal's ID and your support (true/false).\n"
	out += "4. After voting ends, anyone may call Finalize, then Queue,\n"
	out += "   then Execute once the timelock expires.\n"
	return out
}
