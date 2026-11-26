package kylix

import (
	"chain/runtime"
	"net/url"
	"strconv"
	"strings"

	"gno.land/p/nt/markdown/sanitize/v0"
	"gno.land/p/nym-kylix000/ring/v0"
	"gno.land/r/nt/grc20reg/v0"
	"gno.land/r/sys/users"
)

// renderOffer renders one open offer: details, live deliverability check,
// exact approve step, rings that would close with it, and cancel/settle actions.
func renderOffer(id uint64) string {
	o := loadOffer(id)
	if o == nil {
		return "# Offer " + u64(id) + "\n\n" + navBar("") +
			"\n\nThis offer is not open: it was settled, cancelled or pruned, or never existed.\n\n[Back to Kylix](" + webPath() + ")\n"
	}

	cache := map[string]string{}
	h := runtime.ChainHeight()
	slot := SlotAddress(o.Owner, o.Nonce)
	target := ApproveTarget(o.Owner, o.Nonce, o.Give.Key)

	isExp := expired(o, h)
	why := ""
	if !isExp {
		why = undeliverable(o)
	}

	var sb strings.Builder
	sb.WriteString("# Offer " + u64(o.ID) + "\n\n")
	sb.WriteString(navBar("") + "\n\n")

	// Status banner.
	switch {
	case isExp:
		sb.WriteString("> [!WARNING] Expired\n> This offer expired at block height " + strconv.FormatInt(o.Expiry, 10) +
			" (current height " + strconv.FormatInt(h, 10) + "). It can no longer swap, and anyone can remove it from the book; whoever does gets its storage deposit back.\n\n")
	case why != "":
		sb.WriteString("> [!WARNING] Needs action before it can swap\n> " + sanitize.InlineText(plainSwapReason(why)) + "\n\n")
	default:
		sb.WriteString("> [!SUCCESS] Ready to swap\n> The owner holds the offered asset")
		if o.Give.Kind == ring.Fungible {
			sb.WriteString(" and has approved the offer's swap address.")
		} else if c := getCollection(o.Give.Key); c != nil && c.approved != nil {
			sb.WriteString(" and has approved the offer's swap address.")
		} else {
			sb.WriteString(". This collection has no read-only approval check, so approval is verified at settlement.")
		}
		sb.WriteString("\n\n")
	}

	// Offer summary.
	sb.WriteString("## Details\n\n")
	sb.WriteString("- **Owner:** " + ownerFullMarkdown(o.Owner, cache) + "\n")
	sb.WriteString("- **Gives:** " + keyedAsset(o.Give, false) + assetNote(o.Give) + "\n")
	sb.WriteString("- **Wants:** " + keyedAsset(o.Want, true) + assetNote(o.Want) + "\n")
	sb.WriteString("- **Expires:** " + expiryLong(o, h) + "\n")
	sb.WriteString("- **Address to approve:** `" + target.String() + "`\n")
	if target != slot {
		sb.WriteString("- **Offer's own address:** `" + slot.String() + "` (offer number " + u64(o.Nonce) +
			" of this owner; this collection trades through an adapter, so approve the address above, not this one)\n")
	}
	if o.ViaSession {
		sb.WriteString("- **Session key:** posted with a session key (cancelling still requires the account key)\n")
	}

	// Approve step.
	sb.WriteString("\n## Approve step for this offer\n\n")
	writeApproveInstructions(&sb, o.Give, target, slot)

	// Matching rings.
	sb.WriteString("\n## Rings that close with this offer\n\n")
	if isExp {
		sb.WriteString("Expired offers cannot settle.\n")
	} else {
		rings := findRingsForOffer(o)
		if len(rings) == 0 {
			sb.WriteString("No 2- or 3-offer direct ring closes with this offer among the newest " + strconv.Itoa(matchScanLimit) +
				" offers right now. Longer rings (up to 6 offers) and rings that need a GnoSwap swap are found by programs that search off chain.\n")
		} else {
			for _, r := range rings {
				ids := offerIDList(r)
				sb.WriteString("- **" + strconv.Itoa(len(r)) + "-offer ring** (`" + ids + "`): ")
				for i, ro := range r {
					if i > 0 {
						sb.WriteString(" → ")
					}
					sb.WriteString(ownerMarkdown(ro.Owner, cache) + " gives " + sanitize.InlineText(shortAsset(ro.Give)))
				}
				sb.WriteString("\n  " + gnoButton(webPath()+":ring/"+ids, "Review and settle", "success") + "\n")
			}
		}
	}

	// Actions.
	sb.WriteString("\n## Actions\n\n")
	sb.WriteString(gnoButton(txLink(webPath(), "CancelIntent", "id", u64(o.ID)), "Cancel offer (owner only)", "caution outline"))
	if isExp {
		sb.WriteString(" " + gnoButton(txLink(webPath(), "PruneIntent", "id", u64(o.ID)), "Remove expired offer", "warning outline"))
	}
	sb.WriteString("\n\nCancelling withdraws your offer and returns its storage deposit to you. It calls no other realm, so nothing can block it. ")
	sb.WriteString("Once an offer has expired, anyone can remove it and collect its deposit; that also calls no other realm.\n\n")

	sb.WriteString("<gno-form exec=\"CancelIntent\">\n")
	sb.WriteString(gnoInput("id", "Offer ID", u64(o.ID), true, true))
	sb.WriteString("</gno-form>\n")

	return sb.String()
}

