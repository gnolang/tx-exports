package contest

import (
	"strconv"
	"strings"
	"time"

	"gno.land/p/g1lnkytfqcjwllws63gvf0mv9yt04aswy4y9amhm/remixlab/core/v1"
	"gno.land/p/g1lnkytfqcjwllws63gvf0mv9yt04aswy4y9amhm/remixlab/render/v1"
)

// Render serves the native pages: overview (entries, ballot and result), a
// single entry, the review queue, members and rules.
func Render(path string) string {
	if members == nil {
		return render.Heading(1, appTitle) + "This app is not initialized.\n"
	}
	segs, q := render.ParsePath(path)
	switch {
	case len(segs) == 0:
		return renderHome()
	case segs[0] == "entries" && len(segs) == 2:
		id, err := strconv.ParseUint(segs[1], 10, 64)
		if err != nil {
			return notFound()
		}
		return renderEntry(id)
	case segs[0] == "queue" && len(segs) == 1:
		return renderQueue(render.Page(q, render.PageCount(entries.CountByStatus(core.SubmissionSubmitted), pageSize)))
	case segs[0] == "members" && len(segs) == 1:
		return renderMembers(render.Page(q, render.PageCount(members.Size(), pageSize)))
	case segs[0] == "rules" && len(segs) == 1:
		return renderRules()
	}
	return notFound()
}

func renderHome() string {
	var sb strings.Builder
	sb.WriteString(render.Heading(1, appTitle))
	v, voting := Ballot()
	now := time.Now().Unix()
	switch {
	case !voting:
		sb.WriteString("**Taking entries.** Reviewers admit up to " + strconv.Itoa(maxEntries) + " entries; then voting opens on the admitted entries.\n\n")
		sb.WriteString(render.TxLink("Submit an entry", pkgPath, "Submit") + " · " +
			render.Link("Review queue", render.RealmURL(pkgPath, "queue")) + " (" + strconv.Itoa(entries.CountByStatus(core.SubmissionSubmitted)) + ") · " +
			render.TxLink("Open voting", pkgPath, "OpenVoting") + "\n\n")
	case v.Status == core.BallotOpen && now < v.Deadline:
		sb.WriteString("**Voting is open** until " + render.Text(time.Unix(v.Deadline, 0).UTC().Format(time.RFC3339)) +
			" · electorate " + strconv.Itoa(v.ElectorateSize) + " · ballots " + strconv.Itoa(v.Turnout) + "\n\n")
	case v.Status == core.BallotOpen:
		sb.WriteString("**Voting ended, awaiting finalization.** " + render.TxLink("Finalize result", pkgPath, "Finalize") + "\n\n")
	default:
		sb.WriteString("**Result: " + render.Text(resultLabel(v)) + "** · ballots " + strconv.Itoa(v.Turnout) + "\n\n")
	}

	var rows [][]string
	for i, e := range Entries() {
		idStr := strconv.FormatUint(e.ID, 10)
		row := []string{
			render.Link("#"+idStr, render.RealmURL(pkgPath, "entries/"+idStr)),
			render.Text(e.Answers[titleIndex]),
		}
		if voting {
			row = append(row, strconv.Itoa(v.Counts[i]))
			if v.Status == core.BallotOpen && now < v.Deadline {
				row = append(row, render.TxLink("vote", pkgPath, "Vote", "entryID", idStr))
			} else {
				row = append(row, "")
			}
		}
		rows = append(rows, render.TrustedRow(row...))
	}
	headers := []string{"Entry", "Title"}
	if voting {
		headers = append(headers, "Votes", "")
	}
	if len(rows) == 0 {
		sb.WriteString("No admitted entries yet.\n\n")
	} else {
		sb.WriteString(render.Table(headers, rows))
	}

	sb.WriteString("- " + render.Link("Members", render.RealmURL(pkgPath, "members")) + " (" + strconv.Itoa(members.Size()) + ") · " +
		render.TxLink("Join (requires an invitation)", pkgPath, "Join") + "\n")
	sb.WriteString("- " + render.Link("Rules", render.RealmURL(pkgPath, "rules")) + "\n\n")
	sb.WriteString("_Recipe " + render.Text(recipeID+"@"+recipeVersion) + ". Membership is address-based; one address is not one person._\n")
	return sb.String()
}

