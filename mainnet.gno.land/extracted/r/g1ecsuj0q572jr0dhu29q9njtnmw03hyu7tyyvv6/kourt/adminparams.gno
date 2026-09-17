package kourt
import (
	"strconv"
	"strings"
)
func adminAddr() address {
	if globalDAO != nil {
		return globalDAO.admin
	}
	return directoryAdmin
}
func purgeThreshold() int {
	if globalDAO != nil {
		return globalDAO.purgeM
	}
	return daoBootstrapM
}
func daoSeats() int {
	if globalDAO != nil {
		return globalDAO.n
	}
	return daoBootstrapN
}
func AdminParams() string {
	l := ladderDefault
	r := creditRatesDefault
	hosts := MediaHosts()
	exact, suffix := hosts, ""
	if i := strings.Index(hosts, "|"); i >= 0 {
		exact, suffix = hosts[:i], hosts[i+1:]
	}
	n := func(v int64) string { return strconv.FormatInt(v, 10) }
	return "admin:" + adminAddr().String() +
		";creationBurn:" + n(courtCreationBurn) +
		";assocBond:" + n(assocBondDefault) +
		";purgeM:" + strconv.Itoa(purgeThreshold()) +
		";t1:" + n(l.t1Bps) +
		";t2:" + n(l.t2Bps) +
		";t3:" + n(l.t3Bps) +
		";entry:" + n(l.postsEntry) +
		";l2:" + n(l.postsT2) +
		";l3:" + n(l.postsT3()) +
		";flag:" + n(r.flag) +
		";dispute:" + n(r.dispute) +
		";authorHigh:" + n(r.authorHigh) +
		";conviction:" + n(r.conviction) +
		";unadjudicated:" + n(r.unadjudicated) +
		";domain:" + siteDomain +
		";mediaExact:" + exact +
		";mediaSuffix:" + suffix
}
const adminParamsPath = "admin-params"
func renderAdminParams() string {
	l := ladderDefault
	r := creditRatesDefault
	n := func(v int64) string { return strconv.FormatInt(v, 10) }
	var b strings.Builder
	b.WriteString("# Realm parameters\n\n")
	b.WriteString("Everything the global DAO admin can set, and what it is set " +
		"to now. A court's moderators set their own court's bond, ladder and " +
		"standing rates; those are on the court's page, not here.\n\n")
	b.WriteString("Admin: `" + adminAddr().String() + "`\n\n")
	b.WriteString("| Setting | Now | What it does | Set with |\n")
	b.WriteString("|---|---|---|---|\n")
	b.WriteString("| Court creation burn | " + ugnotAmt(courtCreationBurn) +
		" GNOT | The minimum a new court costs to open. The whole payment is " +
		"burned. 0 turns it off, and off is the shipped default. | " +
		"`SetCourtCreationBurn` |\n")
	b.WriteString("| Association bond | " + ccAmt(assocBondDefault) +
		" CC | What a stranger posts to attach an edge, in courts that set no " +
		"override. | `SetAssociationBondDefault` |\n")
	b.WriteString("| Purge threshold | " + strconv.Itoa(purgeThreshold()) + " of " +
		strconv.Itoa(daoSeats()) + " | How many global moderators must agree to purge. | " +
		"`SetPurgeThreshold` |\n")
	b.WriteString("| Posting ladder | " + n(l.t1Bps) + "/" + n(l.t2Bps) + "/" +
		n(l.t3Bps) + " bps at " + n(l.postsEntry) + "/" + n(l.postsT2) + "/" +
		n(l.postsT3()) + " posts | The default rungs a court inherits: the share " +
		"earned at each tier and the post counts that reach them. | " +
		"`SetLadderDefault` |\n")
	b.WriteString("| Standing rates | flag " + n(r.flag) + " (inert), dispute " +
		n(r.dispute) + ", author " + n(r.authorHigh) + ", conviction " +
		n(r.conviction) + ", unadjudicated " + n(r.unadjudicated) +
		" bps | The default credit each act earns toward standing. Policing " +
		"ranks above authorship, which ranks above staking. The flag rate is " +
		"still settable and still bounds what authorship may be set to, but no " +
		"path credits it since the quality lane was removed. | " +
		"`SetCreditRatesDefault` |\n")
	dom := siteDomain
	if dom == "" {
		dom = "_none_"
	}
	b.WriteString("| Site domain | " + dom + " | The website this realm belongs " +
		"to. Also allow-lists that domain for images without listing it below. | " +
		"`SetSiteDomain` |\n")
	hosts := MediaHosts()
	if hosts == "|" {
		hosts = "_none_"
	}
	b.WriteString("| Media hosts | " + hosts + " | Where images may be loaded " +
		"from: exact hosts before the bar, suffixes after it. | " +
		"`SetMediaHosts` |\n")
	b.WriteString("\nBurned to date, across every court and every creation: **" +
		ugnotAmt(BurnedGNOT()) + " GNOT**, held at `" + BurnSink().String() +
		"` — an address derived from a sub-realm identity that is never created, " +
		"so no key to it exists and nothing can ever be spent from it.\n")
	return b.String()
}
