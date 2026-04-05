package builders

import (
	"chain/runtime"
	"strings"
	"time"
)

func assertNonEmpty(v string, field string) {
	if strings.TrimSpace(v) == "" {
		panic("missing required field: " + field)
	}
}

func assertValidRequestType(v string) {
	switch v {
	case "initial", "followup":
		return
	default:
		panic("invalid requestType: must be 'initial' or 'followup'")
	}
}

func Submit(
	_ realm,
	twitterHandle string,
	discordHandle string,
	githubURL string,
	requestType string,
	applicationDetails string,
) {
	runtime.AssertOriginCall()

	assertNonEmpty(twitterHandle, "twitterHandle")
	assertNonEmpty(discordHandle, "discordHandle")
	assertNonEmpty(githubURL, "githubURL")
	assertNonEmpty(applicationDetails, "applicationDetails")
	assertValidRequestType(requestType)

	caller := applicantAddr()
	now := time.Now()

	sub := GetSubmission(caller)
	if sub != nil {
		sub.Twitter = twitterHandle
		sub.Discord = discordHandle
		sub.GitHub = githubURL
		sub.RequestType = requestType
		sub.Details = applicationDetails
		sub.Status = StatusPending
		sub.ReviewNote = ""
		sub.SubmittedAt = now
		sub.ReviewedAt = time.Time{}
		sub.PaidAt = time.Time{}
		setSubmission(sub)
		return
	}

	setSubmission(&Submission{
		Applicant:   caller,
		Twitter:     twitterHandle,
		Discord:     discordHandle,
		GitHub:      githubURL,
		RequestType: requestType,
		Details:     applicationDetails,
		Status:      StatusPending,
		SubmittedAt: now,
	})
}

func Approve(_ realm, addr address, note string) {
	requireAdmin()

	sub := GetSubmission(addr)
	if sub == nil {
		panic("submission not found")
	}

	sub.Status = StatusApproved
	sub.ReviewNote = note
	sub.ReviewedAt = time.Now()
	setSubmission(sub)
}

func Reject(_ realm, addr address, note string) {
	requireAdmin()

	sub := GetSubmission(addr)
	if sub == nil {
		panic("submission not found")
	}

	sub.Status = StatusRejected
	sub.ReviewNote = note
	sub.ReviewedAt = time.Now()
	setSubmission(sub)
}

func MarkPaid(_ realm, addr address, note string) {
	requireAdmin()

	sub := GetSubmission(addr)
	if sub == nil {
		panic("submission not found")
	}
	if sub.Status != StatusApproved {
		panic("submission must be approved before marking paid")
	}

	sub.Status = StatusPaid
	sub.ReviewNote = note
	sub.ReviewedAt = time.Now()
	sub.PaidAt = time.Now()
	setSubmission(sub)
}

func TransferAdmin(_ realm, newAdmin address) {
	requireAdmin()

	if newAdmin == "" {
		panic("new admin cannot be empty")
	}

	admin = newAdmin
}
