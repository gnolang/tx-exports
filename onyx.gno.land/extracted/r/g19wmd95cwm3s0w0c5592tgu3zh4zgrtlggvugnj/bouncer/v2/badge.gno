package bouncer

import (
	"strconv"

	"gno.land/p/g19wmd95cwm3s0w0c5592tgu3zh4zgrtlggvugnj/bouncer/badge/v0"
)

// Badge returns a Markdown image of pkgpath's live Bouncer badge (grade,
// score and attestation date), linked to its Passport. A realm shows it by
// adding one line to its Render:
//
//	out += bouncer.Badge("gno.land/r/<address>/myrealm")
//
// The color follows the verdict, not the grade: a package with a PROVEN
// High finding is red even at grade B.
func Badge(pkgpath string) string {
	if !validPkgPath(pkgpath) {
		return ""
	}
	link := webPath() + ":realm/" + pkgpath
	a, ok := Latest(pkgpath)
	if !ok {
		return badge.Markdown("Bouncer: not scanned", badge.SVG("bouncer", "not scanned", badge.Grey), link)
	}
	msg := a.Grade + " " + strconv.Itoa(a.Score) + " · " + date(a.Time)
	return badge.Markdown("Bouncer: grade "+a.Grade+", score "+strconv.Itoa(a.Score)+", "+verdictWords(a.Verdict),
		badge.SVG("bouncer", msg, verdictColor(a.Verdict)), link)
}

func verdictColor(v string) string {
	switch v {
	case VerdictNotRecommended:
		return badge.Red
	case VerdictReview:
		return badge.Orange
	}
	return badge.Green
}

func verdictWords(v string) string {
	switch v {
	case VerdictNotRecommended:
		return "not recommended for integration"
	case VerdictReview:
		return "review before integration"
	}
	return "no known Critical or High issues"
}