func writeApproveInstructions(sb *strings.Builder, give ring.Asset, target, slot address) {
	demo := demoRealmPath()
	switch give.Kind {
	case ring.Fungible:
		sym := shortTokenSymbol(give.Key)
		tRealm := tokenRealmPath(give.Key)
		sb.WriteString("Allow `" + target.String() + "` to move **exactly " + strconv.FormatInt(give.Amount, 10) + " " +
			sanitize.InlineText(sym) + "** (token " + sanitize.InlineCode(give.Key) + ") from your wallet: not more, or the offer will not settle. Only this offer can spend that allowance.\n\n")
		if demo != "" && tRealm == demo && (sym == "OBOL" || sym == "DRACHMA") {
			sb.WriteString(gnoButton(
				txLink(demoWebPath(), "Approve", "symbol", sym, "spender", target.String(), "amount", strconv.FormatInt(give.Amount, 10)),
				"Approve "+strconv.FormatInt(give.Amount, 10)+" "+sym+" (demo)",
				"info",
			) + "\n")
		} else if tRealm != "" {
			sb.WriteString(gnoButton(pkgWebPath(tRealm)+"$help", "Open token realm ($help)", "info") +
				" — call `Approve` with spender `" + target.String() + "` and amount exactly `" + strconv.FormatInt(give.Amount, 10) + "`.\n")
		}
	case ring.Item:
		c := getCollection(give.Key)
		if c != nil && c.target != "" {
			sb.WriteString("This collection trades through an adapter (" + sanitize.InlineCode(give.Key) + "). ")
			sb.WriteString("Approve the adapter's address for this offer, `" + target.String() + "` (not the offer's own address `" + slot.String() +
				"`) for item " + sanitize.InlineCode(give.ID) + " in " + sanitize.InlineCode(c.target) + ".\n\n")
			sb.WriteString(gnoButton(pkgWebPath(c.target)+"$help", "Open target collection ($help)", "info") + "\n")
		} else {
			sb.WriteString("Approve `" + target.String() + "` for item " + sanitize.InlineCode(give.ID) + " in " +
				sanitize.InlineCode(give.Key) + ".\n\n")
			if demo != "" && give.Key == demo {
				sb.WriteString(gnoButton(
					txLink(demoWebPath(), "ApproveRelic", "spender", target.String(), "id", give.ID),
					"Approve Relic "+give.ID+" (demo)",
					"info",
				) + "\n")
			} else {
				sb.WriteString(gnoButton(pkgWebPath(give.Key)+"$help", "Open collection realm ($help)", "info") + "\n")
			}
		}
	}
}

