package tributary

import (
	"chain/banker"
	"strings"

	"gno.land/p/nt/ufmt/v0"
)

const realmPath = "/r/g196fz02krdlf6fc7a7p2w8e4rkywepwn5c9nh63/tributary"

// Render serves a multi-page interactive gnoweb dashboard straight from chain state:
//   - ""               -> Global protocol overview, live TVL, registered nodes, recent waterfalls
//   - "node/<id>"      -> Live on-chain SVG DAG diagram, effective end-to-end shares, gnokey commands
//   - "addr/<g1...>"   -> Maintainer claimable & lifetime earnings across all DAGs
func Render(path string) string {
	clean := strings.Trim(strings.TrimSpace(path), "/")
	if strings.HasPrefix(clean, "node/") {
		return renderNode(strings.TrimPrefix(clean, "node/"))
	}
	if strings.HasPrefix(clean, "addr/") {
		return renderAddress(strings.TrimPrefix(clean, "addr/"))
	}
	return renderHome()
}

func renderHome() string {
	var sb strings.Builder
	sb.WriteString("# Tributary — Recursive Open-Source Dependency-DAG Revenue Waterfalls\n\n")
	sb.WriteString("> *Drop 1 `ugnot` into a downstream realm. Watch it cascade deterministically across every upstream open-source package (`A -> B, C -> D`) in one atomic transaction — cycle-proof, zero-dust, and rendered live on-chain.*\n\n")

	// Live protocol stats
	ro := banker.NewReadonlyBanker()
	sb.WriteString("## Live On-Chain Telemetry\n\n")
	sb.WriteString("| Metric | Value |\n|---|---|\n")
	sb.WriteString(ufmt.Sprintf("| Registered Nodes | **%d** (%d cryptographically locked) |\n", engine.NodeCount(), engine.LockedCount()))
	sb.WriteString(ufmt.Sprintf("| Total Volume Routed | **%s** (`%d ugnot`) |\n", formatGNOT(engine.TotalRouted()), engine.TotalRouted()))
	sb.WriteString(ufmt.Sprintf("| Total Claimed by Maintainers | **%s** (`%d ugnot`) |\n", formatGNOT(engine.TotalClaimed()), engine.TotalClaimed()))
	sb.WriteString(ufmt.Sprintf("| Live Pending Escrow | **%s** (`%d ugnot`) |\n", formatGNOT(engine.EscrowedTotal()), engine.EscrowedTotal()))
	sb.WriteString(ufmt.Sprintf("| Total `ugnot` Supply Read (Readonly Banker) | `%d` |\n\n", ro.TotalCoin(denom)))

	nodes := engine.ListNodes()
	// Show featured SVG diagram of the richest multi-hop DAG right on the homepage!
	var featuredID string
	bestScore := -1
	for _, n := range nodes {
		score := len(n.Edges)*1000 + int(n.TotalInflow/1000)
		if len(n.Edges) > 0 && score > bestScore {
			bestScore = score
			featuredID = n.ID
		}
	}
	if featuredID != "" {
		sb.WriteString("## Featured Live Dependency Waterfall\n\n")
		sb.WriteString(engine.RenderGraphSVG(featuredID))
		sb.WriteString(ufmt.Sprintf("\n\nInspect full breakdown: [View `%s` DAG](%s:node/%s)\n\n", featuredID, realmPath, featuredID))
	}

	sb.WriteString("## Registered Nodes\n\n")
	if len(nodes) == 0 {
		sb.WriteString("_No nodes registered yet. Call `Register(id, title, pkgRef, beneficiary)` to launch the first waterfall._\n\n")
	} else {
		sb.WriteString("| Node | Package Ref | Status | Keep / Forward | Total Inflow | Total Retained |\n")
		sb.WriteString("|---|---|---|---|---|---|\n")
		for _, n := range nodes {
			status := "Editable"
			if n.Locked {
				status = "LOCKED"
			}
			pkg := n.PkgRef
			if pkg == "" {
				pkg = "-"
			}
			sb.WriteString(ufmt.Sprintf("| [%s](%s:node/%s) (`%s`) | `%s` | %s | %s / %s | %s | %s |\n",
				n.Title, realmPath, n.ID, n.ID, pkg, status,
				fmtBPS(n.RetainedBPS()), fmtBPS(n.ForwardedBPS()),
				formatGNOT(n.TotalInflow), formatGNOT(n.TotalRetained),
			))
		}
		sb.WriteString("\n")
	}

	receipts := engine.RecentReceipts()
	sb.WriteString("## Recent Waterfall Deposits\n\n")
	if len(receipts) == 0 {
		sb.WriteString("_No deposits routed yet._\n\n")
	} else {
		sb.WriteString("| # | Entry Node | Amount | Hops | Beneficiaries Credited | Block | Memo |\n")
		sb.WriteString("|---|---|---|---|---|---|---|\n")
		for _, r := range receipts {
			memo := r.Memo
			if memo == "" {
				memo = "-"
			}
			sb.WriteString(ufmt.Sprintf("| #%d | [%s](%s:node/%s) | **%s** | %d | %d | %d | %s |\n",
				r.Seq, r.EntryID, realmPath, r.EntryID, formatGNOT(r.Amount), r.Hops, r.Credits, r.Height, memo,
			))
		}
		sb.WriteString("\n")
	}

	sb.WriteString("## Composable Package (`p/tributary`)\n\n")
	sb.WriteString("Any Gno realm can import `gno.land/p/g196fz02krdlf6fc7a7p2w8e4rkywepwn5c9nh63/tributary` directly or stream revenue cross-realm via `DepositWithBanker`.\n")
	return sb.String()
}

