// Package hearthguild is a companion consumer realm that imports both
// hearthcore/v0 (pure formatting, tier math, SVG badges, RFC-8259 JSON) and
// hearthbounty/v1 (live escrow stats, builder profiles, and Unicode-safe
// tag neutralization) to provide composable on-chain builder passports and
// peer skill endorsements for DAOs and grant programs.
package hearthguild

import (
	"chain"
	"chain/runtime"
	"strconv"
	"strings"

	"gno.land/p/g1x582angdzrqadgv4382j6y7ju6fj5wll6yuuq4/hearthcore/v0"
	"gno.land/p/nt/avl/v0"
	"gno.land/p/nt/markdown/sanitize/v0"
	"gno.land/p/nt/mux/v0"
	"gno.land/p/nt/seqid/v0"
	"gno.land/r/g1x582angdzrqadgv4382j6y7ju6fj5wll6yuuq4/hearthbounty/v1"
)

type endorsementRecord struct {
	ID       uint64
	Builder  address
	Endorser address
	SkillTag string
	Note     string
	Height   int64
}

// EndorsementView is an immutable value copy of a guild endorsement.
type EndorsementView struct {
	ID       uint64
	Builder  address
	Endorser address
	SkillTag string
	Note     string
	Height   int64
}

var (
	guildPkgPath  string
	guildWebBase  string
	endorseSeq    seqid.ID
	endorsements  *avl.Tree // seqid -> *endorsementRecord
	endorsedByKey *avl.Tree // "endorser/builder" -> true
	builderCounts *avl.Tree // builder address string -> uint64
	router        *mux.Router
)

func init(cur realm) {
	guildPkgPath = cur.PkgPath()
	idx := strings.Index(guildPkgPath, "/")
	if idx == -1 {
		guildWebBase = "/r/g1x582angdzrqadgv4382j6y7ju6fj5wll6yuuq4/hearthguild/v0"
	} else {
		guildWebBase = guildPkgPath[idx:]
	}
	endorsements = avl.NewTree()
	endorsedByKey = avl.NewTree()
	builderCounts = avl.NewTree()
	initRouter()
}

func initRouter() {
	router = mux.NewRouter()
	router.HandleFunc("", renderHome)
	router.HandleFunc("passport/{addr}", renderPassport)
	router.NotFoundHandler = renderNotFound
}

// EndorseBuilder records a peer skill endorsement backed by the builder's live
// hearthbounty/v1 profile. Self-endorsement and duplicate endorser->builder
// attestations are rejected.
func EndorseBuilder(cur realm, builder address, skillTag, note string) uint64 {
	caller := cur.Previous().Address()
	if !builder.IsValid() {
		panic("hearthguild: invalid builder address")
	}
	if caller == builder {
		panic("hearthguild: cannot endorse yourself")
	}
	if _, ok := hearthbounty.GetProfile(builder); !ok {
		panic("hearthguild: builder has no hearthbounty/v1 profile")
	}

	pairKey := string(caller) + "/" + string(builder)
	if endorsedByKey.Has(pairKey) {
		panic("hearthguild: caller already endorsed this builder")
	}

	cleanTag := hearthcore.ValidateText("skillTag", skillTag, 2, 32)
	cleanNote := hearthcore.ValidateText("note", note, 6, 240)
	nextID := uint64(endorseSeq.Next())
	height := runtime.ChainHeight()

	rec := &endorsementRecord{
		ID:       nextID,
		Builder:  builder,
		Endorser: caller,
		SkillTag: cleanTag,
		Note:     cleanNote,
		Height:   height,
	}
	endorsements.Set(seqid.ID(nextID).String(), rec)
	endorsedByKey.Set(pairKey, true)

	bKey := string(builder)
	prev := uint64(0)
	if raw := builderCounts.Get(bKey); raw != nil {
		prev = raw.(uint64)
	}
	builderCounts.Set(bKey, prev+1)

	chain.Emit(
		"BuilderEndorsed",
		"id", strconv.FormatUint(nextID, 10),
		"builder", string(builder),
		"endorser", string(caller),
		"skill_tag", cleanTag,
	)

	return nextID
}

