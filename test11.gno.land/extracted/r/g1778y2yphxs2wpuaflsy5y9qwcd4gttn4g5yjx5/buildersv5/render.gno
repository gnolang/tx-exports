package builders

import (
	"gno.land/p/jeronimoalbi/mdform"
	"gno.land/p/moul/md"
	"gno.land/p/moul/txlink"
)

const realmPath = "/r/g1778y2yphxs2wpuaflsy5y9qwcd4gttn4g5yjx5/buildersv5"

func renderSubmission(sub *Submission) string {
	out := "### " + string(sub.Applicant) + "\n\n"
	out += "- **Status:** " + sub.Status.String() + "\n"
	out += "- **Twitter:** " + sub.Twitter + "\n"
	out += "- **Discord:** " + sub.Discord + "\n"
	out += "- **GitHub:** " + sub.GitHub + "\n"
	out += "- **Request Type:** " + sub.RequestType + "\n"
	out += "- **Details:** " + sub.Details + "\n"
	out += "- **Submitted:** " + sub.SubmittedAt.Format("2006-01-02 15:04:05") + "\n"

	if !sub.ReviewedAt.IsZero() {
		out += "- **Reviewed:** " + sub.ReviewedAt.Format("2006-01-02 15:04:05") + "\n"
	}
	if !sub.PaidAt.IsZero() {
		out += "- **Paid:** " + sub.PaidAt.Format("2006-01-02 15:04:05") + "\n"
	}
	if sub.ReviewNote != "" {
		out += "- **Note:** " + sub.ReviewNote + "\n"
	}

	out += "\n"
	return out
}

func renderAdminActions(sub *Submission) string {
	approveLink := txlink.NewLink("Approve").
		AddArgs(
			"addr", string(sub.Applicant),
			"note", "approved",
		).
		URL()

	rejectLink := txlink.NewLink("Reject").
		AddArgs(
			"addr", string(sub.Applicant),
			"note", "rejected",
		).
		URL()

	out := md.Link("✅ Approve", approveLink) + " | " + md.Link("❌ Reject", rejectLink)

	if sub.Status == StatusApproved {
		paidLink := txlink.NewLink("MarkPaid").
			AddArgs(
				"addr", string(sub.Applicant),
				"note", "paid",
			).
			URL()
		out += " | " + md.Link("💸 Mark Paid", paidLink)
	}

	return out + "\n"
}

func renderApplyForm() string {
	form := mdform.New(
		"exec", "Submit",
		"path", realmPath,
	)

	form.Input(
		"twitterHandle",
		"placeholder", "@yourhandle",
		"description", "Twitter / X handle",
		"required", "true",
	)

	form.Input(
		"discordHandle",
		"placeholder", "username or username#1234",
		"description", "Discord handle",
		"required", "true",
	)

	form.Input(
		"githubURL",
		"placeholder", "https://github.com/yourname",
		"description", "GitHub profile or repo URL",
		"required", "true",
	)

	form.Select(
		"requestType",
		"initial",
		"description", "Request type",
		"selected", "true",
	)

	form.Select(
		"requestType",
		"followup",
	)

	form.Input(
		"applicationDetails",
		"placeholder", "What are you building, what do you need funds for, and if this is a follow-up request, what indexer activity should reviewers look at?",
		"description", "Application details",
		"required", "true",
	)

	return form.String()
}

func Render(path string) string {
	if path == "apply" {
		out := "# Apply for Builder Faucet\n\n"
		out += "Submit your faucet application below.\n\n"
		out += renderApplyForm()
		out += "\n"
		out += md.Link("← Back to Registry", realmPath) + "\n"
		return out
	}

	if path == "admin" {
		out := "# Admin Panel\n\n"
		out += "**Admin:** `" + string(Admin()) + "`\n\n"
		out += md.Link("← Back to Registry", realmPath) + "\n\n"

		if TotalSubmissions() == 0 {
			out += "No submissions yet.\n"
			return out
		}

		out += "## Review Queue\n\n"
		for i := 0; i < TotalSubmissions(); i++ {
			sub := SubmissionAt(i)
			out += renderSubmission(sub)
			out += renderAdminActions(sub)
			out += "\n---\n\n"
		}
		return out
	}

	out := "# Builder Faucet Registry\n\n"
	out += "**Total submissions:** " + itoa(TotalSubmissions()) + "\n\n"
	out += "**Approved:** " + itoa(TotalApproved()) + "\n\n"
	out += "**Paid:** " + itoa(TotalPaid()) + "\n\n"

	out += md.Link("📝 Apply for Faucet", realmPath+":apply")
	out += " | "
	out += md.Link("🔐 Admin Panel", realmPath+":admin")
	out += "\n\n---\n\n"

	if TotalSubmissions() == 0 {
		out += "No submissions yet.\n"
		return out
	}

	out += "## Submissions\n\n"
	for i := 0; i < TotalSubmissions(); i++ {
		sub := SubmissionAt(i)
		out += renderSubmission(sub)
		out += "---\n\n"
	}

	return out
}

func itoa(n int) string {
	if n == 0 {
		return "0"
	}

	neg := false
	if n < 0 {
		neg = true
		n = -n
	}

	s := ""
	for n > 0 {
		s = string(rune('0'+(n%10))) + s
		n /= 10
	}

	if neg {
		return "-" + s
	}
	return s
}
