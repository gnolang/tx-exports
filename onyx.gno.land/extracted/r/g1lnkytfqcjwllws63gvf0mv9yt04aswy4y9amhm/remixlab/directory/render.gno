package directory

import (
	"net/url"
	"strconv"
	"strings"

	"gno.land/p/g1lnkytfqcjwllws63gvf0mv9yt04aswy4y9amhm/remixlab/core/v1"
	"gno.land/p/g1lnkytfqcjwllws63gvf0mv9yt04aswy4y9amhm/remixlab/render/v1"
)

// Render serves the native pages: overview, accepted entries, a single
// entry, the review queue, members and rules.
func Render(path string) string {
	if members == nil {
		return render.Heading(1, appTitle) + "This app is not initialized.\n"
	}
	segs, q := render.ParsePath(path)
	switch {
	case len(segs) == 0:
		return renderHome()
	case segs[0] == "entries" && len(segs) == 1:
		return renderList("Entries", "entries", core.SubmissionAccepted, q)
	case segs[0] == "entries" && len(segs) == 2:
		id, err := strconv.ParseUint(segs[1], 10, 64)
		if err != nil {
			return notFound()
		}
		return renderEntry(id)
	case segs[0] == "queue" && len(segs) == 1:
		return renderList("Review queue", "queue", core.SubmissionSubmitted, q)
	case segs[0] == "members" && len(segs) == 1:
		return renderMembers(render.Page(q, render.PageCount(members.Size(), pageSize)))
	case segs[0] == "rules" && len(segs) == 1:
		return renderRules()
	}
	return notFound()
}

func renderHome() string {
	accepted := entries.CountByStatus(core.SubmissionAccepted)
	waiting := entries.CountByStatus(core.SubmissionSubmitted)
	var sb strings.Builder
	sb.WriteString(render.Heading(1, appTitle))
	sb.WriteString("Entries are submitted for review; accepted entries are listed here. Every submission, including rejected ones, is public chain data.\n\n")
	sb.WriteString("- " + render.Link("Entries", render.RealmURL(pkgPath, "entries")) + " (" + strconv.Itoa(accepted) + ")\n")
	sb.WriteString("- " + render.Link("Review queue", render.RealmURL(pkgPath, "queue")) + " (" + strconv.Itoa(waiting) + ")\n")
	sb.WriteString("- " + render.Link("Members", render.RealmURL(pkgPath, "members")) + " (" + strconv.Itoa(members.Size()) + ")\n")
	sb.WriteString("- " + render.Link("Rules", render.RealmURL(pkgPath, "rules")) + "\n\n")
	sb.WriteString(render.TxLink("Submit an entry", pkgPath, "Submit") + " · " + render.TxLink("Join (requires an invitation)", pkgPath, "Join") + "\n\n")
	sb.WriteString(renderTable(entries.Submissions(int(core.SubmissionAccepted), 0, 5), false))
	sb.WriteString("_Recipe " + render.Text(recipeID+"@"+recipeVersion) + ". Membership is address-based; one address is not one person._\n")
	return sb.String()
}

func renderList(heading, route string, status core.SubmissionStatus, q url.Values) string {
	pages := render.PageCount(entries.CountByStatus(status), pageSize)
	page := render.Page(q, pages)
	list := entries.Submissions(int(status), (page-1)*pageSize, pageSize)
	return render.Heading(1, heading) +
		renderTable(list, status == core.SubmissionSubmitted) +
		render.Pager(pkgPath, route, page, pages)
}

func renderTable(list []core.SubmissionView, reviewActions bool) string {
	if len(list) == 0 {
		return "Nothing here yet.\n\n"
	}
	var rows [][]string
	for _, v := range list {
		idStr := strconv.FormatUint(v.ID, 10)
		row := []string{
			render.Link("#"+idStr, render.RealmURL(pkgPath, "entries/"+idStr)),
			render.Text(v.Answers[titleIndex]),
		}
		if reviewActions {
			row = append(row, reviewLinks(idStr))
		}
		rows = append(rows, render.TrustedRow(row...))
	}
	headers := []string{"Entry", "Title"}
	if reviewActions {
		headers = append(headers, "Review")
	}
	return render.Table(headers, rows)
}

func renderEntry(id uint64) string {
	v, ok := entries.Submission(id)
	if !ok {
		return notFound()
	}
	idStr := strconv.FormatUint(id, 10)
	if v.Status == core.SubmissionRejected {
		return render.Heading(1, "Entry #"+idStr) + "This entry was rejected.\n\n" +
			render.Link("All entries", render.RealmURL(pkgPath, "entries")) + "\n"
	}
	var sb strings.Builder
	sb.WriteString(render.Heading(1, v.Answers[titleIndex]))
	sb.WriteString("Status: **" + v.Status.String() + "** · submitted by " + render.Code(v.Submitter.String()) + "\n\n")
	var rows [][]string
	for i, f := range entries.Fields() {
		if i != titleIndex && v.Answers[i] != "" {
			rows = append(rows, render.Row(f.Label, v.Answers[i]))
		}
	}
	if len(rows) > 0 {
		sb.WriteString(render.Table([]string{"Field", "Answer"}, rows))
	}
	if v.Status == core.SubmissionSubmitted {
		sb.WriteString("Awaiting review: " + reviewLinks(idStr) + "\n\n")
	}
	sb.WriteString(render.Link("All entries", render.RealmURL(pkgPath, "entries")) + "\n")
	return sb.String()
}

func reviewLinks(idStr string) string {
	return render.TxLink("accept", pkgPath, "Accept", "id", idStr) + " · " +
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
	return render.Heading(1, "Rules") +
		render.Table([]string{"Operation", "Who may", "Most permissive allowed"}, rows) +
		"Up to 100 pending or accepted submissions, at most 3 per address. Review decisions are final; rejecting an entry frees its slot." + "\n"
}

func notFound() string {
	return render.Heading(1, "Not found") + render.Link("Back to the app", render.RealmURL(pkgPath, "")) + "\n"
}
