package gnome

import (
	"strconv"
	"strings"

	"gno.land/p/demo/ufmt"

	"gno.land/p/g1lyzcpa7duh69lk04nahxup484xrz4k6k2nqdun/gnome/alerts"
	gnome "gno.land/p/g1lyzcpa7duh69lk04nahxup484xrz4k6k2nqdun/gnome/dao"
)

const (
	dateFmt             = "2006-01-02 15:04 MST"
	proposalTakeoverMsg = "For the proposal outcome to change it has to be taken over by a parent DAO by voting on it"
)

// TODO: Define a pattern to add custom CSS styles
const customStyles = `
<style>
.custom ul { padding-left: 20px; }
.custom li { list-style-type: disc; }
.custom li.current { font-weight: 900; }
.custom li > p { margin: 0px; }
</style>
`

// Render returns a Markdown string with DAO or proposal details.
// By default it renders the Council DAO details view.
//
// Paths:
//   - `dao/DAO_PATH` => Renders DAO or sub DAO details
//   - `proposal/PROPOSAL_ID` => Renders details for a proposal
//   - `proposals/DAO_PATH` => Renders the list of proposals for a DAO
func Render(path string) string {
	var r Router

	r.HandleFunc("", renderDAO)
	r.HandleFunc("dao", renderDAO)
	r.HandleFunc("proposal", renderProposal)
	r.HandleFunc("proposals", renderProposals)

	// Render global alerts before proposal states are updated within the handlers
	return renderAlerts() + r.Render(path)
}

func renderAlerts() string {
	if gnomeDAO.IsLocked() {
		msg := "Realm is locked"
		if reason := gnomeDAO.LockReason(); reason != "" {
			msg += "</br>" + reason
		}

		return alerts.NewError(msg)
	}

	if IsProposalsAdvanceNeeded() {
		return alerts.NewWarning(
			newGnoStudioConnectLink("AdvanceProposals", "Proposals advance needed"),
		)
	}
	return ""
}

func renderDAO(res ResponseWriter, req Request) {
	var (
		dao     *gnome.DAO
		daoPath = req.Route
	)

	if daoPath == "" {
		dao = gnomeDAO
		daoPath = nameCouncilDAO
	} else {
		var found bool
		dao, found = daos.GetByPath(daoPath)
		if !found {
			res.Write("DAO Not Found")
			return
		}

		// TODO: Add lock dismissal reason when available
		if dao.IsLocked() {
			res.Write(alerts.NewError("DAO is dismissed"))
		}
	}

	res.Writef(
		"# Gno.me DAO\n"+
			"## %s\n"+
			"%s\n\n"+
			"[View Proposals of %s](%s)\n",
		dao.Title(),
		dao.Manifest(),
		dao.Title(),
		makeProposalsURI(daoPath, true),
	)

	res.Write("## " + dao.Title() + " Members\n")
	for _, m := range dao.Members() {
		res.Write("- " + m.String() + "\n")
	}

	res.Write("\n" + customStyles + "\n\n")

	res.Write("## Organization\n\n")
	res.Write(renderOrganizationTree(daoPath))
	res.Write("\n")
}

func renderProposals(res ResponseWriter, req Request) {
	daoPath := req.Route
	dao, found := daos.GetByPath(daoPath)
	if !found {
		res.Write("DAO Not Found")
		return
	}

	daoProposals := proposals.GetAllByDAO(dao.Path())
	count := len(daoProposals)
	if count == 0 {
		res.Write("DAO has no proposals")
		return
	}

	realmPath := makeRealmPath(req.Path)
	pages := NewPaginator(realmPath, WithItemCount(count))

	// TODO: Add links to toggle display of dismissed proposals (when DAO dismissal is implemented)

	res.Writef("# %s: Proposals\n", dao.Title())
	pages.Iterate(func(i int) bool {
		if i >= count {
			return true
		}

		p := daoProposals[i]
		_ = advanceProposal(p) // TODO: Handle errors when render notice support is implemented
		path := makeProposalURI(p.ID(), true)
		res.Writef("- [#%s %s](%s) (%s)\n", p.ID(), p.Title(), path, p.Status())
		return false
	})

	if pages.IsEnabled() {
		res.Write("\n" + pages.Render())
	}
}