func renderQueue(page int) string {
	list := entries.Submissions(int(core.SubmissionSubmitted), (page-1)*pageSize, pageSize)
	if len(list) == 0 {
		return render.Heading(1, "Review queue") + "Nothing to review.\n"
	}
	var rows [][]string
	for _, e := range list {
		idStr := strconv.FormatUint(e.ID, 10)
		rows = append(rows, render.TrustedRow(
			render.Link("#"+idStr, render.RealmURL(pkgPath, "entries/"+idStr)),
			render.Text(e.Answers[titleIndex]),
			reviewLinks(idStr),
		))
	}
	return render.Heading(1, "Review queue") +
		render.Table([]string{"Entry", "Title", "Review"}, rows) +
		render.Pager(pkgPath, "queue", page, render.PageCount(entries.CountByStatus(core.SubmissionSubmitted), pageSize))
}

func renderEntry(id uint64) string {
	v, ok := entries.Submission(id)
	if !ok {
		return notFound()
	}
	idStr := strconv.FormatUint(id, 10)
	if v.Status == core.SubmissionRejected {
		return render.Heading(1, "Entry #"+idStr) + "This entry was rejected.\n\n" +
			render.Link("Back to the contest", render.RealmURL(pkgPath, "")) + "\n"
	}
	status := "admitted"
	if v.Status == core.SubmissionSubmitted {
		status = "awaiting review"
	}
	var sb strings.Builder
	sb.WriteString(render.Heading(1, v.Answers[titleIndex]))
	sb.WriteString("Status: **" + status + "** · submitted by " + render.Code(v.Submitter.String()) + "\n\n")
	var rows [][]string
	for i, f := range entries.Fields() {
		if i != titleIndex && v.Answers[i] != "" {
			rows = append(rows, render.Row(f.Label, v.Answers[i]))
		}
	}
	if len(rows) > 0 {
		sb.WriteString(render.Table([]string{"Field", "Answer"}, rows))
	}
	if v.Status == core.SubmissionSubmitted && ballotID == 0 {
		sb.WriteString("Review: " + reviewLinks(idStr) + "\n\n")
	}
	sb.WriteString(render.Link("Back to the contest", render.RealmURL(pkgPath, "")) + "\n")
	return sb.String()
}

func reviewLinks(idStr string) string {
	return render.TxLink("admit", pkgPath, "Accept", "id", idStr) + " · " +
		render.TxLink("reject", pkgPath, "Reject", "id", idStr)
}

func renderMembers(page int) string {
	var rows [][]string
	for _, m := range members.List((page-1)*pageSize, pageSize) {
		rows = append(rows, render.Row(m.Address.String(), m.Role.String()))
	}
	return render.Heading(1, "Members") +
		render.Table([]string{"Address", "Role"}, rows) +
		render.Pager(pkgPath, "members", page, render.PageCount(members.Size(), pageSize))
}

func renderRules() string {
	var rows [][]string
	for _, r := range policy.List() {
		rows = append(rows, render.Row(r.Op, r.Rule.String(), r.Floor.String()))
	}
	rows = append(rows, render.Row("contest.vote", "electorate frozen when voting opens (members)", "-"))
	return render.Heading(1, "Rules") +
		render.Table([]string{"Operation", "Who may", "Most permissive allowed"}, rows) +
		"Up to 50 pending or admitted submissions, at most 1 per address; at most 10 admitted entries. Review decisions are final; rejecting an entry frees its slot. A tie has no winner." + "\n"
}

func resultLabel(v core.BallotView) string {
	if w, ok := Winner(); ok {
		return "winner: " + v.Options[v.Winner] + " (entry " + strconv.FormatUint(w, 10) + ")"
	}
	return v.Outcome.String()
}

func notFound() string {
	return render.Heading(1, "Not found") + render.Link("Back to the app", render.RealmURL(pkgPath, "")) + "\n"
}
