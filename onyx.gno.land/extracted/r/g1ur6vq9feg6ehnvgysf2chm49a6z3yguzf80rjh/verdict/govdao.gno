package verdict

import (
	"strconv"
	"strings"

	"gno.land/r/gov/dao"
)

// Proposal statuses as seen by Verdict.
const (
	statusActive   = "ACTIVE"
	statusAccepted = "ACCEPTED"
	statusDenied   = "DENIED"
	statusUnknown  = "UNKNOWN"
)

// govStatus returns the live status of a GovDAO proposal. It is a variable
// so tests can substitute a fake GovDAO.
var govStatus = fetchGovStatus

// fetchGovStatus reads the proposal page rendered by gno.land/r/gov/dao and
// extracts the status block.
//
// GovDAO keeps proposal statuses private to its implementation realm and
// exposes them only through Render, so Verdict reads the rendered page.
// The page is built as:
//
//	## Prop #N - <title>
//	<description>            <- written by the proposal author
//	...
//	### Stats
//	- **PROPOSAL HAS BEEN ACCEPTED** | **PROPOSAL HAS BEEN DENIED** | **Proposal is open for votes**
//	...
//	[Detailed voting list](...)
//
// The description is author-controlled, so a malicious author could paste a
// fake "### Stats" block into it. The real block is always rendered after
// the description, so we only trust the LAST "### Stats" heading, and only
// if the "[Detailed voting list]" link follows it.
//
// If GovDAO ever changes this format, parsing returns UNKNOWN: markets then
// stop accepting bets and cannot settle, and after their deadline anyone can
// call VoidExpired to refund every bettor. Funds can never be locked.
func fetchGovStatus(_ int, rlm realm, pid int64) string {
	page := dao.Render(cross(rlm), strconv.FormatInt(pid, 10))
	return parseGovStatus(page)
}

func parseGovStatus(page string) string {
	i := strings.LastIndex(page, "### Stats\n")
	if i < 0 {
		return statusUnknown
	}
	block := page[i+len("### Stats\n"):]
	if !strings.Contains(block, "[Detailed voting list](") {
		return statusUnknown
	}
	switch {
	case strings.HasPrefix(block, "- **PROPOSAL HAS BEEN ACCEPTED**"):
		return statusAccepted
	case strings.HasPrefix(block, "- **PROPOSAL HAS BEEN DENIED**"):
		return statusDenied
	case strings.HasPrefix(block, "- **Proposal is open for votes**"):
		return statusActive
	}
	return statusUnknown
}

// govTitle returns the proposal title, or "" if it can't be read.
func govTitle(pid int64) string {
	p, err := dao.GetProposal(dao.ProposalID(pid))
	if err != nil || p == nil {
		return ""
	}
	return strings.TrimSpace(strings.ReplaceAll(p.Title(), "\n", " "))
}
