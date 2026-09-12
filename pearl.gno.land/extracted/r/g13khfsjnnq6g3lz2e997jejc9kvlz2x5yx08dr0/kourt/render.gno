package kourt
import (
	"strconv"
	"strings"
	sanitize "gno.land/p/nt/markdown/sanitize/v0"
)
func Render(path string) string {
	return withSiteBanner(render(path), path)
}
func render(path string) string {
	path = strings.Trim(path, "/")
	if path == "" {
		return renderDirectory()
	}
	parts := strings.SplitN(path, "/", 4)
	if len(parts) == 1 {
		if parts[0] == helpPath {
			return renderHelp()
		}
		if parts[0] == adminParamsPath {
			return renderAdminParams()
		}
		return renderCourt(parts[0])
	}
	if parts[1] == "mod" {
		return renderModLog(parts[0])
	}
	if parts[1] == electionPath {
		if len(parts) != 2 {
			return "## Not found\nThe ballot is /<court>/election."
		}
		return renderElection(parts[0])
	}
	if parts[1] == "folder" {
		if len(parts) != 3 {
			return "## Not found\nA folder is /<court>/folder/<id>."
		}
		fid, ferr := strconv.ParseUint(parts[2], 10, 64)
		if ferr != nil {
			return "## Not found\nA folder id must be a number."
		}
		return renderFolderPage(parts[0], fid)
	}
	if parts[1] == "me" {
		if len(parts) == 3 {
			return renderStanding(parts[0], parts[2])
		}
		return renderStandingIndex(parts[0])
	}
	id, err := strconv.ParseUint(parts[1], 10, 64)
	if err != nil {
		return "## Not found\nA claim id must be a number."
	}
	if len(parts) >= 3 && parts[2] == "board" {
		if len(parts) == 4 {
			if parts[3] == "top" {
				return renderBoardTop(parts[0], id)
			}
			if parts[3] == "hidden" {
				return renderBoardHidden(parts[0], id)
			}
			return renderBoardRow(parts[0], id, parts[3])
		}
		return renderBoardPage(parts[0], id)
	}
	if len(parts) == 4 {
		return "## Not found\nThat is not a page."
	}
	if len(parts) == 3 {
		return renderPositions(parts[0], id, parts[2])
	}
	return renderClaim(parts[0], id)
}
func renderDirectory() string {
	b := strings.Builder{}
	b.WriteString("# " + platformName + "\n\nLet Truth be told.\n\n")
	b.WriteString("Stake on claims of fact. Your principal always returns 1×.\n\n")
	b.WriteString(helpLink + "\n\n")
	afterHeader := b.Len()
	writeTier(&b, "Featured", tierFeatured)
	writeListedByBurn(&b)
	if b.Len() == afterHeader {
		b.WriteString("_No courts yet._\n")
	}
	return b.String()
}
func writeListedByBurn(b *strings.Builder) {
	slugs := listedPage("burn", 0, renderPageSize)
	if len(slugs) == 0 {
		return
	}
	b.WriteString("## Courts\n\n")
	shown := 0
	for _, s := range slugs {
		c := mustCourt(s)
		if c.tier != tierListed {
			continue
		}
		shown++
		b.WriteString("- [" + courtNameFor(c) + "](/r/kourt/kourtv2:" + s + ") · " +
			qualifiedSymbol(c) + " — " + strconv.FormatUint(c.nextID, 10) + " claims\n")
	}
	if total := len(ListByTier(int(tierListed))); total > shown {
		b.WriteString("- _…and " + strconv.Itoa(total-shown) +
			" more; open any court directly at /r/kourt/kourtv2:<slug>_\n")
	}
	b.WriteString("\n")
}
const renderPageSize = 50
func writeTier(b *strings.Builder, heading string, tier uint8) {
	slugs := ListByTier(int(tier))
	if len(slugs) == 0 {
		return
	}
	b.WriteString("## " + heading + "\n\n")
	shown := len(slugs)
	if shown > renderPageSize {
		shown = renderPageSize
	}
	for _, s := range slugs[:shown] {
		c := mustCourt(s)
		b.WriteString("- [" + courtNameFor(c) + "](/r/kourt/kourtv2:" + s + ") · " +
			qualifiedSymbol(c) + " — " + strconv.FormatUint(c.nextID, 10) + " claims\n")
	}
	if len(slugs) > shown {
		b.WriteString("- _…and " + strconv.Itoa(len(slugs)-shown) +
			" more; open any court directly at /r/kourt/kourtv2:<slug>_\n")
	}
	b.WriteString("\n")
}
func renderCourt(slug string) string {
	if !Exists(slug) {
		return "## Not found\nNo court by that slug."
	}
	c := mustCourt(slug)
	b := strings.Builder{}
	b.WriteString("# " + courtNameFor(c) + "\n\n")
	if c.tier == tierHidden {
		b.WriteString("> **Delisted by the global DAO.** This court appears in no " +
			"listing and is reachable only by direct link. Nothing else changes: " +
			"its claims still stake, answer, settle and pay out as usual.\n\n")
	}
	if d := courtDescFor(c); d != "" {
		b.WriteString(d + "\n\n")
	}
	writeFolderIndex(&b, c, slug)
	b.WriteString("## Claims\n\n")
	if c.nextID == 0 {
		b.WriteString("_No claims yet._\n\n")
		writeCourtCoin(&b, c)
		return b.String()
	}
	lo := uint64(1)
	if c.nextID > renderPageSize {
		lo = c.nextID - renderPageSize + 1
	}
	for id := c.nextID; id >= lo; id-- {
		cs := mustClaim(c, id)
		if HiddenFromListing(slug, id) {
			continue
		}
		b.WriteString("- [" + claimTitleFor(c, cs) + "](/r/kourt/kourtv2:" + slug + "/" +
			strconv.FormatUint(id, 10) + ") — " + claimStatus(cs) + "\n")
	}
	if lo > 1 {
		b.WriteString("- _…and " + strconv.FormatUint(lo-1, 10) +
			" older; open any by id at /r/kourt/kourtv2:" + slug + "/<id>_\n")
	}
	b.WriteString("\n")
	writeStrip(&b, slug)
	writePending(&b, slug)
	writeCourtCoin(&b, c)
	b.WriteString("[Moderation log](/r/kourt/kourtv2:" + slug + "/mod)\n")
	return b.String()
}
func writeCourtCoin(b *strings.Builder, c *Court) {
	b.WriteString("## This court's coin\n\n")
	b.WriteString("- " + qualifiedSymbol(c) +
		" — this court's own coin, not interchangeable with any other court's\n")
	b.WriteString("- price: " + strconv.FormatInt(c.crv.Price(c.minted), 10) +
		" ugnot per coin — buying burns the GNOT, there is no sell side, " +
		"and the price only rises\n")
	b.WriteString("- in circulation: " + strconv.FormatInt(c.coin.TotalSupply(), 10) +
		" · paid out as rewards so far: " + strconv.FormatInt(c.emittedTotal, 10) + "\n")
	b.WriteString("- reward reservoir: " + strconv.FormatInt(c.reservoirR(), 10) +
		" waiting to be earned · " + strconv.FormatInt(c.seniorOwed, 10) +
		" already owed to earlier earners\n\n")
	b.WriteString(helpLink + "\n\n")
}
func renderClaim(slug string, id uint64) string {
	if !Exists(slug) {
		return "## Not found\nNo court by that slug."
	}
	c := mustCourt(slug)
	if id == 0 || id > c.nextID {
		return "## Not found\nNo claim by that id."
	}
	cs := mustClaim(c, id)
	b := strings.Builder{}
	b.WriteString("# " + claimTitleFor(c, cs) + "\n\n")
	if body := claimBodyQuoted(c, cs); body != "" {
		b.WriteString(body)
	}
	writeClaimMedia(&b, c, cs)
	b.WriteString(hideBanner(c, cs))
	writeRelations(&b, c, id)
	writeAppeal(&b, c, cs)
	if cs.seeded {
		b.WriteString("_Seeded by a moderator to start this court; the author earns nothing from it._\n\n")
	}
	b.WriteString("## Signal\n\n")
	if cs.frozenAt != 0 {
		fTotal := cs.yesStakeAtFreeze + cs.noStakeAtFreeze
		b.WriteString("- staked when answered: " + strconv.FormatInt(fTotal, 10) +
			" " + qualifiedSymbol(c) + " (YES " + strconv.FormatInt(cs.yesStakeAtFreeze, 10) +
			" / NO " + strconv.FormatInt(cs.noStakeAtFreeze, 10) + ")\n")
		if fTotal > 0 {
			b.WriteString("- lean when answered: " + pct(cs.yesStakeAtFreeze, fTotal) + " YES\n")
		}
		if live := cs.yesStake + cs.noStake; live > 0 {
			b.WriteString("- still unwithdrawn: " + strconv.FormatInt(live, 10) +
				" " + qualifiedSymbol(c) + "\n")
		}
	} else {
		total := cs.yesStake + cs.noStake
		b.WriteString("- staked now: " + strconv.FormatInt(total, 10) +
			" " + qualifiedSymbol(c) + " (YES " + strconv.FormatInt(cs.yesStake, 10) +
			" / NO " + strconv.FormatInt(cs.noStake, 10) + ")\n")
		if total > 0 {
			b.WriteString("- right now: " + pct(cs.yesStake, total) + " YES\n")
		}
		b.WriteString("- pays: not set until the claim is answered — it is " +
			"this claim's total stake against a typical claim in this court, " +
			"so staking now is what sets it\n")
	}
	h := heightNow()
	if yAvg, ym := cs.yes.Average(h, periodBlocks); ym {
		if tAvg, tm := cs.oi.Average(h, periodBlocks); tm && tAvg > 0 {
			b.WriteString("- trailing week: " + pct(yAvg, tAvg) + " YES\n")
		}
	}
	yc := convToCC(cs.yesConvHi, cs.yesConvLo)
	nc := convToCC(cs.noConvHi, cs.noConvLo)
	if yc+nc > 0 {
		b.WriteString("- lifetime, weighted by how long each stake was held: " + pct(yc, yc+nc) + " YES\n")
	}
	b.WriteString("\n## Status\n\n" + claimStatus(cs) + "\n")
	if cs.frozenAt != 0 {
		b.WriteString("\n## Resolution\n\n")
		b.WriteString("- answer: " + sideName(int(cs.answer)) + " (bond " +
			strconv.FormatInt(cs.answerBond0, 10) + " " + qualifiedSymbol(c) + ")\n")
		b.WriteString("- the answerer has been challenged and upheld " +
			strconv.FormatInt(int64(AnswerRecord(slug, cs.answerer)), 10) +
			" time(s) in this court — answers nobody contested do not count\n")
		if PriorityGateActive(slug) {
			b.WriteString("- answer priority is live here — a record of " +
				strconv.FormatInt(int64(priorityNetRecord), 10) +
				"+ earns a 24h head start on new claims\n")
		}
		if cs.failedRounds > 0 {
			b.WriteString("- failed dispute rounds: " + strconv.FormatInt(cs.failedRounds, 10) +
				" of " + strconv.FormatInt(int64(maxFailedRounds), 10) +
				" — the next dispute bond doubles\n")
		}
		if cs.disputeOpen {
			b.WriteString("- dispute round " + strconv.FormatInt(cs.round, 10) +
				" vote open — no running total is shown here until it closes\n")
		} else if cs.verdictAt == 0 {
			b.WriteString("- disputing this answer costs a bond of " +
				strconv.FormatInt(cs.disputeBond0(), 10) + " " + qualifiedSymbol(c) +
				", doubling for each round that fails to reach a quorum\n")
			b.WriteString("  - win and the answerer's bond is burned and you are " +
				"compensated, up to twice your own bond; lose and yours burns " +
				"instead. Nothing passes between the two of you — a forfeit is " +
				"burned, a compensation is newly issued\n")
			b.WriteString("  - if the round draws no quorum, half your bond burns " +
				"and half returns; three such rounds close the claim undecided, " +
				"with every stake out at 1× and the deposit and fee refunded\n")
			b.WriteString("  - **your stake is not at risk either way** — only the " +
				"bond is\n")
		}
		if cs.verdictAt != 0 && !cs.provClose {
			b.WriteString("- verdict: " + sideName(int(cs.provisional)) + " — " + cs.route + "\n")
		}
		if cs.tierRef <= 0 {
			b.WriteString("- pays " + tierText(tierParBps) +
				" — this claim was answered before ratings were recorded, so it " +
				"pays the standard amount\n")
		} else {
			b.WriteString("- pays " + tierText(tierBpsFor(cs)) +
				" — this claim held " + strconv.FormatInt(cs.xBarFrozen, 10) +
				" " + qualifiedSymbol(c) + " against a typical " +
				strconv.FormatInt(cs.tierRef, 10) + " " + qualifiedSymbol(c) + " here\n")
			b.WriteString("- the rating is the money that showed up, not a vote: " +
				"a claim of typical size pays 1.00×, and it is capped at 0.25× and 2.00×\n")
			if cs.spamTotalW > 0 && cs.spamW > 0 {
				b.WriteString("- and " + tierText(spamNetBps(cs)) +
					" of that, because " + strconv.FormatInt(cs.spamW, 10) +
					" of " + strconv.FormatInt(cs.spamTotalW, 10) +
					" of the weight cast flagged it as spam\n")
			}
		}
		switch {
		}
		if cs.rewardsOpened {
			w, a, ans, carrot := cs.drawWinners, cs.drawAuthor, cs.drawAnswerer, cs.carrotPool
			b.WriteString("- rewards open — pools (" + qualifiedSymbol(c) +
				"): accuracy " + strconv.FormatInt(w, 10) +
				", author " + strconv.FormatInt(a, 10) + ", answerer " + strconv.FormatInt(ans, 10) +
				", participation remaining " + strconv.FormatInt(carrot, 10) + "\n")
		}
	}
	b.WriteString("\n_To see your own stake on this claim, put your address on " +
		"the end of this page's path:_ `/r/kourt/kourtv2:" + sanitize.InlineText(slug) +
		"/" + strconv.FormatUint(id, 10) + "/<your address>`\n\n")
	writeBoardLink(&b, c, cs, id)
	return b.String()
}
func renderPositions(slug string, id uint64, addrStr string) string {
	if !Exists(slug) {
		return "## Not found\nNo court by that slug."
	}
	c := mustCourt(slug)
	if id == 0 || id > c.nextID {
		return "## Not found\nNo claim by that id."
	}
	who := address(addrStr)
	if !who.IsValid() {
		return "## Not found\nThat is not a valid address."
	}
	cs := mustClaim(c, id)
	b := strings.Builder{}
	b.WriteString("# Positions on this claim\n\n")
	b.WriteString(hideBanner(c, cs))
	b.WriteString("Claim: [" + claimTitleFor(c, cs) + "](/r/kourt/kourtv2:" + slug +
		"/" + strconv.FormatUint(id, 10) + ") in [" + courtNameFor(c) +
		"](/r/kourt/kourtv2:" + slug + ")\n\n")
	b.WriteString("Address: " + sanitize.InlineText(addrStr) + "\n\n")
	yStake := StakeOf(slug, id, sideYES, who)
	nStake := StakeOf(slug, id, sideNO, who)
	yConv := ConvictionOf(slug, id, sideYES, who)
	nConv := ConvictionOf(slug, id, sideNO, who)
	b.WriteString("## Stake (what you have in, and always get back)\n\n")
	b.WriteString("- YES: " + strconv.FormatInt(yStake, 10) +
		"   NO: " + strconv.FormatInt(nStake, 10) + " (" + qualifiedSymbol(c) +
		" base units)\n")
	b.WriteString("- conviction so far — YES: " + strconv.FormatInt(yConv, 10) +
		"   NO: " + strconv.FormatInt(nConv, 10) + " (the reward weight)\n")
	bal := c.coin.BalanceOf(who)
	locked := lockedOf(c, who)
	voted := voteLockedOf(c, who)
	b.WriteString("\n## This address's " + qualifiedSymbol(c) +
		" in this court (all claims)\n\n")
	b.WriteString("- held: " + strconv.FormatInt(bal, 10) +
		" — every unit votes, committed or not\n")
	b.WriteString("- committed as stake: " + strconv.FormatInt(locked, 10) + "\n")
	b.WriteString("- committed by voting: " + strconv.FormatInt(voted, 10) +
		" — until each question resolves\n")
	b.WriteString("- free to stake: " + strconv.FormatInt(spendable(c, who), 10) + "\n")
	b.WriteString("- free to bond, deposit or transfer: " +
		strconv.FormatInt(disposable(c, who), 10) + "\n")
	roles := ""
	if who == cs.author {
		roles += "author "
	}
	if cs.frozenAt != 0 && who == cs.answerer {
		roles += "answerer "
	}
	if roles != "" {
		b.WriteString("- roles: " + roles + "\n")
	}
	if rec := AnswerRecord(slug, who); rec > 0 {
		b.WriteString("- answers challenged and upheld in this court: " + strconv.FormatInt(int64(rec), 10) + "\n")
	}
	b.WriteString("\n## What you can do\n\n")
	switch {
	case cs.verdictAt == 0 && cs.frozenAt == 0:
		b.WriteString("- staking is open — stake or unstake freely until an answer posts\n")
	case cs.verdictAt == 0:
		b.WriteString("- answered, awaiting the verdict — principal is never withheld; withdraw once it is final\n")
	default:
		b.WriteString("- the verdict is final — withdraw your principal on either side (1×)\n")
		if cs.rewardsOpened {
			win := int(cs.provisional)
			if !cs.provClose && ((win == sideYES && yStake+yConv > 0) || (win == sideNO && nStake+nConv > 0)) {
				b.WriteString("- you backed the winning side — pull your accuracy reward\n")
			}
			if who == cs.author && cs.drawAuthor > 0 {
				b.WriteString("- author reward available — pull it\n")
			}
			if who == cs.answerer && cs.drawAnswerer > 0 {
				b.WriteString("- answerer reward available — pull it\n")
			}
		}
	}
	return b.String()
}
func tierText(bps int64) string {
	if bps < 0 {
		bps = 0
	}
	frac := (bps % tierParBps) / 100
	out := strconv.FormatInt(bps/tierParBps, 10) + "."
	if frac < 10 {
		out += "0"
	}
	return out + strconv.FormatInt(frac, 10) + "×"
}
func sideName(side int) string {
	if side == sideYES {
		return "YES"
	}
	return "NO"
}
func ClaimStatus(courtSlug string, claimID uint64) string {
	return claimStatus(mustClaim(mustCourt(courtSlug), claimID))
}
func claimStatus(cs *claimState) string {
	switch {
	case cs.closed:
		return "closed — never answered; every stake exited 1×, the deposit refunded"
	case cs.spamClosed:
		return "discarded — more than half the weight cast called this claim spam; " +
			"every stake withdraws 1×, the answerer's and disputer's bonds return, " +
			"the filing fee burns"
	case cs.provClose:
		return "closed without a decision — three dispute rounds failed quorum; everyone withdraws 1×, deposit and fee refunded"
	case cs.verdictAt != 0:
		return "settled " + sideName(int(cs.provisional)) + " — every stake withdraws 1×"
	case cs.disputeOpen:
		disputed := int(cs.answer)
		if cs.provisional >= 0 {
			disputed = int(cs.provisional)
		}
		return "disputed " + sideName(disputed) +
			" — a sealed vote is deciding; principal is never withheld"
	case cs.provisional >= 0:
		return "provisional verdict " + sideName(int(cs.provisional)) +
			" — reopenable by a new dispute until block " + strconv.FormatInt(cs.escrowUntil, 10) +
			"; the side it is against may withdraw 1× now"
	case cs.frozenAt != 0:
		return "answered " + sideName(int(cs.answer)) +
			" — staking frozen; disputable until block " +
			strconv.FormatInt(cs.answerHeight+settleDelay, 10) + ", then it settles undisputed"
	default:
		return "open — stake YES or NO; unstake freely until an answer posts"
	}
}
func pct(num, den int64) string {
	if den <= 0 || num < 0 {
		return "—"
	}
	bps := mulDiv128(num, 10000, den)
	return strconv.FormatInt(bps/100, 10) + "." + pad2(bps%100) + "%"
}
func pad2(v int64) string {
	if v < 10 {
		return "0" + strconv.FormatInt(v, 10)
	}
	return strconv.FormatInt(v, 10)
}
func writeFolderIndex(b *strings.Builder, c *Court, slug string) {
	if c.mod == nil {
		return
	}
	shown := 0
	for _, f := range c.mod.folderRows() {
		if f.parent != 0 || f.retired || f.purged {
			continue
		}
		if shown == 0 {
			b.WriteString("Filed under: ")
		} else {
			b.WriteString(" · ")
		}
		b.WriteString("[" + sanitize.InlineText(f.name) + "](/r/kourt/kourtv2:" +
			slug + "/folder/" + strconv.FormatUint(f.id, 10) + ")")
		shown++
	}
	if shown > 0 {
		b.WriteString("\n\n")
	}
}
func renderFolderPage(slug string, fid uint64) string {
	if !Exists(slug) {
		return "## Not found\nNo court by that slug."
	}
	c := mustCourt(slug)
	if c.mod == nil {
		return "## Not found\nThis court has no folders."
	}
	v := c.mod.folders.Get(beClaimKey(fid))
	if v == nil {
		return "## Not found\nNo folder by that id."
	}
	f := v.(*folder)
	base := "/r/kourt/kourtv2:" + slug
	var b strings.Builder
	if f.purged {
		b.WriteString("# [purged:" + sanitize.InlineText(f.code) + "]\n\n")
		b.WriteString("_This heading was purged by the global DAO. Its name and " +
			"description were erased, not hidden._\n\n")
		b.WriteString("[← " + courtNameFor(c) + "](" + base + ")\n")
		return b.String()
	}
	b.WriteString("# " + sanitize.InlineText(f.name) + "\n\n")
	b.WriteString("[← " + courtNameFor(c) + "](" + base + ")")
	for up, n := f.parent, 0; up != 0 && n <= maxFolders; n++ {
		pv := c.mod.folders.Get(beClaimKey(up))
		if pv == nil {
			break
		}
		pf := pv.(*folder)
		b.WriteString(" · [" + sanitize.InlineText(pf.name) + "](" + base +
			"/folder/" + strconv.FormatUint(pf.id, 10) + ")")
		up = pf.parent
	}
	b.WriteString("\n\n")
	if f.retired {
		b.WriteString("> This heading was retired by a moderator. It is kept so " +
			"links to it still resolve.\n\n")
	}
	if f.bornOf != 0 {
		b.WriteString("> The court voted this heading into existence: [claim #" +
			strconv.FormatUint(f.bornOf, 10) + "](" + base + "/" +
			strconv.FormatUint(f.bornOf, 10) + ") settled YES, and carrying it was " +
			"a second act anyone could take.\n\n")
	}
	if f.desc != "" {
		b.WriteString(sanitize.Block(f.desc) + "\n")
	}
	kids := 0
	for _, k := range c.mod.folderRows() {
		if k.parent != f.id || k.retired || k.purged {
			continue
		}
		if kids == 0 {
			b.WriteString("## Under this heading\n\n")
		}
		kids++
		b.WriteString("- [" + sanitize.InlineText(k.name) + "](" + base + "/folder/" +
			strconv.FormatUint(k.id, 10) + ")\n")
	}
	if kids > 0 {
		b.WriteString("\n")
	}
	b.WriteString("## Claims filed here\n\n")
	filed := 0
	for _, id := range f.items {
		if id == 0 || id > c.nextID {
			continue
		}
		cs := mustClaim(c, id)
		filed++
		b.WriteString("- [" + claimTitleFor(c, cs) + "](" + base + "/" +
			strconv.FormatUint(id, 10) + ") — " + claimStatus(cs) + "\n")
	}
	if filed == 0 {
		b.WriteString("_Nothing filed here yet._\n")
	}
	b.WriteString("\n_A folder curates and can never bury: every claim above is " +
		"also on the court's own newest-first list, and nothing is reachable only " +
		"from here._\n\n")
	b.WriteString(helpLink + "\n")
	return b.String()
}
