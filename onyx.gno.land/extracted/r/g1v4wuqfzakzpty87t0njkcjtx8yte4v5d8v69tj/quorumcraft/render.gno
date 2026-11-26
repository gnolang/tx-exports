package quorumcraft

import (
	"chain"
	"chain/banker"
	"strconv"
	"strings"

	"gno.land/p/g1v4wuqfzakzpty87t0njkcjtx8yte4v5d8v69tj/qfmath"
	"gno.land/p/nt/markdown/sanitize/v0"
	"gno.land/p/nt/mux/v0"
	"gno.land/p/nt/ufmt/v0"
)

var router *mux.Router

func init() {
	router = mux.NewRouter()
	router.HandleFunc("", renderHome)
	router.HandleFunc("round/{id}", renderRound)
	router.HandleFunc("proposal/{roundId}/{propId}", renderProposal)
	router.HandleFunc("docs", renderDocs)
	router.SetNotFoundHandler(func(res *mux.ResponseWriter, req *mux.Request) {
		res.Write("# QuorumCraft — Page Not Found\n\n")
		res.Write(ufmt.Sprintf("Unknown path `%s`. Return to [Overview](/r/g1v4wuqfzakzpty87t0njkcjtx8yte4v5d8v69tj/quorumcraft) or [Docs](/r/g1v4wuqfzakzpty87t0njkcjtx8yte4v5d8v69tj/quorumcraft:docs).\n", sanitize.InlineText(req.Path)))
	})
}

// Render serves the multi-page on-chain Markdown + SVG explorer for QuorumCraft.
func Render(path string) string {
	return router.Render(strings.TrimPrefix(path, "/"))
}

func baseLink(sub string) string {
	const prefix = "/r/g1v4wuqfzakzpty87t0njkcjtx8yte4v5d8v69tj/quorumcraft"
	if sub == "" {
		return prefix
	}
	return prefix + ":" + sub
}

func renderHome(res *mux.ResponseWriter, _ *mux.Request) {
	stats := GetProtocolStats()
	realmAddr := chain.PackageAddress(realmPkgPath)
	vaultBal := banker.NewReadonlyBanker().GetCoin(realmAddr, ugnotDenom)

	var sb strings.Builder
	sb.WriteString("# QuorumCraft — Pairwise Quadratic Funding & Milestone Escrow\n\n")
	sb.WriteString(ufmt.Sprintf("[Overview](%s) | [Architecture & CLI Docs](%s)\n\n", baseLink(""), baseLink("docs")))
	sb.WriteString("> Deterministic anti-collusion Quadratic Funding (`p/qfmath`) paired with quorum-attested milestone escrow in native `ugnot` on Gno.land.\n\n")

	sb.WriteString("## Protocol Treasury\n\n")
	sb.WriteString("| Metric | Value |\n")
	sb.WriteString("|---|---|\n")
	sb.WriteString(ufmt.Sprintf("| Live Vault Balance | `%s` (`%d ugnot`) |\n", formatGnot(vaultBal), vaultBal))
	sb.WriteString(ufmt.Sprintf("| Active Escrowed Ledger | `%s` (`%d ugnot`) |\n", formatGnot(stats.TotalEscrowed), stats.TotalEscrowed))
	sb.WriteString(ufmt.Sprintf("| Milestone Payouts Released | `%s` (`%d ugnot`) |\n", formatGnot(stats.TotalReleased), stats.TotalReleased))
	sb.WriteString(ufmt.Sprintf("| Disputed / Refunded | `%s` (`%d ugnot`) |\n", formatGnot(stats.TotalRefunded), stats.TotalRefunded))
	sb.WriteString(ufmt.Sprintf("| Grant Rounds (Open / Total) | `%d / %d` |\n", stats.OpenRounds, stats.RoundCount))
	sb.WriteString(ufmt.Sprintf("| Total Proposals | `%d` |\n", stats.ProposalCount))
	sb.WriteString(ufmt.Sprintf("| Realm Escrow Address | `%s` |\n\n", realmAddr.String()))

	if len(rounds) == 0 {
		sb.WriteString("## Grant Rounds\n\n")
		sb.WriteString("_No grant rounds launched yet. Use `CreateRound` to sponsor the first Pairwise-QF round._\n")
		res.Write(sb.String())
		return
	}

	// Render live on-chain SVG chart for the most recent round with proposals.
	var featured *Round
	for i := len(rounds) - 1; i >= 0; i-- {
		if len(rounds[i].Proposals) > 0 {
			featured = rounds[i]
			break
		}
	}
	if featured != nil {
		stdAlloc, pwAlloc := PreviewRoundMatching(featured.ID)
		matched := stdAlloc
		if featured.Mode == ModePairwiseQF {
			matched = pwAlloc
		}
		if featured.Status == RoundFinalized {
			matched = make([]int64, len(featured.Proposals))
			for i, p := range featured.Proposals {
				matched[i] = p.MatchedGrant
			}
		}
		sb.WriteString("## Live On-Chain QF Matching Chart\n\n")
		sb.WriteString(buildRoundChartCanvas(featured, matched).Render("QuorumCraft Direct vs Matched Grants") + "\n\n")
	}

	sb.WriteString("## Grant Rounds\n\n")
	sb.WriteString("| Round | Mode | Status | Matching Pool | Direct Donations | Proposals | Quorum |\n")
	sb.WriteString("|---|---|---|---|---|---|---|\n")
	for i := len(rounds) - 1; i >= 0; i-- {
		r := rounds[i]
		sb.WriteString(ufmt.Sprintf(
			"| [#%d %s](%s) | `%s` | `%s` | `%s` | `%s` | %d | %d.%02d%% |\n",
			r.ID,
			sanitize.TableCell(r.Name),
			baseLink("round/"+strconv.Itoa(r.ID)),
			r.Mode.String(),
			r.Status.String(),
			formatGnot(r.MatchingPool),
			formatGnot(r.DirectTotal),
			len(r.Proposals),
			r.QuorumBps/100,
			r.QuorumBps%100,
		))
	}
	res.Write(sb.String())
}

