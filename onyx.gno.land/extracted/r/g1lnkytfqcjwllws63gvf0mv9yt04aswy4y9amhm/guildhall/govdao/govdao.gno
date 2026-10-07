// Package govdao is an optional, one-way adapter from Guildhall reputation to
// GovDAO membership. Guildhall does not depend on it and GovDAO has no
// authority over it or over any other Guildhall realm; it only reads
// reputation and builds proposals that GovDAO members may choose to submit.
//
// It turns a contributor's on-chain work records into two inputs for GovDAO:
//
//   - an eligibility check: a minimum reputation score per tier, and
//   - a portfolio: a summary of the contributor's paid, reviewed work, with
//     links to every record, generated from chain state rather than written
//     by hand.
//
// GovDAO only accepts proposals created directly by a member's transaction,
// so this realm never creates proposals itself. It builds the request; the
// member submits it from a `gnokey maketx run` script:
//
//	package main
//
//	import (
//		"gno.land/r/gov/dao"
//		guild "gno.land/r/g1lnkytfqcjwllws63gvf0mv9yt04aswy4y9amhm/guildhall/govdao"
//	)
//
//	func main(cur realm) {
//		req := guild.NewMemberRequest(cross(cur), "g1candidate...", "T2")
//		dao.MustCreateProposal(cross(cur), req)
//	}
//
// The thresholds are set by the Guildhall admin with SetThreshold. They are
// Guildhall's bar for the candidates it vouches for; GovDAO's vote decides.
package govdao

import (
	"chain"
	"strconv"
	"strings"

	"gno.land/p/g1lnkytfqcjwllws63gvf0mv9yt04aswy4y9amhm/guildhall/jsonw/v0"
	"gno.land/p/nt/avl/v0"
	"gno.land/p/nt/markdown/sanitize/v0"
	"gno.land/p/nt/ufmt/v0"
	"gno.land/r/g1lnkytfqcjwllws63gvf0mv9yt04aswy4y9amhm/guildhall/reputation"
	"gno.land/r/gov/dao"
	impl "gno.land/r/gov/dao/impl/v0"
	"gno.land/r/gov/dao/memberstore/v0"
)

const (
	portfolioRecords = 10
	chainURL         = "https://gno.land"
)

// thresholds maps tier -> minimum reputation score.
var thresholds avl.Tree

func init() {
	thresholds.Set(memberstore.T1, int64(2000))
	thresholds.Set(memberstore.T2, int64(800))
	thresholds.Set(memberstore.T3, int64(300))
}

// Threshold returns the minimum score required to be proposed for tier.
func Threshold(tier string) int64 {
	v := thresholds.Get(tier)
	if v == nil {
		return -1
	}
	return v.(int64)
}

// Eligible reports whether addr meets the reputation bar for tier and, if
// not, why.
func Eligible(addr address, tier string) (bool, string) {
	min := Threshold(tier)
	if min < 0 {
		return false, "unknown tier " + strconv.Quote(tier)
	}
	if !addr.IsValid() {
		return false, "invalid address"
	}
	score := reputation.Score(addr)
	if score < min {
		return false, ufmt.Sprintf("reputation %d is below the %s threshold of %d", score, tier, min)
	}
	return true, ""
}

// AssertEligible panics unless addr meets the reputation bar for tier.
func AssertEligible(addr address, tier string) {
	if ok, why := Eligible(addr, tier); !ok {
		panic("guildhall: " + why)
	}
}

// Portfolio renders addr's Guildhall track record as markdown suitable for a
// GovDAO membership proposal.
func Portfolio(addr address) string {
	var b strings.Builder
	score := reputation.Score(addr)
	b.WriteString(ufmt.Sprintf("**Guildhall reputation: %d (%s)**", score, reputation.Level(addr)))
	if r := reputation.Rank(addr); r > 0 {
		b.WriteString(ufmt.Sprintf(", ranked #%d", r))
	}
	b.WriteString("\n\n")
	b.WriteString(ufmt.Sprintf("- Paid work records: %d\n", reputation.CompletedCount(addr)))
	b.WriteString(ufmt.Sprintf("- Reviews given: %d\n", reputation.ReviewCount(addr)))
	if gnot := reputation.Earned(addr, "ugnot"); gnot > 0 {
		b.WriteString("- Earned through bounties: " + gnotString(gnot) + "\n")
	}
	b.WriteString(ufmt.Sprintf("- Full profile: %s/r/g1lnkytfqcjwllws63gvf0mv9yt04aswy4y9amhm/guildhall/reputation:u/%s\n\n", chainURL, addr.String()))

	recs := reputation.RecordsOf(addr, 0, portfolioRecords)
	if len(recs) > 0 {
		b.WriteString("Most recent work:\n\n")
		for _, r := range recs {
			if r.Voided {
				continue
			}
			b.WriteString(ufmt.Sprintf("- %s (+%d, record #%d)", sanitize.InlineText(r.Title), r.Points, r.ID))
			if u := sanitize.URL(r.Link); u != "" && strings.HasPrefix(r.Link, "https://") {
				b.WriteString(" · [work](" + u + ")")
			}
			b.WriteString("\n")
		}
		b.WriteString("\n")
	}
	b.WriteString("_Generated from on-chain records by gno.land/r/g1lnkytfqcjwllws63gvf0mv9yt04aswy4y9amhm/guildhall/govdao._")
	return b.String()
}