// CheckEligibility evaluates whether a builder or AI agent meets DAO/grant
// thresholds directly from live hearthbounty/v1 on-chain track record.
func CheckEligibility(builder address, minSettled uint64, minEarnedUgnot int64) bool {
	p, ok := hearthbounty.GetProfile(builder)
	if !ok {
		return false
	}
	return p.SettledCount >= minSettled && p.EarnedUgnot >= minEarnedUgnot
}

// EndorsementCount returns how many unique peer endorsements builder has received.
func EndorsementCount(builder address) uint64 {
	if raw := builderCounts.Get(string(builder)); raw != nil {
		return raw.(uint64)
	}
	return 0
}

// ExportPassportJSON emits a deterministic JSON credential combining live
// hearthbounty/v1 reputation data with hearthguild/v0 peer endorsements.
func ExportPassportJSON(builderStr string) string {
	addr := address(strings.TrimSpace(builderStr))
	p, ok := hearthbounty.GetProfile(addr)
	if !ok {
		return `{"found":false}`
	}
	stats := hearthbounty.GetStats()
	eCount := EndorsementCount(addr)

	return hearthcore.NewJSONObject().
		Bool("found", true).
		Str("consumer_realm", guildPkgPath).
		Str("upstream_realm", hearthbounty.PkgPath()).
		Str("address", string(p.Address)).
		Str("handle", p.Handle).
		Bool("is_agent", p.IsAgent).
		Str("tier", string(p.Tier)).
		Uint64("settled_count", p.SettledCount).
		Int64("earned_ugnot", p.EarnedUgnot).
		Str("earned_formatted", hearthcore.FormatGNOT(p.EarnedUgnot)).
		Str("rating_formatted", hearthcore.FormatRating(p.RatingSum, p.RatingCount)).
		Uint64("endorsement_count", eCount).
		Int64("upstream_total_bounties", int64(stats.TotalBounties)).
		Int64("upstream_total_escrow_ugnot", stats.TotalEscrowUgnot).
		String()
}

// Render serves the native gnoweb Guild Passport interface.
func Render(path string) string {
	return router.Render(path)
}

func safeText(s string) string {
	return hearthbounty.NeutralizeGnoTags(hearthcore.EscapeMath(sanitize.InlineText(s)))
}

func safeCell(s string) string {
	return hearthbounty.NeutralizeGnoTags(hearthcore.EscapeMath(sanitize.TableCell(s)))
}