func renderRound(res *mux.ResponseWriter, req *mux.Request) {
	id, err := strconv.Atoi(req.GetVar("id"))
	if err != nil || id < 1 || id > len(rounds) {
		res.Write("# Round Not Found\n\nReturn to [Overview](" + baseLink("") + ").\n")
		return
	}
	r := rounds[id-1]

	stdAlloc, pwAlloc := PreviewRoundMatching(r.ID)
	activeAlloc := stdAlloc
	if r.Mode == ModePairwiseQF {
		activeAlloc = pwAlloc
	}
	if r.Status == RoundFinalized {
		stdAlloc = make([]int64, len(r.Proposals))
		activeAlloc = make([]int64, len(r.Proposals))
		for i, p := range r.Proposals {
			stdAlloc[i] = p.StandardQFMatched
			activeAlloc[i] = p.MatchedGrant
		}
		if r.Mode == ModePairwiseQF {
			pwAlloc = activeAlloc
		}
	}

	_, donorWeights := buildContributionMatrix(r)
	nakamoto := qfmath.NakamotoCoeff(donorWeights)
	hhiBps := qfmath.ConcentrationBps(donorWeights)
	topBps := qfmath.TopShareBps(donorWeights)
	deltas := qfmath.CollusionDelta(stdAlloc, pwAlloc)

	var sb strings.Builder
	sb.WriteString(ufmt.Sprintf("# Round #%d — %s\n\n", r.ID, sanitize.InlineText(r.Name)))
	sb.WriteString(ufmt.Sprintf("[← Overview](%s) | [Docs](%s)\n\n", baseLink(""), baseLink("docs")))
	if r.Description != "" {
		sb.WriteString(sanitize.Block(r.Description))
	}

	sb.WriteString("## Round Parameters & Decentralization Telemetry\n\n")
	sb.WriteString("| Parameter | Value |\n")
	sb.WriteString("|---|---|\n")
	sb.WriteString(ufmt.Sprintf("| Status | `%s` |\n", r.Status.String()))
	sb.WriteString(ufmt.Sprintf("| Matching Mechanism | `%s` (Penalty M = `%s`) |\n", r.Mode.String(), formatGnot(r.PenaltyCoeff)))
	sb.WriteString(ufmt.Sprintf("| Sponsor | `%s` |\n", r.Sponsor.String()))
	sb.WriteString(ufmt.Sprintf("| Matching Pool | `%s` (`%d ugnot`) |\n", formatGnot(r.MatchingPool), r.MatchingPool))
	sb.WriteString(ufmt.Sprintf("| Direct Donations | `%s` (`%d ugnot`) |\n", formatGnot(r.DirectTotal), r.DirectTotal))
	sb.WriteString(ufmt.Sprintf("| Unique Donors | `%d` |\n", r.Donors.Size()))
	sb.WriteString(ufmt.Sprintf("| Nakamoto Coefficient | `%d` |\n", nakamoto))
	sb.WriteString(ufmt.Sprintf("| Donor HHI Concentration | `%d bps` (%d.%02d%%) |\n", hhiBps, hhiBps/100, hhiBps%100))
	sb.WriteString(ufmt.Sprintf("| Top-1 Donor Share | `%d bps` (%d.%02d%%) |\n", topBps, topBps/100, topBps%100))
	sb.WriteString(ufmt.Sprintf("| Milestone Quorum | `%d.%02d%%` |\n\n", r.QuorumBps/100, r.QuorumBps%100))

	sb.WriteString("## Direct vs Matched Distribution (On-Chain SVG)\n\n")
	sb.WriteString(buildRoundChartCanvas(r, activeAlloc).Render("Round Matching Chart") + "\n\n")

	sb.WriteString("## Proposals — Pairwise-QF vs Standard-QF Comparison\n\n")
	if len(r.Proposals) == 0 {
		sb.WriteString("_No proposals submitted yet._\n\n")
	} else {
		sb.WriteString("| Proposal | Donors | Direct | Standard QF | Pairwise QF | Anti-Collusion Delta | Total Escrow |\n")
		sb.WriteString("|---|---|---|---|---|---|---|\n")
		for i, p := range r.Proposals {
			propLink := baseLink(ufmt.Sprintf("proposal/%d/%d", r.ID, p.ID))
			deltaSign := ""
			if deltas[i] > 0 {
				deltaSign = "+"
			}
			sb.WriteString(ufmt.Sprintf(
				"| [#%d %s](%s) | %d | `%s` | `%s` | `%s` | `%s%s` | `%s` |\n",
				p.ID,
				sanitize.TableCell(p.Title),
				propLink,
				p.DonorContribs.Size(),
				formatGnot(p.DirectTotal),
				formatGnot(stdAlloc[i]),
				formatGnot(pwAlloc[i]),
				deltaSign,
				formatGnot(deltas[i]),
				formatGnot(p.DirectTotal+activeAlloc[i]),
			))
		}
		sb.WriteString("\n")
	}

	sb.WriteString("## CLI Actions\n\n```bash\n")
	sb.WriteString(ufmt.Sprintf("# Fund matching pool (+5 GNOT)\ngnokey maketx call -pkgpath %s -func FundMatchingPool -args %d -send 5000000ugnot -gas-fee 1000000ugnot -gas-wanted 5000000 -broadcast -chainid onyx-1 -remote https://rpc.onyx.testnets.gno.land:443 <key>\n\n", realmPkgPath, r.ID))
	sb.WriteString(ufmt.Sprintf("# Finalize round\ngnokey maketx call -pkgpath %s -func FinalizeRound -args %d -gas-fee 1000000ugnot -gas-wanted 5000000 -broadcast -chainid onyx-1 -remote https://rpc.onyx.testnets.gno.land:443 <key>\n", realmPkgPath, r.ID))
	sb.WriteString("```\n")
	res.Write(sb.String())
}