// renderRing renders a ring page ("ring/1,2,3"): large SVG graph, each swap in
// plain English, live readiness check per swap, and settle links/form.
func renderRing(rawIDs string) string {
	idList, err := ring.ParseOfferIDs(rawIDs)
	if err != nil {
		return "# Ring\n\n" + navBar("") + "\n\nInvalid offer list: " +
			sanitize.InlineText(plainSwapReason(err.Error())) + "\n\n[Back to Kylix](" + webPath() + ")\n"
	}

	cache := map[string]string{}
	height := runtime.ChainHeight()
	n := len(idList)
	offs := make([]*Offer, n)
	legs := make([]ring.Leg, n)
	var problems []string

	for i, id := range idList {
		o := loadOffer(id)
		if o == nil {
			problems = append(problems, "Offer #"+u64(id)+" is not open (already settled, cancelled, pruned, or unknown).")
			continue
		}
		if expired(o, height) {
			problems = append(problems, "Offer #"+u64(id)+" expired at height "+strconv.FormatInt(o.Expiry, 10)+".")
		}
		offs[i] = o
		legs[i] = ring.Leg{Offer: o.ID, Owner: o.Owner, Give: o.Give, Want: o.Want}
	}

	canonicalIDs := ring.FormatOfferIDs(idList)
	var sb strings.Builder
	sb.WriteString("# Ring: " + canonicalIDs + "\n\n")
	sb.WriteString(navBar("") + "\n\n")

	if len(problems) > 0 {
		sb.WriteString("> [!WARNING] Cannot settle this ring\n")
		for _, p := range problems {
			sb.WriteString("> - " + sanitize.InlineText(p) + "\n")
		}
		sb.WriteString("\n[Back to Kylix](" + webPath() + ")\n")
		return sb.String()
	}

	hops, err := ring.VerifyWithBridge(legs)
	if err != nil {
		sb.WriteString("> [!WARNING] Not a valid ring\n> " + sanitize.InlineText(plainSwapReason(err.Error())) + "\n\n")
		sb.WriteString("[Back to Kylix](" + webPath() + ")\n")
		return sb.String()
	}

	// Live readiness check (same checks SettleRing runs before moving anything).
	reasons := make([]string, len(idList))
	var bridgeFeeTier uint32
	bridgeHasPool := true
	allReady := true
	hasBridge := false

	for i, o := range offs {
		reasons[i] = undeliverable(o)
		if reasons[i] != "" {
			allReady = false
		}
		if hops[i].Bridged {
			hasBridge = true
			fee, ok := bridgeFee(hops[i].Asset.Key, hops[i].Want.Key)
			bridgeFeeTier, bridgeHasPool = fee, ok
			if !ok {
				allReady = false
			}
		}
	}

	// Large ring graph.
	graphHops := make([]ring.GraphHop, n)
	for i, h := range hops {
		gh := ring.GraphHop{
			From:    ownerPlain(offs[i].Owner, cache),
			Give:    graphAsset(h.Asset),
			Note:    svgHint(assetHint(h.Asset)),
			OfferID: offs[i].ID,
			Bridged: h.Bridged,
		}
		if h.Bridged {
			gh.Want = "≥ " + graphAsset(h.Want)
			gh.WantNote = svgHint(assetHint(h.Want))
		}
		graphHops[i] = gh
	}
	if uri := ring.GraphDataURI(graphHops, ring.GraphFull); uri != "" {
		sb.WriteString("![Ring " + canonicalIDs + "](" + uri + ")\n\n")
	}

	// Status banner & primary settle button.
	variant := "outline"
	if allReady {
		variant = "success"
		sb.WriteString("> [!SUCCESS] Ready to settle\n> Every owner holds their asset and has approved this swap")
		if hasBridge {
			sb.WriteString(", and a GnoSwap pool (" + formatFeePercent(bridgeFeeTier) + " fee tier) is available for the swap through GnoSwap")
		}
		sb.WriteString(". Anyone can settle this ring in one transaction.\n\n")
	} else {
		sb.WriteString("> [!WARNING] Not ready to settle right now\n> One or more swaps cannot deliver yet (see table below). ")
		sb.WriteString("Nothing will move until every swap is ready.\n\n")
	}
	if hasBridge && bridgeHasPool {
		// Name the pool: the automatic choice can be steered by whoever adds
		// liquidity to another pool of the same pair.
		sb.WriteString(gnoButton(txLink(webPath(), "SettleRingVia", "ids", canonicalIDs, "fee", strconv.FormatUint(uint64(bridgeFeeTier), 10)),
			"Settle through the "+formatFeePercent(bridgeFeeTier)+" pool", variant) + "\n\n")
		sb.WriteString("The " + formatFeePercent(bridgeFeeTier) + " pool is the one holding the most of the token being bought. " +
			"If GnoSwap has several pools for this pair, check which one gives the best price before settling, and pick it in the form at the bottom of this page.\n\n")
	} else {
		sb.WriteString(gnoButton(txLink(webPath(), "SettleRing", "ids", canonicalIDs), "Settle this ring", variant) + "\n\n")
	}

	// Swaps spelled out in plain words.
	sb.WriteString("## Swaps in this ring\n\n")
	for i, h := range hops {
		from := offs[h.From]
		to := offs[h.To]
		sb.WriteString(strconv.Itoa(i+1) + ". " + ownerMarkdown(from.Owner, cache) + " gives " +
			keyedAsset(h.Asset, false) + " ")
		if h.Bridged {
			sb.WriteString("→ swapped on **GnoSwap**")
			if bridgeHasPool {
				sb.WriteString(" (" + formatFeePercent(bridgeFeeTier) + " pool)")
			} else {
				sb.WriteString(" (no pool found)")
			}
			sb.WriteString(" → " + keyedAsset(h.Want, true) + " to " +
				ownerMarkdown(to.Owner, cache))
		} else {
			sb.WriteString("to " + ownerMarkdown(to.Owner, cache))
			if h.Asset.Kind == ring.Fungible && h.Asset.Amount > h.Want.Amount {
				sb.WriteString(" (asked for at least " + sanitize.InlineText(graphAsset(h.Want)) + "; keeps the full amount)")
			}
		}
		sb.WriteString(" — [offer #" + u64(from.ID) + "](" + webPath() + ":offer/" + u64(from.ID) + ")\n")
	}

	// Deliverability table.
	sb.WriteString("\n## Is every swap ready?\n\n")
	sb.WriteString("| Swap | Offer | Owner | Gives | Ready now? |\n|---|---|---|---|---|\n")
	for i, o := range offs {
		status := "Ready"
		if reasons[i] != "" {
			status = "Not ready: " + sanitize.TableCell(plainSwapReason(reasons[i]))
		} else if hops[i].Bridged && !bridgeHasPool {
			status = "No GnoSwap pool for this pair"
		}
		sb.WriteString("| " + strconv.Itoa(i+1) + " | [#" + u64(o.ID) + "](" + webPath() + ":offer/" + u64(o.ID) + ") | " +
			ownerTableCell(o.Owner, cache) + " | " + sanitize.TableCell(shortAsset(o.Give)) + " | " + status + " |\n")
	}

	// CLI fallback form.
	sb.WriteString("\n## Settle with gnokey\n\n")
	gasWanted := settleGasWanted(offs, hasBridge)
	sb.WriteString("Wallet users can click the settle button above. From the command line, set a deposit limit: settling runs each collection's code, and any storage it adds is charged to you. ")
	sb.WriteString("The gas limit below is sized to this ring (what such rings measured, with headroom) and the fee is the minimum for it at the base gas price (1 ugnot per 1,000 gas), because the whole fee is paid whatever gas is used. If the simulation runs out of gas, raise both together; nothing is charged for a failed simulation. The storage the ring frees is refunded to you.\n\n")
	fn, extra := "SettleRing", ""
	if hasBridge && bridgeHasPool {
		fn, extra = "SettleRingVia", " -args "+strconv.FormatUint(uint64(bridgeFeeTier), 10)
	}
	sb.WriteString("```\ngnokey maketx call -pkgpath " + selfPath + " -func " + fn + " -args " + canonicalIDs + extra +
		" \\\n  -gas-fee " + strconv.FormatInt(gasWanted/1000, 10) + "ugnot -gas-wanted " + strconv.FormatInt(gasWanted, 10) + " -max-deposit 500000ugnot \\\n  -broadcast -chainid " +
		runtime.ChainID() + " -remote <rpc address> <your key>\n```\n\n")
	sb.WriteString("Or submit the form below to generate a command:\n\n")
	if hasBridge {
		sb.WriteString("<gno-form exec=\"SettleRingVia\">\n")
		sb.WriteString(gnoInput("ids", "Offer IDs in ring order", canonicalIDs, true, true))
		for i, f := range feeTiers {
			desc := ""
			if i == 0 {
				desc = "GnoSwap pool to swap through (fee tier)"
			}
			sb.WriteString(gnoSelectOpt("fee", strconv.FormatUint(uint64(f), 10), desc, f == bridgeFeeTier, i == 0))
		}
		sb.WriteString("</gno-form>\n")
	} else {
		sb.WriteString("<gno-form exec=\"SettleRing\">\n")
		sb.WriteString(gnoInput("ids", "Offer IDs in ring order", canonicalIDs, true, true))
		sb.WriteString("</gno-form>\n")
	}

	return sb.String()
}

// settleGasWanted sizes a settle command's gas limit to the ring: 25M, plus
// 5M per token offer, 25M per MNS name (the adapter reads the registry), 8M
// per other item, and 150M for a GnoSwap hop. Measured on a local chain
// (gno v1.8.0): 2 token offers used 24 to 29M gas, a token and a relic 30M,
// a token and an MNS name 37M, 6 token offers 39M, 3 relics and 3 tokens
// 59M, 6 items 52 to 60M (6 Sinopia3 tokens 53M in a filetest); on the
// onyx-1 testnet a 2-offer ring with a real GnoSwap swap used 146M (the
// swap alone about 118M; a test run of GnoSwap's source had suggested 34M),
// and a token and an MNS name used 44M there, against 37M locally.
// Third-party collection code may use
// more; the simulation then fails without charging a fee. The solver is
// meant to print the same limits.
func settleGasWanted(offs []*Offer, bridged bool) int64 {
	g := int64(25_000_000)
	mns := namespacePrefix() + "adapters/nsnft"
	for _, o := range offs {
		switch {
		case o.Give.Kind != ring.Item:
			g += 5_000_000
		case o.Give.Key == mns:
			g += 25_000_000
		default:
			g += 8_000_000
		}
	}
	if bridged {
		g += 150_000_000
	}
	return g
}