// NewMemberRequest builds a GovDAO proposal to add addr to tier, with its
// Guildhall portfolio attached. It panics if addr does not meet the tier's
// reputation threshold. GovDAO's own rules still apply: the signer must be a
// member with an invitation point, and only T1 and T2 are proposal-gated.
func NewMemberRequest(cur realm, addr address, tier string) dao.ProposalRequest {
	AssertEligible(addr, tier)
	return impl.NewAddMemberRequest(cross(cur), addr, tier, Portfolio(addr))
}

// SetThreshold changes the minimum score for tier. Only the Guildhall admin
// (reputation.Admin) may call it: the bar is Guildhall's statement of who it
// vouches for, and GovDAO is free to ignore it.
func SetThreshold(cur realm, tier string, min int64) {
	if cur.Previous().Address() != reputation.Admin() {
		panic("guildhall: only the Guildhall admin may change thresholds")
	}
	validateThreshold(tier, min)
	thresholds.Set(tier, min)
	chain.Emit("GuildhallThresholdChanged", "tier", tier, "min", strconv.FormatInt(min, 10))
}

func validateThreshold(tier string, min int64) {
	if _, ok := memberstore.GetTier(tier); !ok {
		panic("guildhall: unknown tier " + strconv.Quote(tier))
	}
	if min < 0 {
		panic("guildhall: threshold must not be negative")
	}
}

// Render shows the thresholds and, for u/<address>, that address's
// eligibility and generated portfolio.
func Render(path string) string {
	path = strings.Trim(path, "/")
	if strings.HasPrefix(path, "api/candidate/") {
		return apiCandidate(address(strings.TrimPrefix(path, "api/candidate/")))
	}
	if strings.HasPrefix(path, "u/") {
		return renderCandidate(address(strings.TrimPrefix(path, "u/")))
	}
	var b strings.Builder
	b.WriteString("# Guildhall × GovDAO\n\n")
	b.WriteString("Guildhall reputation is an on-chain input to GovDAO membership. A contributor can be proposed for a tier once their score reaches its threshold, and the proposal carries a portfolio generated from their work records.\n\n")
	b.WriteString("| Tier | Minimum reputation |\n|---|---:|\n")
	thresholds.Iterate("", "", func(k string, v any) bool {
		b.WriteString(ufmt.Sprintf("| %s | %d |\n", k, v.(int64)))
		return false
	})
	b.WriteString("\nThresholds are set by the Guildhall admin. GovDAO's vote still decides every membership; Guildhall only vouches.\n\n")
	b.WriteString("Check a candidate at `/r/g1lnkytfqcjwllws63gvf0mv9yt04aswy4y9amhm/guildhall/govdao:u/<address>`.\n\n")
	b.WriteString("## Proposing a member\n\n```go\npackage main\n\nimport (\n\t\"gno.land/r/gov/dao\"\n\tguild \"gno.land/r/g1lnkytfqcjwllws63gvf0mv9yt04aswy4y9amhm/guildhall/govdao\"\n)\n\nfunc main(cur realm) {\n\treq := guild.NewMemberRequest(cross(cur), \"g1candidate...\", \"T2\")\n\tdao.MustCreateProposal(cross(cur), req)\n}\n```\n\n")
	b.WriteString("Run it with `gnokey maketx run` from a GovDAO member's key.\n")
	return b.String()
}

func renderCandidate(addr address) string {
	if !addr.IsValid() {
		return "# Not found\n"
	}
	var b strings.Builder
	b.WriteString("# Candidate " + addr.String() + "\n\n")
	b.WriteString("| Tier | Required | Eligible |\n|---|---:|---|\n")
	thresholds.Iterate("", "", func(k string, v any) bool {
		mark := "no"
		if ok, _ := Eligible(addr, k); ok {
			mark = "yes"
		}
		b.WriteString(ufmt.Sprintf("| %s | %d | %s |\n", k, v.(int64), mark))
		return false
	})
	b.WriteString("\n## Portfolio\n\n" + Portfolio(addr) + "\n")
	return b.String()
}

// apiCandidate serves JSON for the web app: per-tier thresholds and whether
// addr meets each.
func apiCandidate(addr address) string {
	if !addr.IsValid() {
		return jsonw.Obj("error", jsonw.String("invalid address"))
	}
	var tiers []string
	thresholds.Iterate("", "", func(k string, v any) bool {
		ok, _ := Eligible(addr, k)
		tiers = append(tiers, jsonw.Obj("tier", jsonw.String(k), "min", jsonw.Int(v.(int64)), "eligible", jsonw.Bool(ok)))
		return false
	})
	return jsonw.Obj("address", jsonw.String(addr.String()), "score", jsonw.Int(reputation.Score(addr)), "tiers", jsonw.Arr(tiers))
}

func gnotString(ugnot int64) string {
	whole := ugnot / 1_000_000
	frac := ugnot % 1_000_000
	if frac == 0 {
		return strconv.FormatInt(whole, 10) + " GNOT"
	}
	fs := strconv.FormatInt(frac, 10)
	for len(fs) < 6 {
		fs = "0" + fs
	}
	return strconv.FormatInt(whole, 10) + "." + strings.TrimRight(fs, "0") + " GNOT"
}
