// Package guildhall is the front door of Guildhall: fund work, track it, and
// turn finished work into a record anyone can check.
//
//	gno.land/r/g1lnkytfqcjwllws63gvf0mv9yt04aswy4y9amhm/guildhall/bounties     escrowed bounties with milestones, reviewers and disputes
//	gno.land/r/g1lnkytfqcjwllws63gvf0mv9yt04aswy4y9amhm/guildhall/reputation   work records and reputation other realms can import
//	gno.land/r/g1lnkytfqcjwllws63gvf0mv9yt04aswy4y9amhm/guildhall/govdao       optional adapter: reputation as an input to GovDAO membership
package guildhall

import (
	"strings"

	"gno.land/p/g1lnkytfqcjwllws63gvf0mv9yt04aswy4y9amhm/guildhall/trust/v0"
	"gno.land/p/nt/ufmt/v0"
	"gno.land/r/g1lnkytfqcjwllws63gvf0mv9yt04aswy4y9amhm/guildhall/bounties"
	"gno.land/r/g1lnkytfqcjwllws63gvf0mv9yt04aswy4y9amhm/guildhall/reputation"
)

func Render(_ string) string {
	var b strings.Builder
	b.WriteString("# Guildhall\n\n")
	b.WriteString("**Fund work, track it, and turn finished work into a record anyone can check.**\n\n")
	b.WriteString("Post a task and escrow GNOT or any registered GRC20 token against it. Split it into milestones and name the reviewers. ")
	b.WriteString("Each approved milestone pays the contributor and writes a public record of the work: who did it, who vouched for it, and a link to the PR, realm or proposal. ")
	b.WriteString("Those records add up to a reputation that any realm can read with one import. Guildhall governs itself; no outside realm has authority over it.\n\n")

	b.WriteString(ufmt.Sprintf("| Open bounties | In progress | Completed | Work records | Ranked contributors |\n|---:|---:|---:|---:|---:|\n| %d | %d | %d | %d | %d |\n\n",
		bounties.CountByStatus("open"), bounties.CountByStatus("active"), bounties.CountByStatus("completed"),
		reputation.RecordCount(), reputation.ContributorCount()))

	b.WriteString("- [**Bounty board**](/r/g1lnkytfqcjwllws63gvf0mv9yt04aswy4y9amhm/guildhall/bounties): find work or [post a bounty](/r/g1lnkytfqcjwllws63gvf0mv9yt04aswy4y9amhm/guildhall/bounties:post)\n")
	b.WriteString("- [**Reputation**](/r/g1lnkytfqcjwllws63gvf0mv9yt04aswy4y9amhm/guildhall/reputation): leaderboard, profiles and [how scoring works](/r/g1lnkytfqcjwllws63gvf0mv9yt04aswy4y9amhm/guildhall/reputation:about)\n")
	b.WriteString("- [**GovDAO**](/r/g1lnkytfqcjwllws63gvf0mv9yt04aswy4y9amhm/guildhall/govdao): an optional bridge that lets GovDAO members propose high-reputation contributors\n\n")

	top := reputation.Top(5)
	if len(top) > 0 {
		b.WriteString("## Top contributors\n\n")
		for i, s := range top {
			b.WriteString(ufmt.Sprintf("%d. [%s](/r/g1lnkytfqcjwllws63gvf0mv9yt04aswy4y9amhm/guildhall/reputation:u/%s): %d (%s)\n", i+1, s.Addr.String(), s.Addr.String(), s.Score, trust.Level(s.Score)))
		}
		b.WriteString("\n")
	}

	b.WriteString("## How it works\n\n")
	b.WriteString("1. **Post.** Send funds with `PostBounty`. They stay in the realm, not with the poster.\n")
	b.WriteString("2. **Assign.** Contributors apply and the poster picks one.\n")
	b.WriteString("3. **Deliver.** The contributor submits each milestone with a link to the work.\n")
	b.WriteString("4. **Review.** Once enough reviewers approve, the milestone pays out and a reputation record is written.\n")
	b.WriteString("5. **Dispute.** If reviewer and contributor disagree, the arbiter pays, refunds or splits.\n\n")

	b.WriteString("## Gate your realm on reputation\n\n")
	b.WriteString("```go\nimport \"gno.land/r/g1lnkytfqcjwllws63gvf0mv9yt04aswy4y9amhm/guildhall/reputation\"\n\nfunc Post(cur realm, body string) {\n\treputation.AssertScore(cur.Previous().Address(), 100)\n\t// ...\n}\n```\n")
	return b.String()
}