// renderPost renders the offer-posting workflow:
//  1. An interactive builder (<gno-form path="post">) that computes the user's
//     exact approve address via NextSlot / ApproveTarget and produces prefilled
//     GnoConnect / $help transaction buttons for both Approve and PostIntent.
//  2. A direct <gno-form exec="PostIntent"> fallback for gnokey users.
func renderPost(rawQuery string) string {
	// Parse and strictly allowlist any query params returned by the builder form.
	q, _ := url.ParseQuery(rawQuery)
	ownerAddr, ownerErr := resolveOwnerInput(q.Get("owner"))
	giveKind := parseKindChoice(q.Get("giveKind"))
	giveKey := allowAssetKey(q.Get("giveKey"))
	giveID := cleanItemIDInput(q.Get("giveID"))
	giveAmount := parseNonNegInt64(q.Get("giveAmount"))
	wantKind := parseKindChoice(q.Get("wantKind"))
	wantKey := allowAssetKey(q.Get("wantKey"))
	tokens, colls := knownAssets(giveKey, wantKey)
	wantID := cleanItemIDInput(q.Get("wantID"))
	wantMin := parseNonNegInt64(q.Get("wantMin"))
	expiry := parseNonNegInt64(q.Get("expiry"))

	// Infer kind from chosen key when the user selected a known asset.
	if giveKey != "" {
		if IsCollection(giveKey) {
			giveKind = "item"
		} else if tokenOf(giveKey) != nil {
			giveKind = "fungible"
		}
	}
	if wantKey != "" {
		if IsCollection(wantKey) {
			wantKind = "item"
		} else if tokenOf(wantKey) != nil {
			wantKind = "fungible"
		}
	}

	var sb strings.Builder
	sb.WriteString("# Post an offer\n\n")
	sb.WriteString(navBar("post") + "\n\n")
	sb.WriteString("Kylix never holds your assets. Posting an offer takes two steps: **approve** your offer's own address, then **post** the offer. ")
	sb.WriteString("When you post, Kylix checks that a token offer, or an item of an official collection, could settle right now. It runs no third-party collection's code when you post: such an item is checked only when someone settles.\n\n")
	sb.WriteString("> [!NOTE] Your minimum is your price\n> If what you receive comes through a GnoSwap swap, expect to receive exactly the minimum you ask for, not more: " +
		"anyone can trade on the same pool around the swap and keep the difference. Set your minimum to the amount you actually want. " +
		"Your offer stays open until it settles, you cancel it, or it expires (about 7 days by default, at most about 30).\n\n")

	// If the builder form was submitted, show tailored Approve + Post transaction buttons.
	hasDraft := len(q) > 0
	if hasDraft {
		writeDraftSummary(&sb, ownerAddr, ownerErr, giveKind, giveKey, giveID, giveAmount, wantKind, wantKey, wantID, wantMin, expiry)
	}

	sb.WriteString("## Step 1: Prepare your offer (wallet & approve helper)\n\n")
	sb.WriteString("Pick what you give and what you want below. Adding your address or `@username` lets Kylix calculate the exact address to approve for your next offer.\n\n")
	sb.WriteString("<gno-form path=\"post\">\n")
	ownerVal := ""
	if ownerAddr != "" {
		ownerVal = ownerAddr.String()
	}
	sb.WriteString(gnoInput("owner", "Your g1 address or @username (optional, to compute approve address)", ownerVal, false, false))
	writeKindSelect(&sb, "giveKind", "What are you giving?", giveKind, false)
	writeAssetSelect(&sb, "giveKey", "Token or collection you give", giveKey, tokens, colls, false)
	sb.WriteString(gnoInput("giveID", "Item ID you give (leave blank for tokens)", giveID, false, false))
	sb.WriteString(gnoInput("giveAmount", "Token amount you give (0 for items)", formatIntOrEmpty(giveAmount), false, false))
	writeKindSelect(&sb, "wantKind", "What do you want back?", wantKind, false)
	writeAssetSelect(&sb, "wantKey", "Token or collection you want", wantKey, tokens, colls, false)
	sb.WriteString(gnoInput("wantID", "Item ID you want (leave blank for tokens)", wantID, false, false))
	sb.WriteString(gnoInput("wantMin", "Minimum token amount you want (0 for items)", formatIntOrEmpty(wantMin), false, false))
	sb.WriteString(gnoInput("expiry", expiryInputHint(), formatIntOrEmpty(expiry), false, false))
	sb.WriteString("</gno-form>\n\n")

	sb.WriteString("## Step 2: Approve your swap address\n\n")
	sb.WriteString("Every offer you post gets its own address, computed from your address and how many offers you have posted (`NextSlot`). ")
	sb.WriteString("Before your offer can settle, approve that address for the exact token amount or item, or, for a collection that trades through an adapter, the adapter's address for your offer (`ApproveTarget`).\n\n")
	sb.WriteString(gnoButton(txLink(webPath(), "NextSlot"), "Look up NextSlot ($help)", "outline") + " ")
	sb.WriteString(gnoButton(txLink(webPath(), "ApproveTarget"), "Look up ApproveTarget ($help)", "outline") + " ")
	sb.WriteString(gnoButton(demoWebPath(), "Need test assets? Demo faucet", "outline") + "\n\n")

	sb.WriteString("## Direct gnokey form\n\n")
	sb.WriteString("Prefer to copy a `gnokey` command directly? Fill in the fields below, or ")
	sb.WriteString(gnoButton(txLink(webPath(), "PostIntent"), "Open post call in wallet / $help", "info") + ".\n\n")

	sb.WriteString("<gno-form exec=\"PostIntent\">\n")
	writeKindSelect(&sb, "giveKind", "Give kind (fungible or item)", giveKind, true)
	writeAssetSelect(&sb, "giveKey", "Give token or collection key", giveKey, tokens, colls, true)
	sb.WriteString(gnoInput("giveID", "Give item ID (empty for tokens)", giveID, false, false))
	sb.WriteString(gnoInput("giveAmount", "Give amount (0 for items)", strconv.FormatInt(giveAmount, 10), true, false))
	writeKindSelect(&sb, "wantKind", "Want kind (fungible or item)", wantKind, true)
	writeAssetSelect(&sb, "wantKey", "Want token or collection key", wantKey, tokens, colls, true)
	sb.WriteString(gnoInput("wantID", "Want item ID (empty for tokens)", wantID, false, false))
	sb.WriteString(gnoInput("wantMin", "Minimum wanted amount (0 for items)", strconv.FormatInt(wantMin, 10), true, false))
	sb.WriteString(gnoInput("expiry", expiryInputHint(), strconv.FormatInt(expiry, 10), true, false))
	sb.WriteString("</gno-form>\n")

	return sb.String()
}