func renderHome(res *mux.ResponseWriter, req *mux.Request) {
	var b strings.Builder
	stats := hearthbounty.GetStats()

	b.WriteString("# <gno-icon name=\"shield\" /> HearthGuild Passport\n\n")
	b.WriteString("Composable consumer realm reading live reputation and escrow metrics from `")
	b.WriteString(safeText(hearthbounty.PkgPath()))
	b.WriteString("` and rendering deterministic badges via `hearthcore/v0`.\n\n")

	b.WriteString("<gno-columns>\n")
	b.WriteString("<gno-frame>\n")
	b.WriteString("### Upstream Bounty Board\n\n")
	b.WriteString("- **Total Bounties:** **" + strconv.Itoa(stats.TotalBounties) + "**\n")
	b.WriteString("- **Active Escrow:** **" + hearthcore.FormatGNOT(stats.TotalEscrowUgnot) + "**\n")
	b.WriteString("- **Settled Volume:** **" + hearthcore.FormatGNOT(stats.TotalSettledUgnot) + "**\n")
	b.WriteString("</gno-frame>\n")
	b.WriteString("<gno-columns-sep />\n")
	b.WriteString("<gno-frame>\n")
	b.WriteString("### Guild Credential Registry\n\n")
	b.WriteString("- **Upstream Profiles:** **" + strconv.Itoa(stats.ProfileCount) + "** (" + strconv.Itoa(stats.AgentCount) + " AI agents)\n")
	b.WriteString("- **Peer Endorsements:** **" + strconv.Itoa(endorsements.Size()) + "**\n")
	b.WriteString("- **Gate Helper:** `CheckEligibility(addr, minSettled, minEarnedUgnot)`\n")
	b.WriteString("</gno-frame>\n")
	b.WriteString("</gno-columns>\n\n")

	b.WriteString("## Recent Peer Endorsements\n\n")
	if endorsements.Size() == 0 {
		b.WriteString("> [!INFO] No Endorsements Yet\n")
		b.WriteString("> Endorse any registered `hearthbounty/v1` builder or AI agent below.\n\n")
	} else {
		b.WriteString("| ID | Builder | Skill | Endorser | Note |\n")
		b.WriteString("|---:|---|---|---|---|\n")
		shown := 0
		endorsements.ReverseIterate("", "", func(_ string, val any) bool {
			rec := val.(*endorsementRecord)
			bLink := "[" + safeCell(hearthcore.ShortAddr(rec.Builder)) + "](" + guildWebBase + ":passport/" + string(rec.Builder) + ")"
			b.WriteString("| `" + strconv.FormatUint(rec.ID, 10) + "` | " + bLink + " | **" + safeCell(rec.SkillTag) + "** | `" +
				safeCell(hearthcore.ShortAddr(rec.Endorser)) + "` | " + safeCell(rec.Note) + " |\n")
			shown++
			return shown >= 25
		})
		b.WriteString("\n")
	}

	b.WriteString("## Endorse a Registered Builder or AI Agent\n\n")
	b.WriteString("<gno-form exec=\"EndorseBuilder\">\n")
	b.WriteString("<gno-input name=\"builder\" type=\"text\" placeholder=\"Builder or AI agent g1... address\" required=\"true\" />\n")
	b.WriteString("<gno-input name=\"skillTag\" type=\"text\" placeholder=\"Skill tag (e.g. audit, avl, mcp)\" required=\"true\" />\n")
	b.WriteString("<gno-textarea name=\"note\" placeholder=\"Verification note citing settled bounty work\" rows=\"3\" required=\"true\" />\n")
	b.WriteString("</gno-form>\n")

	res.Write(b.String())
}

func renderPassport(res *mux.ResponseWriter, req *mux.Request) {
	addrStr := req.GetVar("addr")
	addr := address(addrStr)
	p, ok := hearthbounty.GetProfile(addr)
	if !ok {
		renderNotFound(res, req)
		return
	}

	var b strings.Builder
	b.WriteString("# <gno-icon name=\"shield\" /> Guild Passport: " + safeText(p.Handle) + "\n\n")
	b.WriteString(`<gno-button href="` + guildWebBase + `" label="Back to HearthGuild" variant="outline" />` + "\n\n")
	b.WriteString(hearthcore.RenderTierBadgeSVG(p.Handle, p.Tier, p.SettledCount, p.EarnedUgnot, p.IsAgent))
	b.WriteString("\n\n")
	b.WriteString("- **Address:** `" + safeText(string(p.Address)) + "`\n")
	b.WriteString("- **Upstream Tier:** **" + string(p.Tier) + "** (" + strconv.FormatUint(p.SettledCount, 10) + " settled, " + hearthcore.FormatGNOT(p.EarnedUgnot) + " earned)\n")
	b.WriteString("- **Peer Endorsements:** **" + strconv.FormatUint(EndorsementCount(addr), 10) + "**\n")
	res.Write(b.String())
}

func renderNotFound(res *mux.ResponseWriter, req *mux.Request) {
	res.Write("# Passport Not Found\n\nNo `hearthbounty/v1` profile matched `" + safeText(req.Path) + "`.\n")
}