func renderProposal(res *mux.ResponseWriter, req *mux.Request) {
	rID, err1 := strconv.Atoi(req.GetVar("roundId"))
	pID, err2 := strconv.Atoi(req.GetVar("propId"))
	if err1 != nil || err2 != nil || rID < 1 || rID > len(rounds) {
		res.Write("# Proposal Not Found\n\nReturn to [Overview](" + baseLink("") + ").\n")
		return
	}
	r := rounds[rID-1]
	if pID < 1 || pID > len(r.Proposals) {
		res.Write("# Proposal Not Found\n\nReturn to [Round #" + strconv.Itoa(rID) + "](" + baseLink("round/"+strconv.Itoa(rID)) + ").\n")
		return
	}
	p := r.Proposals[pID-1]
	reqQuorum := RequiredQuorum(r, p)

	var sb strings.Builder
	sb.WriteString(ufmt.Sprintf("# Proposal #%d.%d — %s\n\n", r.ID, p.ID, sanitize.InlineText(p.Title)))
	sb.WriteString(ufmt.Sprintf("[← Round #%d](%s) | [Overview](%s) | [Docs](%s)\n\n", r.ID, baseLink("round/"+strconv.Itoa(r.ID)), baseLink(""), baseLink("docs")))

	sb.WriteString(sanitize.Block(p.Summary))

	sb.WriteString("## Escrow Summary\n\n")
	sb.WriteString("| Field | Value |\n")
	sb.WriteString("|---|---|\n")
	sb.WriteString(ufmt.Sprintf("| Recipient | `%s` |\n", p.Recipient.String()))
	if safeURL := sanitize.URL(p.RepoURL); safeURL != "" {
		sb.WriteString(ufmt.Sprintf("| Repository | [%s](%s) |\n", sanitize.TableCell(p.RepoURL), safeURL))
	}
	sb.WriteString(ufmt.Sprintf("| Direct Contributions | `%s` (`%d` donors) |\n", formatGnot(p.DirectTotal), p.DonorContribs.Size()))
	sb.WriteString(ufmt.Sprintf("| Matched Grant (%s) | `%s` |\n", r.Mode.String(), formatGnot(p.MatchedGrant)))
	sb.WriteString(ufmt.Sprintf("| Total Funded Escrow | `%s` |\n", formatGnot(p.TotalGrant())))
	sb.WriteString(ufmt.Sprintf("| Released to Builder | `%s` |\n", formatGnot(p.EscrowReleased)))
	sb.WriteString(ufmt.Sprintf("| Refunded (Disputes) | `%s` |\n", formatGnot(p.EscrowRefunded)))
	sb.WriteString(ufmt.Sprintf("| Remaining Locked | `%s` |\n", formatGnot(p.RemainingEscrow())))
	sb.WriteString(ufmt.Sprintf("| Attestation Quorum | `%d` of `%d` eligible attestors |\n\n", reqQuorum, EligibleAttestorCount(r, p)))

	sb.WriteString("## Milestone Escrow Progress (On-Chain SVG)\n\n")
	sb.WriteString(buildEscrowBarCanvas(r, p).Render("Milestone Escrow Progress") + "\n\n")

	sb.WriteString("## Milestone Tranches\n\n")
	sb.WriteString("| # | Milestone | Weight | Tranche | Status | Quorum | Proof / Commit |\n")
	sb.WriteString("|---|---|---|---|---|---|---|\n")
	for i, m := range p.Milestones {
		tranche := ProposalTrancheAmount(p, i)
		proofCell := "_pending_"
		if m.ProofURI != "" {
			if safeProof := sanitize.URL(m.ProofURI); safeProof != "" {
				proofCell = ufmt.Sprintf("[proof](%s) (`%s`)", safeProof, sanitize.TableCell(m.CommitHash))
			} else {
				proofCell = ufmt.Sprintf("`%s` (`%s`)", sanitize.TableCell(m.ProofURI), sanitize.TableCell(m.CommitHash))
			}
		}
		if m.Status == MilestoneDisputed {
			proofCell = ufmt.Sprintf("DISPUTED: %s", sanitize.TableCell(m.DisputeReason))
		}
		sb.WriteString(ufmt.Sprintf(
			"| M%d | %s | %d.%02d%% | `%s` | `%s` | `%d/%d` | %s |\n",
			i+1,
			sanitize.TableCell(m.Title),
			m.Bps/100,
			m.Bps%100,
			formatGnot(tranche),
			m.Status.String(),
			m.ApprovalCount,
			reqQuorum,
			proofCell,
		))
	}
	sb.WriteString("\n")

	sb.WriteString("## `gnokey` Commands\n\n```bash\n")
	sb.WriteString(ufmt.Sprintf("# Contribute 1 GNOT to this proposal\ngnokey maketx call -pkgpath %s -func Contribute -args %d -args %d -send 1000000ugnot -gas-fee 1000000ugnot -gas-wanted 5000000 -broadcast -chainid onyx-1 -remote https://rpc.onyx.testnets.gno.land:443 <key>\n\n", realmPkgPath, r.ID, p.ID))
	sb.WriteString(ufmt.Sprintf("# Submit proof for Milestone 0\ngnokey maketx call -pkgpath %s -func SubmitMilestoneProof -args %d -args %d -args 0 -args \"https://github.com/org/repo/releases/tag/v1\" -args \"sha256:abc123\" -gas-fee 1000000ugnot -gas-wanted 5000000 -broadcast -chainid onyx-1 -remote https://rpc.onyx.testnets.gno.land:443 <builder-key>\n\n", realmPkgPath, r.ID, p.ID))
	sb.WriteString(ufmt.Sprintf("# Attest Milestone 0\ngnokey maketx call -pkgpath %s -func AttestMilestone -args %d -args %d -args 0 -gas-fee 1000000ugnot -gas-wanted 5000000 -broadcast -chainid onyx-1 -remote https://rpc.onyx.testnets.gno.land:443 <reviewer-key>\n\n", realmPkgPath, r.ID, p.ID))
	sb.WriteString(ufmt.Sprintf("# Release Milestone 0 escrow once quorum met\ngnokey maketx call -pkgpath %s -func ReleaseMilestone -args %d -args %d -args 0 -gas-fee 1000000ugnot -gas-wanted 5000000 -broadcast -chainid onyx-1 -remote https://rpc.onyx.testnets.gno.land:443 <any-key>\n", realmPkgPath, r.ID, p.ID))
	sb.WriteString("```\n")
	res.Write(sb.String())
}