func writeDraftSummary(sb *strings.Builder, owner address, ownerErr string,
	giveKind, giveKey, giveID string, giveAmount int64,
	wantKind, wantKey, wantID string, wantMin, expiry int64,
) {
	sb.WriteString("<gno-frame>\n### Your prepared offer\n\n")
	if ownerErr != "" {
		sb.WriteString("> [!WARNING] Address not recognized\n> " + sanitize.InlineText(ownerErr) + "\n\n")
	}

	var errs []string
	give, gErr := checkDraftAsset("give", giveKind, giveKey, giveID, giveAmount)
	if gErr != "" {
		errs = append(errs, gErr)
	}
	want, wErr := checkDraftAsset("want", wantKind, wantKey, wantID, wantMin)
	if wErr != "" {
		errs = append(errs, wErr)
	}
	if gErr == "" && wErr == "" && give.SameAs(want) {
		errs = append(errs, "An offer cannot give the exact asset it wants.")
	}
	if h := runtime.ChainHeight(); expiry != 0 && expiry <= h {
		errs = append(errs, "The expiry must be a future block height (the current height is "+strconv.FormatInt(h, 10)+"), or 0 for the default of about 7 days.")
	} else if expiry > h+MaxExpiryBlocks {
		errs = append(errs, "The expiry can be at most about 30 days ahead: block height "+strconv.FormatInt(h+MaxExpiryBlocks, 10)+" or lower.")
	}

	if owner != "" {
		nonce, slot := NextSlot(owner)
		target := slot
		if giveKey != "" {
			target = ApproveTarget(owner, nonce, giveKey)
		}
		sb.WriteString("> [!CAUTION] Prepared for account `" + owner.String() + "`\n")
		sb.WriteString("> The addresses below are computed for this account. If it is not yours, do not approve or post: this page was prepared for someone else.\n\n")
		sb.WriteString("**1. Approve this address first** (it belongs to offer number " + u64(nonce) + " of `" + owner.String() + "`):\n\n")
		sb.WriteString("- Approve address: `" + target.String() + "`\n")
		if target != slot {
			sb.WriteString("- Your offer's own address: `" + slot.String() + "` (this collection trades through an adapter, so approve the address above, not this one)\n")
		}
		sb.WriteString("\n")
		if gErr == "" {
			writeApproveInstructions(sb, give, target, slot)
			sb.WriteString("\n")
		}
	}

	if len(errs) > 0 {
		sb.WriteString("> [!NOTE] Finish the offer fields to generate the Post button\n")
		for _, e := range errs {
			sb.WriteString("> - " + sanitize.InlineText(e) + "\n")
		}
		sb.WriteString("</gno-frame>\n\n")
		return
	}

	sb.WriteString("**2. Post your offer:** giving " + keyedAsset(give, false) + " for " + keyedAsset(want, true))
	if expiry != 0 {
		sb.WriteString(" (expires " + blocksAhead(expiry-runtime.ChainHeight()) + ", at block height " + strconv.FormatInt(expiry, 10) + ")")
	} else {
		sb.WriteString(" (expires in about 7 days)")
	}
	sb.WriteString(".\n\n")
	sb.WriteString("Check the keys in code before you sign: anyone can deploy a token or collection with the same symbol or name as a well-known one, and the key is what the offer is for.\n\n")

	postURL := txLink(webPath(), "PostIntent",
		"giveKind", giveKind,
		"giveKey", giveKey,
		"giveID", giveID,
		"giveAmount", strconv.FormatInt(giveAmount, 10),
		"wantKind", wantKind,
		"wantKey", wantKey,
		"wantID", wantID,
		"wantMin", strconv.FormatInt(wantMin, 10),
		"expiry", strconv.FormatInt(expiry, 10),
	)
	sb.WriteString(gnoButton(postURL, "Post offer (wallet / $help)", "success") + "\n")
	sb.WriteString("</gno-frame>\n\n")
}

func checkDraftAsset(side, kind, key, id string, amount int64) (ring.Asset, string) {
	k, ok := ring.ParseKind(kind)
	if !ok {
		return ring.Asset{}, "Choose whether you " + side + " a fungible token or an item."
	}
	if key == "" {
		return ring.Asset{}, "Choose the token or collection you " + side + "."
	}
	a := ring.Asset{Kind: k, Key: key, ID: id, Amount: amount}
	switch k {
	case ring.Fungible:
		if tokenOf(key) == nil {
			return ring.Asset{}, "The selected " + side + " key is not a registered token."
		}
		if id != "" {
			return ring.Asset{}, "Leave the " + side + " item ID blank for tokens."
		}
		if amount <= 0 {
			return ring.Asset{}, "Enter a positive " + side + " token amount."
		}
	case ring.Item:
		if !IsCollection(key) {
			return ring.Asset{}, "The selected " + side + " key is not a registered collection."
		}
		if !validItemID(id) {
			return ring.Asset{}, "Enter a valid " + side + " item ID (1–64 chars: A-Z, a-z, 0-9, . _ : / - *)."
		}
		if amount != 0 {
			return ring.Asset{}, "Set " + side + " amount to 0 for an item."
		}
	}
	return a, ""
}