// TODO: Improve renderProposal code
func renderProposal(res ResponseWriter, req Request) {
	rawID := req.Route
	id, err := strconv.Atoi(rawID)
	if err != nil {
		res.Write("Invalid proposal ID: " + gnome.EscapeHTML(rawID))
		return
	}

	proposal, found := proposals.GetByID(gnome.ID(id))
	if !found {
		res.Write("Proposal Not Found")
		return
	}

	var (
		outcome gnome.ProposalStatus
		status  = proposal.Status()
	)

	// When the status is not final advance the proposal to calculate the current outcome
	if !status.IsFinal() {
		_ = advanceProposal(proposal) // TODO: Implement generic alert support for render and use it to render errors
		outcome = proposal.Status()

		// Validate if proposal is valid for the current state
		if err := proposal.Validate(); err != nil {
			res.Write(alerts.NewError(err.Error()))
		}

		// Warn when the outcome could change if a member of a parent DAO votes on this proposal.
		// Proposal choice is only available when there is a majority, so there is voting concensus.
		if proposal.Choice() != gnome.ChoiceNone && !proposal.HasVotingDeadlinePassed() {
			res.Write(alerts.NewWarning(proposalTakeoverMsg))
		}
	} else if status == gnome.StatusDismissed {
		// Display an alert with the dismiss reason
		res.Write(alerts.NewWarning(proposal.StatusReason()))
	}

	dao := proposal.DAO()
	daoPath := dao.Path()
	if proposal.HasBeenPromoted() {
		uri := makeDAOURI(daoPath, true)
		link := alerts.NewLink(uri, dao.Title())
		res.Write(alerts.NewWarning("Proposal has been promoted to " + link + " DAO"))
	}

	res.Write("# #" + proposal.ID().String() + " " + proposal.Title() + "\n")
	res.Write("- Type: " + proposal.Strategy().Name() + "\n")
	res.Write("- Created: " + proposal.CreatedAt().UTC().Format(dateFmt) + "\n")
	res.Write("- Proposer: " + proposal.Proposer().String() + "\n")
	res.Write("- Status: " + getProposalStatusMarkdown(status, proposal.Choice(), proposal.StatusReason()) + "\n")

	if !status.IsFinal() {
		if outcome == gnome.StatusReview {
			res.Write("- Review Deadline: " + proposal.ReviewDeadline().UTC().Format(dateFmt) + "\n")
		} else {
			res.Write("- Voting Deadline: " + proposal.VotingDeadline().UTC().Format(dateFmt) + "\n")
			res.Write("- Expected Outcome: " + getProposalStatusMarkdown(outcome, proposal.Choice(), proposal.StatusReason()) + "\n")

			// Vote line should be render as long as voting deadline is not reached.
			// This is required for proposals that have to be advanced after deadline is reached.
			if !proposal.HasVotingDeadlinePassed() {
				res.Write("\n" + newGnoStudioConnectLink("Vote", "Vote on this proposal") + "\n")
			}
		}
	}

	if s := proposal.Description(); s != "" {
		res.Write("## Description\n" + s + "\n")
	}

	if r, ok := proposal.Strategy().(gnome.ParamsRenderer); ok {
		// TODO: Use custom HTML component to allow users to toggle params visibility
		if s := r.RenderParams(); s != "" {
			res.Write("## Parameters\n\n" + s + "\n")
		}
	}

	res.Write("## Votes\n")
	record := proposal.VotingRecord()
	if record.VoteCount() == 0 {
		res.Write("The proposal has no votes\n")
	} else {
		// TODO: Render percentages for each voting choice and abstentions?
		record.Iterate(func(c gnome.VoteChoice, count uint) bool {
			res.Writef("- %s: %d\n", string(c), count)
			return false
		})

		res.Write("## Participation\n")
		renderProposalParticipation(res, record.Votes())
	}

	// If proposal has been promoted to a parent DAO render participation in child DAOs
	if proposal.HasBeenPromoted() {
		res.Write("## Sub DAOs Participation\n")
		daos := proposal.Promotions()
		records := proposal.VotingRecords()
		for i := len(records) - 2; i >= 0; i-- { // reverse iteration excluding record for current DAO
			r := records[i]
			dao := daos[i]
			res.Write("### [" + dao.Title() + "](" + makeDAOURI(daoPath, true) + "]\n")
			renderProposalParticipation(res, r.Votes())
		}
	}
}