func renderDocs(res *mux.ResponseWriter, _ *mux.Request) {
	var sb strings.Builder
	sb.WriteString("# QuorumCraft Architecture & CLI Guide\n\n")
	sb.WriteString(ufmt.Sprintf("[← Overview](%s)\n\n", baseLink("")))
	sb.WriteString("## 1. Pairwise-Bounded Anti-Collusion Quadratic Funding (`p/qfmath`)\n\n")
	sb.WriteString("Classic Quadratic Funding amplifies broad community consensus via `score_p = (sum_d sqrt(c_{p,d}))^2 - sum_d c_{p,d}`, but remains vulnerable to coordinated sybil rings that split one whale across multiple wallets.\n\n")
	sb.WriteString("QuorumCraft implements Vitalik Buterin's **Pairwise Coordination Subsidy** strictly in 128-bit integer arithmetic (zero floating-point, zero rounding dust):\n\n")
	sb.WriteString("- Pairwise overlap across all projects: `O_{i,j} = sum_q sqrt(c_{q,i} * c_{q,j})`\n")
	sb.WriteString("- Anti-collusion damping factor: `k_{i,j} = M / (M + O_{i,j})`\n")
	sb.WriteString("- Weighted project score: `score_p = sum_{i < j} k_{i,j} * sqrt(c_{p,i} * c_{p,j})`\n")
	sb.WriteString("- Largest-Remainder (Hamilton) dust apportionment guarantees `sum(alloc) == matchingPool`.\n\n")
	sb.WriteString("## 2. Milestone-Gated Escrow Lifecycle\n\n")
	sb.WriteString("1. `CreateRound` / `FundMatchingPool`: Sponsor locks real `ugnot` in the realm vault.\n")
	sb.WriteString("2. `SubmitProposal`: Builder defines 2–4 milestones (`Title:Bps|...`, summing to `10000` bps).\n")
	sb.WriteString("3. `Contribute`: Community members donate real `ugnot`; per-donor donations aggregate automatically.\n")
	sb.WriteString("4. `FinalizeRound`: Deterministic `PairwiseQF` locks matched grants into each proposal's escrow.\n")
	sb.WriteString("5. `SubmitMilestoneProof` → `AttestMilestone` → `ReleaseMilestone`: Tranches release atomically via `banker.SendCoins` once attestations meet quorum.\n")
	sb.WriteString("6. `DisputeMilestone` → `ResolveDispute`: Faulty deliverables can be halted and slashed back to sponsor.\n")
	res.Write(sb.String())
}
