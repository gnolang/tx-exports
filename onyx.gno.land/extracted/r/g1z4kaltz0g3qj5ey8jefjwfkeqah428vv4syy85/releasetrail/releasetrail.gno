// ReleaseTrail is a public, wallet-authenticated product release registry.
// It records immutable claims and independently signed reviews on Gno.land.
package releasetrail

import (
	"chain/runtime"
	"strconv"
	"strings"
)

const (
	maxReleases       = 1000
	maxReviews        = 4000
	maxTitleLength    = 80
	maxSummaryLength  = 240
	maxVersionLength  = 24
	maxEvidenceLength = 240
)

type Release struct {
	ID        int
	Author    address
	Project   string
	Version   string
	Summary   string
	Evidence  string
	Height    int64
	Verified  int
	Flagged   int
	Retracted bool
}

type ReviewRecord struct {
	ReleaseID int
	Reviewer  address
	Outcome   string
	Height    int64
}

var releases []*Release
var reviewRecords []*ReviewRecord
var reviewers = make(map[string]bool)
var reviewsCount int
var flagsCount int

// Publish records a release claim. Each release and its evidence link are immutable.
// The authentic calling realm/address is used as the author, never a user-supplied value.
func Publish(cur realm, project string, version string, summary string, evidenceURL string) int {
	if len(releases) >= maxReleases {
		panic("release registry is full")
	}
	if !validText(project, 3, maxTitleLength) {
		panic("project must be 3-80 safe ASCII characters")
	}
	if !validVersion(version) {
		panic("invalid version: use 1-24 letters, numbers, dots, dashes or underscores")
	}
	if !validText(summary, 10, maxSummaryLength) {
		panic("summary must be 10-240 safe ASCII characters")
	}
	if !validEvidenceURL(evidenceURL) {
		panic("evidence must be a safe https URL, up to 240 characters")
	}

	r := &Release{
		ID:       len(releases) + 1,
		Author:   cur.Previous().Address(),
		Project:  project,
		Version:  version,
		Summary:  summary,
		Evidence: evidenceURL,
		Height:   runtime.ChainHeight(),
	}
	releases = append(releases, r)
	return r.ID
}

// Review creates one public review per wallet, per release.
// A publisher cannot review their own release. Reviews cannot be changed.
func Review(cur realm, releaseID int, outcome string) string {
	r := lookup(releaseID)
	if r.Retracted {
		panic("cannot review a retracted release")
	}
	if len(reviewRecords) >= maxReviews {
		panic("review registry is full")
	}
	caller := cur.Previous().Address()
	if r.Author == caller {
		panic("you cannot review your own release")
	}
	if outcome != "verify" && outcome != "flag" {
		panic("outcome must be verify or flag")
	}
	key := strconv.Itoa(releaseID) + ":" + string(caller)
	if reviewers[key] {
		panic("one review per wallet per release")
	}
	reviewers[key] = true
	reviewRecords = append(reviewRecords, &ReviewRecord{
		ReleaseID: releaseID,
		Reviewer:  caller,
		Outcome:   outcome,
		Height:    runtime.ChainHeight(),
	})
	if outcome == "verify" {
		r.Verified++
		reviewsCount++
	} else {
		r.Flagged++
		flagsCount++
	}
	return "review recorded"
}

// Retract marks a release as withdrawn. The original claim and reviews remain
// visible in public history; deletion and revision are not possible.
func Retract(cur realm, releaseID int) string {
	r := lookup(releaseID)
	if r.Author != cur.Previous().Address() {
		panic("only the original publisher may retract")
	}
	if r.Retracted {
		panic("release already retracted")
	}
	r.Retracted = true
	return "release retracted, history retained"
}

// Count and Detail are read-only accessors for scripts and integrations.
func Count() int {
	return len(releases)
}

func Detail(releaseID int) string {
	r := lookup(releaseID)
	return describe(r)
}