func renderProposalParticipation(res ResponseWriter, votes []gnome.Vote) {
	for _, v := range votes {
		choice := string(v.Choice)
		if v.Reason != "" {
			// TODO: Long reasons have to break lines to fit making web UI look bad
			choice += ` "` + gnome.EscapeHTML(v.Reason) + `"`
		}

		res.Writef("- %s: voted %s\n", v.Address.String(), choice)
	}
}

// TODO: Use the UI package for HTML elements because rendered Markdown styles break the tree
func renderOrganizationTree(currentPath string) string {
	var item string
	if gnomeDAO.Name() == currentPath {
		item = `<li class="current">` + gnomeDAO.Title() + `</li>`
	} else {
		uri := makeDAOURI(gnomeDAO.Path(), true)
		item = `<li>` + alerts.NewLink(uri, gnomeDAO.Title()) + `</li>`
	}
	return `<div class="custom"><ul>` + item + renderSubTree(gnomeDAO, currentPath) + `</ul></div>`
}

func renderSubTree(parentDAO *gnome.DAO, currentPath string) string {
	var (
		buf  strings.Builder
		item string
	)

	for _, dao := range parentDAO.SubDAOs() {
		if dao.IsLocked() {
			// Skip dismissed DAOs
			// TODO: Render filter option to toggle dismissed DAOs visibility
			continue
		}

		if dao.Path() == currentPath {
			item = `<li class="current">` + dao.Title() + `</li>`
		} else {
			uri := makeDAOURI(dao.Path(), true)
			item = `<li>` + alerts.NewLink(uri, dao.Title()) + `</li>`
		}

		buf.WriteString(item)

		if len(dao.SubDAOs()) > 0 {
			buf.WriteString(renderSubTree(dao, currentPath))
		}
	}
	return `<ul>` + buf.String() + `</ul>`
}

func advanceProposal(p *gnome.Proposal) error {
	status := p.Status()
	if status == gnome.StatusReview && p.HasReviewDeadlinePassed() {
		if err := p.Activate(); err != nil {
			return err
		}

		status = p.Status()
	}

	if status == gnome.StatusActive {
		// Tally active proposals to always have an up to date state with the current proposal outcome
		if err := p.Tally(); err != nil {
			return err
		}
	}
	return nil
}

func getProposalStatusMarkdown(s gnome.ProposalStatus, c gnome.VoteChoice, reason string) string {
	switch s {
	case gnome.StatusPassed:
		return ufmt.Sprintf("**%s** (%s)", s, string(c))
	case gnome.StatusRejected:
		// Rejected proposal might have a reason
		if reason == "" {
			return ufmt.Sprintf("**%s**", s)
		} else {
			return ufmt.Sprintf("**%s** (%s)", s, reason)
		}
	case gnome.StatusDismissed, gnome.StatusFailed:
		return ufmt.Sprintf("**%s** (%s)", s, reason)
	default:
		return ufmt.Sprintf("**%s**", s)
	}
}

func newGnoStudioConnectLink(functionName, label string) string {
	href := makeGnoStudioConnectURL(functionName)
	return alerts.NewLink(href, label)
}