// renderCollections renders the registered collections with their trust
// labels, official ones first, pageCollections per page; after is the last
// key of the previous page.
func renderCollections(after string) string {
	var sb strings.Builder
	sb.WriteString("# Registered collections\n\n")
	sb.WriteString(navBar("collections") + "\n\n")
	sb.WriteString("Items from any collection listed here can be traded in Kylix rings. Anyone can register a collection, under any display name, so every collection carries one of these labels:\n\n")
	sb.WriteString("- **Official collection:** registered from Kylix's own namespace (`" + namespacePrefix() + "`), built directly for Kylix. You approve your offer's own address in the collection itself.\n")
	sb.WriteString("- **Official adapter:** maintained under Kylix's own namespace for an existing collection. You approve the adapter's per-offer address (`ApproveTarget`).\n")
	sb.WriteString("- **Third-party collection** or **third-party adapter:** registered by someone else under their own namespace. **What this means for you:** its name can copy an official one's, and its code is not Kylix's. Kylix always checks that the item's owner changed after a swap, but read the code before offering or asking for its items, and check the key, not the name.\n\n")

	if collections.Size() == 0 {
		sb.WriteString("No collections are registered yet.\n\n")
	} else {
		keys, more := collectionKeys(after, pageCollections)
		sb.WriteString(strconv.Itoa(collections.Size()) + " registered, official ones first.\n\n")
		sb.WriteString("| Collection | Label | Collection / Adapter key | Target realm | Approval check |\n")
		sb.WriteString("|---|---|---|---|---|\n")
		for _, key := range keys {
			c := getCollection(key)
			target := "—"
			if c.target != "" {
				target = "[" + sanitize.TableCell(c.target) + "](" + pkgWebPath(c.target) + ")"
			}
			check := "No"
			if c.approved != nil {
				check = "Yes"
			}
			sb.WriteString("| **" + sanitize.TableCell(c.name) + "** | " + collectionKind(key) + " | [" +
				sanitize.TableCell(key) + "](" + pkgWebPath(key) + ") | " + target + " | " + check + " |\n")
		}
		if more {
			sb.WriteString("\n[More collections →](" + webPath() + ":collections?after=" + url.QueryEscape(keys[len(keys)-1]) + ")\n")
		}
		sb.WriteString("\n")
	}

	sb.WriteString("Want to make your own collection tradable on Kylix? See the [plug-in guide](" + webPath() + ":about#plug-in-your-collection).\n")
	return sb.String()
}