func renderNode(id string) string {
	n := engine.GetNode(id)
	if n == nil {
		return ufmt.Sprintf("# Node `%s` Not Found\n\n[Back to Tributary Dashboard](%s)\n", id, realmPath)
	}

	var sb strings.Builder
	sb.WriteString(ufmt.Sprintf("# %s (`%s`)\n\n", n.Title, n.ID))
	sb.WriteString(ufmt.Sprintf("[Back to Dashboard](%s)\n\n", realmPath))

	sb.WriteString(engine.RenderGraphSVG(n.ID))
	sb.WriteString("\n\n")

	status := "Editable by Owner"
	if n.Locked {
		status = "PERMANENTLY LOCKED (Immutable Splits)"
	}

	sb.WriteString("## Node Metadata\n\n")
	sb.WriteString("| Field | Value |\n|---|---|\n")
	sb.WriteString(ufmt.Sprintf("| Package Reference | `%s` |\n", n.PkgRef))
	sb.WriteString(ufmt.Sprintf("| Status | **%s** |\n", status))
	sb.WriteString(ufmt.Sprintf("| Owner | `%s` |\n", n.Owner.String()))
	sb.WriteString(ufmt.Sprintf("| Beneficiary | [`%s`](%s:addr/%s) |\n", n.Beneficiary.String(), realmPath, n.Beneficiary.String()))
	sb.WriteString(ufmt.Sprintf("| Direct Split | Keep **%s** / Forward **%s** |\n", fmtBPS(n.RetainedBPS()), fmtBPS(n.ForwardedBPS())))
	sb.WriteString(ufmt.Sprintf("| Total Inflow | **%s** (`%d ugnot`) |\n", formatGNOT(n.TotalInflow), n.TotalInflow))
	sb.WriteString(ufmt.Sprintf("| Total Retained | **%s** (`%d ugnot`) |\n", formatGNOT(n.TotalRetained), n.TotalRetained))
	sb.WriteString(ufmt.Sprintf("| Total Forwarded | **%s** (`%d ugnot`) |\n\n", formatGNOT(n.TotalForwarded), n.TotalForwarded))

	sb.WriteString("## Direct Upstream Splits\n\n")
	if len(n.Edges) == 0 {
		sb.WriteString("_Leaf node: 100.00% of inflows are retained directly by its beneficiary._\n\n")
	} else {
		sb.WriteString("| Upstream Target | Share (BPS) | Share (%) | Dependency Role |\n|---|---|---|---|\n")
		for _, ed := range n.Edges {
			lbl := ed.Label
			if lbl == "" {
				lbl = "dependency"
			}
			sb.WriteString(ufmt.Sprintf("| [`%s`](%s:node/%s) | `%d` | **%s** | %s |\n",
				ed.TargetID, realmPath, ed.TargetID, ed.BPS, fmtBPS(ed.BPS), lbl,
			))
		}
		sb.WriteString("\n")
	}

	sb.WriteString("## Effective End-to-End Distribution (Per 100% Deposited Here)\n\n")
	sb.WriteString("| Node | Beneficiary | Effective Share |\n|---|---|---|\n")
	for _, s := range engine.EffectiveShares(n.ID) {
		sb.WriteString(ufmt.Sprintf("| [`%s`](%s:node/%s) | [`%s`](%s:addr/%s) | **%s** (`%d bps`) |\n",
			s.Title, realmPath, s.NodeID,
			s.Beneficiary.String(), realmPath, s.Beneficiary.String(),
			fmtBPS(s.EffectiveBPS), s.EffectiveBPS,
		))
	}
	sb.WriteString("\n")

	sb.WriteString("## Fund This Dependency Graph (`gnokey`)\n\n")
	sb.WriteString("```bash\n")
	sb.WriteString(ufmt.Sprintf("gnokey maketx call -pkgpath gno.land%s -func Deposit -args %s -args \"support\" -send 100000ugnot -gas-fee 100000ugnot -gas-wanted 5000000 -chainid onyx-1 -remote https://rpc.onyx.testnets.gno.land:443 -broadcast <your-key>\n", realmPath, n.ID))
	sb.WriteString("```\n")
	return sb.String()
}

