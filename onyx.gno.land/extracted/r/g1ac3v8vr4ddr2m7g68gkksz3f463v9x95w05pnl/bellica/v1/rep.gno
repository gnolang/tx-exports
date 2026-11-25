package bellica

import (
	"gno.land/p/g1ac3v8vr4ddr2m7g68gkksz3f463v9x95w05pnl/bellica/reviews/v1"
)

// Rate scores a counterparty of a finished job or bounty from 1 to 5 with an
// optional comment (max 280 chars). One rating per rater, target and item.
func Rate(cur realm, kind string, id int, target string, score int, comment string) {
	reviews.Rate(db, cur, kind, id, target, score, comment)
}

// Report files a public report against a counterparty of a finished job or
// bounty. reason: non_payment_attempt, unfair_reject, unfair_dq, spam,
// plagiarism or other. text: 30-500 chars explaining what happened. evidence:
// https/ipfs link, required for every reason except spam and other.
// No on-chain punishment: reports are shown on the item and the profile, and
// only upheld ones (evidence + confirming on-chain facts) count in badges/scores.
func Report(cur realm, kind string, id int, target, reason, text, evidence string) int {
	return reviews.Report(db, cur, kind, id, target, reason, text, evidence)
}

// Respond posts the reported party's single public answer to a report.
func Respond(cur realm, reportID int, text string) {
	reviews.Respond(db, cur, reportID, text)
}