// renderAbout explains how Kylix works, custody guarantees, GnoSwap fees,
// what settling costs, and how collection authors plug in.
func renderAbout() string {
	var sb strings.Builder
	sb.WriteString("# How Kylix works\n\n")
	sb.WriteString(navBar("about") + "\n\n")

	sb.WriteString("Kylix is named after the Greek drinking cup passed round the circle at a banquet. ")
	sb.WriteString("Instead of matching only two people who want each other's exact asset, Kylix lets 2 to 6 offers form a closed circle and settles every swap at once.\n\n")
	sb.WriteString("For example: Alice offers **100 OBOL** and wants **50 DRACHMA**; Bob offers **Relic #2** and wants **100 OBOL**; Carol offers **50 DRACHMA** and wants **Relic #2**. ")
	sb.WriteString("No two of them can trade directly, yet passing each asset one step round the circle satisfies everyone in a single transaction.\n\n")

	sb.WriteString("## How settlement works\n\n")
	sb.WriteString("1. **Approve one dedicated address.** Each offer gets its own address (`NextSlot`, or `ApproveTarget` for collections that trade through an adapter). You allow only that address to move only the asset you are offering.\n")
	sb.WriteString("2. **Post your offer.** State what you give and the minimum you want back. Approve first: Kylix accepts an offer of a token, or of an item of an official collection, only if it could settle right now, so you must hold what you offer and have approved it. An item of a third-party collection is not checked when you post, so that collection's code never runs at your expense; it is checked when someone settles. Nothing leaves your wallet when you post. ")
	sb.WriteString("Every offer has an end date: about 7 days unless you choose another block height, and at most about 30 days.\n")
	sb.WriteString("3. **Anyone settles the ring.** When 2 to 6 open offers close a ring, anyone (a trader, a visitor on this page, or a program that searches for rings) can settle it with `SettleRing`.\n")
	sb.WriteString("4. **All or nothing.** Kylix checks that every offer is open, not expired and ready, removes the offers from the book, and moves every asset straight from each owner to the next. If any single swap fails, the whole transaction is undone and nothing moves.\n\n")

	sb.WriteString("## Check the key, not the name\n\n")
	sb.WriteString("Anyone can deploy a token whose symbol is GNS or OBOL, or register a collection called Kylix Relics. ")
	sb.WriteString("So Kylix shows next to every asset the realm it lives in (for example `nym-kylix000/kylixdemo`), and, where you decide to approve, post or settle, its full key. ")
	sb.WriteString("Collections registered from Kylix's own namespace are labelled **official**; every other one is **third-party**, whatever its name says.\n\n")
	sb.WriteString("## Approve exactly the amount you offer\n\n")
	sb.WriteString("A token offer settles only if its address may spend exactly the amount offered, not more. ")
	sb.WriteString("The approval is then used up when the ring settles, and the token realm frees it; a larger approval would stay behind, and the person settling would pay to store each receiver's new balance with nothing freed in return.\n\n")
	sb.WriteString("## What Kylix can and cannot do with your assets\n\n")
	sb.WriteString("<gno-columns>\n<gno-frame>\n### What Kylix can do\n")
	sb.WriteString("- Move **only** the token amount or item you offered, through an approval for exactly that, for a single offer.\n")
	sb.WriteString("- Move it **only** when a closed ring gives you at least the minimum you asked for.\n")
	sb.WriteString("- Return each offer's storage deposit to whoever removes it: you when you cancel, the settler when it settles, anyone once it has expired.\n")
	sb.WriteString("</gno-frame>\n<gno-columns-sep />\n<gno-frame>\n### What Kylix cannot do\n")
	sb.WriteString("- Hold your tokens or collectibles between swaps (no custody, no escrow vault).\n")
	sb.WriteString("- Reuse one offer's approval for any other offer or any other owner.\n")
	sb.WriteString("- Stop you from cancelling: cancelling calls no other realm.\n")
	sb.WriteString("- Accept native GNOT directly: trade GNOT as wrapped `wugnot` instead.\n")
	sb.WriteString("</gno-frame>\n</gno-columns>\n\n")

	sb.WriteString("## Swaps through GnoSwap\n\n")
	sb.WriteString("When a ring has one gap where someone gives token A and the next person wants a different token B, Kylix can fill that gap with a swap on **GnoSwap**, inside the same transaction.\n\n")
	sb.WriteString("> [!WARNING] Your minimum is your price\n")
	sb.WriteString("> When what you receive comes through a GnoSwap swap, expect to receive exactly the minimum you asked for, not more. ")
	sb.WriteString("Anyone can trade on the same pool in the same transaction, just before and after the swap, and keep any difference above your minimum. ")
	sb.WriteString("Set your minimum to the amount you actually want.\n\n")
	sb.WriteString("- **Kylix fee:** none.\n")
	sb.WriteString("- **GnoSwap pool fee:** 0.01%, 0.05%, 0.3% or 1%, depending on the pool.\n")
	sb.WriteString("- **GnoSwap router fee:** 0.15% of what the swap returns.\n")
	sb.WriteString("- **Which pool:** the person settling chooses it (`SettleRingVia`). `SettleRing` picks the pool holding the most of the token being bought, which works when a pair has one pool; with several, anyone can add liquidity that makes it pick a pool that cannot pay, and settling then fails until someone names a better pool.\n")
	sb.WriteString("- **Minimum protection:** if the swap returns less than the receiver's minimum after fees, nothing in the ring moves.\n\n")

	sb.WriteString("## What settling costs\n\n")
	sb.WriteString("Settling a ring that includes collectibles runs code written by each of those collections. That code can store data in its own realm, ")
	sb.WriteString("and the chain charges the storage deposit to whoever sends the transaction; a dishonest collection can collect that deposit later. ")
	sb.WriteString("If you settle rings, set a tight deposit limit (`-max-deposit` in gnokey) and be careful with **third-party** collections and adapters. ")
	sb.WriteString("Posting, cancelling and removing an expired offer never run third-party collection code, and neither does any page except a third-party item's own offer and ring pages: only settling does, and only the settler pays for it.\n\n")

	sb.WriteString("## Notifications\n\n")
	sb.WriteString("Kylix announces every settled offer to its owner (`OfferSettled`). ")
	sb.WriteString("You can opt in to browser alerts for your address on [gnotif](https://gnotif.xyz).\n\n")

	sb.WriteString("## Plug in your collection\n\n")
	sb.WriteString("> [!CAUTION] An item id must fix the item's value\n")
	sb.WriteString("> Between posting and settlement, the owner keeps the item. If anything that gives the item its value can change while its id stays the same, ")
	sb.WriteString("such as contents that can be withdrawn, an unrevealed picture, or a lease the owner can shorten, a buyer can pay for one thing and receive another. ")
	sb.WriteString("Such items must not be offered: put everything that decides the value into the id, or have your approval check answer no while the value can still change.\n\n")
	sb.WriteString("> [!CAUTION] An approval Kylix uses must be consumed by the move\n")
	sb.WriteString("> Accept only an approval of this one item, for exactly the address Kylix asks for, in both your approval check and your move, and make sure the transfer clears it. ")
	sb.WriteString("Do not accept an approval for all items (`SetApprovalForAll`): the transfer leaves it in place, so its storage deposit never comes back to whoever settles, while they pay for the receivers' new entries.\n\n")
	sb.WriteString("Any GRC721 or custom item realm can join Kylix in a few lines. Kylix calls your `Move` function crossing as the offer's own address, and checks `OwnerOf` afterwards:\n\n")
	sb.WriteString("```go\n")
	sb.WriteString("import \"" + selfPath + "\"\n\n")
	sb.WriteString("func init(cur realm) {\n")
	sb.WriteString("\tkylix.RegisterItem(cross(cur), \"My Collection\", MoveForKylix, OwnerForKylix)\n")
	sb.WriteString("\tkylix.RegisterApprovalCheck(cross(cur), ApprovedForKylix) // optional\n")
	sb.WriteString("}\n\n")
	sb.WriteString("func MoveForKylix(cur realm, from, to address, itemID string) error {\n")
	sb.WriteString("\t// cur.Previous().Address() is the offer's address that `from` approved.\n")
	sb.WriteString("\t// Use only an approval of this one item: the transfer clears it.\n")
	sb.WriteString("\tif a, _ := token.GetApproved(grc721.TokenID(itemID)); a != cur.Previous().Address() {\n")
	sb.WriteString("\t\treturn errors.New(\"approve this offer's address for the item itself\")\n")
	sb.WriteString("\t}\n")
	sb.WriteString("\treturn ledger.CallerTeller().TransferFrom(0, cur, from, to, grc721.TokenID(itemID))\n")
	sb.WriteString("}\n\n")
	sb.WriteString("func OwnerForKylix(id kylix.ItemID) address {\n")
	sb.WriteString("\towner, _ := token.OwnerOf(grc721.TokenID(id))\n")
	sb.WriteString("\treturn owner\n")
	sb.WriteString("}\n\n")
	sb.WriteString("func ApprovedForKylix(id kylix.ItemID, spender address) bool {\n")
	sb.WriteString("\tapproved, _ := token.GetApproved(grc721.TokenID(id))\n")
	sb.WriteString("\treturn approved != \"\" && approved == spender // not IsApprovedForAll\n")
	sb.WriteString("}\n")
	sb.WriteString("```\n\n")
	sb.WriteString("`OwnerForKylix` and `ApprovedForKylix` must not panic and should not store anything: return the empty address or false for an id you do not know. ")
	sb.WriteString("Kylix calls them when a ring with your item is settled, and on that offer's and ring's own pages; posting, cancelling and the home page never call a third-party collection. (Official collections, Kylix's own, are also checked at posting and on the home page.) ")
	sb.WriteString("For an already-deployed collection that cannot be changed, deploy a small adapter realm that calls `kylix.RegisterAdapter` and crosses into the target collection as `cur.Sub(\"k/\" + cur.Previous().Address().String())`.\n")
	return sb.String()
}