func renderAddress(raw string) string {
	addr := address(strings.TrimSpace(raw))
	var sb strings.Builder
	sb.WriteString(ufmt.Sprintf("# Maintainer Ledger: `%s`\n\n", addr.String()))
	sb.WriteString(ufmt.Sprintf("[Back to Dashboard](%s)\n\n", realmPath))

	pending := engine.PendingOf(addr)
	claimed := engine.ClaimedOf(addr)

	sb.WriteString("| Metric | Amount |\n|---|---|\n")
	sb.WriteString(ufmt.Sprintf("| Claimable Balance | **%s** (`%d ugnot`) |\n", formatGNOT(pending), pending))
	sb.WriteString(ufmt.Sprintf("| Lifetime Claimed | **%s** (`%d ugnot`) |\n", formatGNOT(claimed), claimed))
	sb.WriteString(ufmt.Sprintf("| Lifetime Earned | **%s** (`%d ugnot`) |\n\n", formatGNOT(pending+claimed), pending+claimed))

	sb.WriteString("## Claim via `gnokey`\n\n")
	sb.WriteString("```bash\n")
	sb.WriteString(ufmt.Sprintf("gnokey maketx call -pkgpath gno.land%s -func Claim -gas-fee 100000ugnot -gas-wanted 3000000 -chainid onyx-1 -remote https://rpc.onyx.testnets.gno.land:443 -broadcast <your-key>\n", realmPath))
	sb.WriteString("```\n")
	return sb.String()
}

func formatGNOT(ugnot int64) string {
	whole := ugnot / 1000000
	frac := ugnot % 1000000
	if frac < 0 {
		frac = -frac
	}
	if frac == 0 {
		return ufmt.Sprintf("%d GNOT", whole)
	}
	// Format 4 decimal digits cleanly
	frac4 := frac / 100
	pad := ""
	if frac4 < 10 {
		pad = "000"
	} else if frac4 < 100 {
		pad = "00"
	} else if frac4 < 1000 {
		pad = "0"
	}
	return ufmt.Sprintf("%d.%s%d GNOT", whole, pad, frac4)
}

func fmtBPS(bps int64) string {
	whole := bps / 100
	frac := bps % 100
	if frac == 0 {
		return ufmt.Sprintf("%d%%", whole)
	}
	if frac < 10 {
		return ufmt.Sprintf("%d.0%d%%", whole, frac)
	}
	return ufmt.Sprintf("%d.%d%%", whole, frac)
}