// Render serves an entire live web interface through Gno.land's gnoweb.
// A path like /1 opens the full history for release #1.
func Render(path string) string {
	path = strings.TrimPrefix(path, "/")
	if path != "" {
		id, err := strconv.Atoi(path)
		if err != nil || id < 1 || id > len(releases) {
			return "# Release not found\n\n[Back to ReleaseTrail](.)"
		}
		return "# ReleaseTrail / Release #" + strconv.Itoa(id) + "\n\n" + describe(releases[id-1]) + "\n\n[Back to all releases](.)"
	}

	var out string
	out += "# ReleaseTrail\n\n"
	out += "**Ship with evidence. Verify with your wallet.**\n\n"
	out += "An open, on-chain public record of product releases, supporting evidence, independent reviews and retractions. No accounts, central database or proprietary API.\n\n"
	out += "## Registry at a glance\n\n"
	out += "| Releases | Independent verifications | Flags |\n| :--- | :--- | :--- |\n"
	out += "| **" + strconv.Itoa(len(releases)) + "** | **" + strconv.Itoa(reviewsCount) + "** | **" + strconv.Itoa(flagsCount) + "** |\n\n"
	out += "## Take action\n\n"
	out += "1. Open the **Actions** tab to call **Publish**, attaching an HTTPS link to a repository, changelog, audit or demo.\n"
	out += "2. As a different wallet, call **Review** with a release ID and `verify` or `flag`.\n"
	out += "3. The publisher may call **Retract**; their original record stays visible.\n\n"
	out += "**Important:** A verification is another wallet's opinion, not proof that an audit passed. Multiple wallets do not guarantee multiple people. Do not store private data.\n\n"
	out += "## Latest releases\n\n"
	if len(releases) == 0 {
		out += "No releases yet. Be the first to publish a product milestone.\n"
		return out
	}
	out += "| ID | Product | Version | Reviews | Status |\n| :--- | :--- | :--- | :--- | :--- |\n"
	start := len(releases) - 12
	if start < 0 {
		start = 0
	}
	for i := len(releases) - 1; i >= start; i-- {
		r := releases[i]
		status := "Active"
		if r.Retracted {
			status = "Retracted"
		}
		out += "| #" + strconv.Itoa(r.ID) + " | " + r.Project + " | " + r.Version + " | " + strconv.Itoa(r.Verified) + " verify / " + strconv.Itoa(r.Flagged) + " flag | " + status + " |\n"
	}
	out += "\nTo view a complete record, open the realm URL with `:" + "<release ID>" + "` after the realm path.\n"
	return out
}

func describe(r *Release) string {
	status := "Active"
	if r.Retracted {
		status = "Retracted - new reviews disabled"
	}
	var out string
	out += "## " + r.Project + " / " + r.Version + "\n\n"
	out += "**Status:** " + status + "\n\n"
	out += "**Published by:** `" + string(r.Author) + "`\n\n"
	out += "**Block height:** " + strconv.FormatInt(r.Height, 10) + "\n\n"
	out += "**Release notes:** " + r.Summary + "\n\n"
	out += "**Evidence:** [Open external evidence](" + r.Evidence + ")\n\n"
	out += "**Independent verifications:** " + strconv.Itoa(r.Verified) + "\n\n"
	out += "**Flags:** " + strconv.Itoa(r.Flagged) + "\n\n"
	out += "### Recent signed reviews\n\n"
	out += "| Wallet | Decision | Block |\n| :--- | :--- | :--- |\n"
	shown := 0
	for i := len(reviewRecords) - 1; i >= 0 && shown < 12; i-- {
		review := reviewRecords[i]
		if review.ReleaseID == r.ID {
			out += "| `" + string(review.Reviewer) + "` | " + review.Outcome + " | " + strconv.FormatInt(review.Height, 10) + " |\n"
			shown++
		}
	}
	if shown == 0 {
		out += "| - | No reviews yet | - |\n"
	}
	out += "\nEvidence is publisher-provided; reviews are pseudonymous wallet opinions. Claims are not independently validated by the contract.\n"
	return out
}

// Mutating entry points receive a runtime-created realm context.
// Immediate caller identity is taken from cur.Previous().Address(),
// not from a caller-supplied address. The cur.IsCurrent() assertion was
// redundant and is unavailable in some Playground VM builds.

func lookup(id int) *Release {
	if id < 1 || id > len(releases) {
		panic("release does not exist")
	}
	return releases[id-1]
}

// Prevent Markdown injection, HTML injection, line breaks and table delimiters.
func validText(s string, min int, max int) bool {
	if len(s) < min || len(s) > max {
		return false
	}
	for i := 0; i < len(s); i++ {
		c := s[i]
		if (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') {
			continue
		}
		if c == ' ' || c == '.' || c == ',' || c == ':' || c == ';' || c == '!' || c == '?' || c == '-' || c == '_' || c == '(' || c == ')' || c == '/' || c == '@' || c == '#' || c == '+' {
			continue
		}
		return false
	}
	return true
}

func validVersion(s string) bool {
	if len(s) < 1 || len(s) > maxVersionLength {
		return false
	}
	for i := 0; i < len(s); i++ {
		c := s[i]
		if (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') || c == '.' || c == '-' || c == '_' {
			continue
		}
		return false
	}
	return true
}

func validEvidenceURL(s string) bool {
	if !strings.HasPrefix(s, "https://") || len(s) < 12 || len(s) > maxEvidenceLength {
		return false
	}
	for i := 8; i < len(s); i++ {
		c := s[i]
		if (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') {
			continue
		}
		if c == '/' || c == ':' || c == '.' || c == '-' || c == '_' || c == '?' || c == '=' || c == '&' || c == '%' || c == '#' || c == '~' || c == '+' {
			continue
		}
		return false
	}
	return true
}