// pinnedTokens are listed first in the post page's token dropdowns, when
// registered: wrapped GNOT and GnoSwap's GNS. The demo tokens follow them.
var pinnedTokens = []string{"gno.land/r/gnoland/wugnot.wugnot", "gno.land/r/gnoswap/gns.GNS"}

// knownAssets lists the choices for the post page's dropdowns, at most
// maxFormAssetOpts tokens and maxFormAssetOpts collections. Anyone can
// register tokens and collections, so the useful ones come first and cannot
// be pushed out: tokens are wugnot, GNS, the demo realm's tokens, then the
// rest of grc20reg in key order; collections are the official ones, then
// the rest. Every key in selected that is registered is always included.
func knownAssets(selected ...string) (tokens []string, colls []string) {
	seenTok := map[string]bool{}
	addTok := func(key string) {
		if !seenTok[key] && tokenOf(key) != nil {
			seenTok[key] = true
			tokens = append(tokens, key)
		}
	}
	for _, k := range pinnedTokens {
		addTok(k)
	}
	reg := grc20reg.GetRegistry()
	if demo := demoRealmPath(); demo != "" && reg != nil {
		reg.Iterate(demo+".", demo+"/", func(key string, _ any) bool {
			if len(tokens) >= maxFormAssetOpts {
				return true
			}
			addTok(key)
			return false
		})
	}
	for _, k := range selected {
		addTok(k)
	}
	if reg != nil {
		reg.Iterate("", "", func(key string, _ any) bool {
			if len(tokens) >= maxFormAssetOpts {
				return true
			}
			addTok(key)
			return false
		})
	}

	seenColl := map[string]bool{}
	for _, k := range selected {
		if IsCollection(k) && IsOfficial(k) && !seenColl[k] {
			seenColl[k] = true
			colls = append(colls, k)
		}
	}
	keys, _ := collectionKeys("", maxFormAssetOpts)
	for _, k := range keys {
		if len(colls) >= maxFormAssetOpts {
			break
		}
		if !seenColl[k] {
			seenColl[k] = true
			colls = append(colls, k)
		}
	}
	for _, k := range selected {
		if IsCollection(k) && !seenColl[k] {
			seenColl[k] = true
			colls = append(colls, k)
		}
	}
	return tokens, colls
}

func writeKindSelect(sb *strings.Builder, name, desc, selected string, required bool) {
	sb.WriteString(gnoSelectOpt(name, "fungible", desc, selected == "" || selected == "fungible", required))
	sb.WriteString(gnoSelectOpt(name, "item", "", selected == "item", false))
}

func writeAssetSelect(sb *strings.Builder, name, desc, selected string, tokens, colls []string, required bool) {
	first := true
	addOpt := func(key string) {
		d := ""
		req := false
		if first {
			d = desc
			req = required
			first = false
		}
		sb.WriteString(gnoSelectOpt(name, key, d, key == selected, req))
	}
	for _, k := range tokens {
		addOpt(k)
	}
	for _, k := range colls {
		addOpt(k)
	}
	if first {
		// No registered assets yet; fall back to a plain input.
		sb.WriteString(gnoInput(name, desc, selected, required, false))
	}
}

func resolveOwnerInput(raw string) (address, string) {
	s := strings.TrimSpace(raw)
	if s == "" {
		return "", ""
	}
	s = strings.TrimPrefix(s, "@")
	if a := address(s); a.IsValid() {
		return a, ""
	}
	if u, _ := users.ResolveName(s); u != nil {
		return u.Addr(), ""
	}
	return "", "Enter a valid g1 address or a registered username."
}

func parseKindChoice(s string) string {
	switch strings.TrimSpace(s) {
	case "fungible":
		return "fungible"
	case "item":
		return "item"
	}
	return ""
}

// allowAssetKey accepts a key only if it is a registered token or
// collection, by direct lookup: no list of choices can crowd it out.
func allowAssetKey(raw string) string {
	s := strings.TrimSpace(raw)
	if s == "" || len(s) > 256 {
		return ""
	}
	if IsCollection(s) || tokenOf(s) != nil {
		return s
	}
	return ""
}

func cleanItemIDInput(raw string) string {
	s := strings.TrimSpace(raw)
	if validItemID(s) {
		return s
	}
	return ""
}

func parseNonNegInt64(raw string) int64 {
	s := strings.TrimSpace(raw)
	if s == "" {
		return 0
	}
	n, err := strconv.ParseInt(s, 10, 64)
	if err != nil || n < 0 {
		return 0
	}
	return n
}

func formatIntOrEmpty(n int64) string {
	if n <= 0 {
		return ""
	}
	return strconv.FormatInt(n, 10)
}

func formatFeePercent(fee uint32) string {
	switch fee {
	case 100:
		return "0.01%"
	case 500:
		return "0.05%"
	case 3000:
		return "0.30%"
	case 10000:
		return "1.00%"
	}
	return strconv.FormatUint(uint64(fee), 10)
}

// plainSwapReason rewords internal p/ring error wording ("leg"/"legs") so
// user-facing pages speak consistently in terms of swaps and offers.
func plainSwapReason(s string) string {
	s = strings.ReplaceAll(s, " legs", " swaps")
	s = strings.ReplaceAll(s, "leg ", "swap ")
	return s
}
