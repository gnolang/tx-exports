package mandate

import (
	"strconv"
	"strings"
	"time"
)

// SourceRepo is where the source code is published, shown in the footer of
// every page.
const SourceRepo = "https://github.com/elangrr/mandate"

// Network the copy-ready commands are pinned to.
const (
	ChainID = "onyx-1"
	Remote  = "https://rpc.onyx.testnets.gno.land:443"
)

// Gas settings used in the commands. The chain charges the whole fee set,
// whatever gas is used, and accepts it when fee / gas wanted is at least
// the current gas price (1 ugnot per 1,000 gas on Onyx). Measured on a local
// chain: Offer and Subscribe use 7M to 10M gas, Pull 8M to 9M. Reads on
// Onyx cost more per object (the chain prices a read by its store's depth,
// and Onyx's store is far larger), so gas wanted keeps about 2x headroom.
// The Pull fee counts against the session's spend limit (see FeeAllowance).
const (
	callGas = "-gas-fee 100000ugnot -gas-wanted 60000000"
	pullGas = "-gas-fee 20000ugnot -gas-wanted 20000000"
)

// Render returns the gnoweb page for path, with the footer.
func Render(path string) string {
	return renderPage(path) + footer()
}

func footer() string {
	return "\n---\n\nBuilt on [gno.land](https://gno.land) · source code: [" + strings.TrimPrefix(SourceRepo, "https://") + "](" + SourceRepo + ")\n"
}

func renderPage(raw string) string {
	path, query := raw, ""
	if i := strings.Index(raw, "?"); i >= 0 {
		path, query = raw[:i], raw[i+1:]
	}
	page := pageParam(query)
	from := intParam(query, "from", -1)
	parts := strings.Split(path, "/")
	switch {
	case path == "":
		return renderHome(from)
	case path == "plans":
		return renderAllPlans(page)
	case path == "help":
		return renderHelp()
	case len(parts) == 2 && parts[0] == "plan":
		id, err := strconv.ParseUint(parts[1], 10, 64)
		if err != nil {
			return renderNotFound()
		}
		return renderPlan(id, from)
	case len(parts) == 2 && parts[0] == "payer":
		a := address(parts[1])
		if !a.IsValid() {
			return renderNotFound()
		}
		return renderPayer(a, page)
	case len(parts) == 2 && parts[0] == "payee":
		a := address(parts[1])
		if !a.IsValid() {
			return renderNotFound()
		}
		return renderPayee(a, page)
	}
	return renderNotFound()
}

func renderHome(from int) string {
	nPlans, nMandates, pulls, paid := Totals()
	var b strings.Builder
	b.WriteString("# Mandate\n\n")
	b.WriteString("**Subscriptions and direct debit on native GNOT.** A creator publishes a plan, such as 1 GNOT every week. ")
	b.WriteString("A supporter signs one permission from their own wallet: *at most this much, every period, through this realm only, until I cancel or it expires*. ")
	b.WriteString("The creator's collector then pulls each payment at the start of the period, and this realm checks who, how much and when before it forwards the coins.\n\n")
	b.WriteString("## The honest limits\n\n")
	b.WriteString("- **It is direct debit, not escrow.** Nothing is locked up front. A supporter can stop at any time, and a creator is only paid when a pull succeeds.\n")
	b.WriteString("- **A hard cap the supporter sets.** The chain never lets a pull take more than the session's spend limit per period: the plan's amount plus a fee allowance of " + formatUgnot(FeeAllowance) + ". ")
	b.WriteString("A dishonest creator could at worst burn that allowance as network fees; they can never take more, or pull more often.\n")
	b.WriteString("- **At most " + strconv.Itoa(MaxSessionsPerWallet) + " mandates per wallet**, because the chain allows " + strconv.Itoa(MaxSessionsPerWallet) + " session keys per account.\n")
	b.WriteString("- **Revoke any time.** Revoking the session on chain stops every pull at once. The realm cannot see a revoke, so a mandate still shows here as active until it is cancelled or expires: [how to stop a mandate](" + link("help") + ").\n")
	b.WriteString("- **One realm, nothing under it.** A session for this realm also covers any realm deployed under its path, so nothing will ever be deployed there.\n")
	b.WriteString("- No admin, no pause, no upgrade. The realm never holds funds: each payment goes straight to the creator in the same transaction.\n\n")
	b.WriteString("[How to use it, with every command](" + link("help") + ")\n\n")
	b.WriteString("## Numbers\n\n")
	b.WriteString("| Plans | Mandates ever recorded | Payments | Paid out |\n|---|---|---|---|\n")
	b.WriteString("| " + strconv.Itoa(nPlans) + " | " + strconv.Itoa(nMandates) + " | " + itoa(pulls) + " | " + formatUgnot(paid) + " |\n\n")
	b.WriteString("## Supporter pages\n\n")
	b.WriteString(plansWithSupporters(from))
	return b.String()
}

// homeScanPlans is how many plans one home page walks. Each check reads only
// the plan itself (its payment counters), never its supporters.
const homeScanPlans = ScanLimit

// plansWithSupporters lists, newest first, the plans that someone paid in
// the current or the previous period, walking at most homeScanPlans plans
// per page: plans nobody pays for (spam included) never fill this list, and
// a "more" link continues the walk. A plan someone keeps paying for stays,
// whatever the churn of its supporter list.
func plansWithSupporters(from int) string {
	var b strings.Builder
	n := plans.Size()
	if from < 0 || from >= n {
		from = n - 1
	}
	rows := 0
	i := from
	now := time.Now().Unix()
	var t strings.Builder
	for walked := 0; i >= 0 && walked < homeScanPlans && rows < PageSize; i, walked = i-1, walked+1 {
		_, v := plans.GetByIndex(i)
		p := v.(*Plan)
		if current, previous := p.paidWindows(now); current+previous == 0 {
			continue
		}
		t.WriteString("| [#" + utoa(p.ID) + " " + escCell(p.Title) + "](" + link("plan/"+utoa(p.ID)) + ") | " + price(p.Amount, p.Period) +
			" | [" + short(p.Payee) + "](" + link("payee/"+p.Payee.String()) + ") | " + payingCell(p, now) +
			" | " + itoa(p.Pulls) + " |\n")
		rows++
	}
	if rows == 0 {
		b.WriteString("No plan has been paid for in its current or last period")
		if i >= 0 {
			b.WriteString(" among those looked at")
		}
		b.WriteString(".\n\n")
	} else {
		b.WriteString("| Plan | Price | Creator | Payments this / last period | All payments |\n|---|---|---|---|---|\n")
		b.WriteString(t.String() + "\n")
	}
	if i >= 0 {
		b.WriteString("[More plans with supporters](" + link("") + "?from=" + strconv.Itoa(i) + ")\n\n")
	}
	b.WriteString("Only plans that someone has paid for are listed here. [All plans, newest first](" + link("plans") + ")\n")
	return b.String()
}

func renderAllPlans(page int) string {
	var b strings.Builder
	b.WriteString("# All plans\n\nNewest first, including plans nobody has paid for yet. [Back to Mandate](" + link("") + ")\n\n")
	list := Plans(page)
	if len(list) == 0 {
		b.WriteString("No plans on this page.\n")
		return b.String()
	}
	b.WriteString("| Plan | Price | Creator | Payments this / last period | All payments |\n|---|---|---|---|---|\n")
	for _, p := range list {
		b.WriteString("| [#" + utoa(p.ID) + " " + escCell(p.Title) + "](" + link("plan/"+utoa(p.ID)) + ") | " + price(p.Amount, p.Period) +
			" | [" + short(p.Payee) + "](" + link("payee/"+p.Payee.String()) + ") | " + infoPayingCell(p) +
			" | " + itoa(p.Pulls) + " |\n")
	}
	b.WriteString(pager("plans", page, len(list) == PageSize))
	return b.String()
}

func renderPlan(id uint64, from int) string {
	p := planOf(id)
	if p == nil {
		return renderNotFound()
	}
	now := time.Now().Unix()
	pe := payeeOf(p.Payee)
	var b strings.Builder
	b.WriteString("# Plan #" + utoa(p.ID) + ": " + esc(p.Title) + "\n\n")
	b.WriteString("**" + price(p.Amount, p.Period) + "** to [" + p.Payee.String() + "](" + link("payee/"+p.Payee.String()) + ")")
	if p.Period < 86400 {
		b.WriteString(" (a test plan: the period is under a day)")
	}
	b.WriteString("\n\n")
	b.WriteString("Plan " + utoa(p.ID) + " · published " + formatTime(p.CreatedAt) + " · " + payingText(p, now) + " · " +
		plural(int(p.Pulls), "payment", "payments") + ", " + formatUgnot(p.Pulls*p.Amount) + " in total · last payment: " + formatTimeOrNever(p.LastPullAt) + "\n\n")
	b.WriteString("Plans never change. New terms are published as a new plan.\n\n")

	b.WriteString("## Supporters\n\n")
	list, next := payingFrom(p, from, now)
	if len(list) == 0 {
		b.WriteString("No paying supporters")
		if next >= 0 {
			b.WriteString(" in this part of the list")
		}
		b.WriteString(".\n\n")
	} else {
		b.WriteString("| Supporter | Since | Payments | Last payment |\n|---|---|---|---|\n")
		for _, m := range list {
			b.WriteString("| [" + short(m.Payer) + "](" + link("payer/"+m.Payer.String()) + ") | " + formatTime(m.CreatedAt) + " | " + itoa(m.Pulls) +
				" | " + formatTimeOrNever(m.lastPullAt()) + " |\n")
		}
		b.WriteString("\n")
	}
	if next >= 0 {
		b.WriteString("[More supporters](" + link("plan/"+utoa(id)) + "?from=" + strconv.Itoa(next) + ")\n\n")
	}
	unpaid, exact := countUnpaid(p, now)
	b.WriteString("Supporters are listed and counted from their first payment on, newest first, while their mandate is active. ")
	b.WriteString("Cancelled and expired mandates are not listed or counted; a supporter who revoked the session on chain stays listed until the mandate is cancelled or expires. ")
	b.WriteString(plural(unpaid, "active mandate has", "active mandates have") + " not paid yet (not listed)")
	if !exact {
		b.WriteString(", among the latest " + strconv.Itoa(ScanLimit))
	}
	b.WriteString(".\n\n")

	b.WriteString("## Support this plan\n\n")
	spend := p.Amount + FeeAllowance
	expires := now + 365*86400
	if pe == nil || pe.CollectorKey == "" {
		b.WriteString("The creator has not published a collector key yet, so there is nothing to subscribe to. Ask them to run `SetCollectorKey`.\n\n")
		return b.String()
	}
	if collectorFunded(pe.CollectorAddr) {
		b.WriteString("**New supporters cannot join right now.** The creator's collector key (`" + pe.CollectorAddr.String() + "`) has received coins, so its address is an account, and the chain refuses a session for a key whose address is an account. " +
			"This creator must publish a new collector key before new supporters can join. Existing mandates keep working until they expire; renewing needs the new key. " +
			"A creator can also hand you a fresh session key privately: `Subscribe` accepts any session key, not only the published one.\n\n")
		return b.String()
	}
	b.WriteString("You need [gnokey](https://docs.gno.land) and a key with some GNOT on " + ChainID + ". Replace `YOUR_KEY` with your key's name. " +
		"You can support one plan of each creator at a time: every plan of a creator is collected by the same key, and the chain allows one session per key. To switch plans, cancel and revoke first (time you paid for carries over to the same plan only). ")
	b.WriteString("These two commands give the creator's collector key (`" + pe.CollectorAddr.String() + "`) the right to take **at most " +
		formatUgnot(spend) + " every " + formatPeriod(p.Period) + "** (the price plus a fee allowance), through this realm only, for one year.\n\n")
	b.WriteString("1. Create the session (your own key; it cannot be done with a session). If the chain answers `session key address collides with existing account`, this collector key can no longer be used for new sessions: ask the creator to publish a new one.\n\n")
	b.WriteString("```\ngnokey maketx session create -pubkey " + pe.CollectorKey + " -allow-paths vm/exec:" + realmPath +
		" -spend-limit " + itoa(spend) + "ugnot -spend-period " + itoa(p.Period) + " -expires-at " + itoa(expires) + " " + callGas + " " + netFlags() + " YOUR_KEY\n```\n\n")
	b.WriteString("2. Record the terms here:\n\n")
	b.WriteString("```\ngnokey maketx call -pkgpath " + realmPath + " -func Subscribe -args " + utoa(p.ID) + " -args " + pe.CollectorAddr.String() +
		" -args " + itoa(expires) + " " + callGas + " " + netFlags() + " YOUR_KEY\n```\n\n")
	b.WriteString("The first payment is collected right after, then one every " + formatPeriod(p.Period) + ". If you paid for this plan before and that period has not ended " +
		"(you cancelled, the creator cancelled, or your mandate expired), the new mandate's first payment waits until it ends, so time you paid for is not charged twice. " +
		"The one exception: a wallet keeps paid time for at most " + strconv.Itoa(MaxCreditsPerPayer) + " plans it has left; beyond that, a creator's cancel keeps nothing for that creator's plan, and your own cancel or expiry lets the period that ends soonest go. Your page at `" + link("payer/<your address>") +
		"` shows how to stop.\n")
	return b.String()
}

func renderPayer(payer address, page int) string {
	var b strings.Builder
	b.WriteString("# Mandates of " + payer.String() + "\n\n")
	b.WriteString("Each mandate lets one creator's collector key pull a fixed amount once per period. To stop one completely, run both commands shown under it: ")
	b.WriteString("**revoke** removes the session on chain (no pull can be signed any more) and **cancel** ends the mandate here. Revoke alone already stops every payment.\n\n")
	list := MandatesOf(payer, page)
	if len(list) == 0 {
		b.WriteString("No mandates on this page.\n")
		return b.String()
	}
	now := time.Now().Unix()
	for _, m := range list {
		p := planOf(m.PlanID)
		b.WriteString("## Mandate " + utoa(m.ID) + ": [plan #" + utoa(p.ID) + " " + esc(p.Title) + "](" + link("plan/"+utoa(p.ID)) + ")\n\n")
		b.WriteString("- Status here: **" + m.Status + "**")
		if m.Status == "active" {
			b.WriteString(" (if you revoked the session on chain, no payment can be taken)")
		}
		b.WriteString("\n- Price: " + price(m.Amount, m.Period) + " to [" + short(m.Payee) + "](" + link("payee/"+m.Payee.String()) + ")\n")
		b.WriteString("- Session key: `" + m.Session.String() + "`\n")
		b.WriteString("- Payments: " + itoa(m.Pulls) + ", " + formatUgnot(m.Paid) + " in total, last: " + formatTimeOrNever(m.LastPullAt) + "\n")
		if m.Status == "active" {
			if m.Pulls == 0 && m.PaidThrough > 0 {
				b.WriteString("- First payment on " + formatTime(m.NextPullAt) + ": your current period is already paid (time carried over from your earlier mandate for this plan) · ends: " + formatTime(m.ExpiresAt) + "\n")
			} else {
				b.WriteString("- Next payment allowed from: " + formatTime(m.NextPullAt) + " · ends: " + formatTime(m.ExpiresAt) + "\n")
			}
		} else if m.PaidThrough > now {
			if PaidThrough(payer, m.PlanID) >= m.PaidThrough {
				b.WriteString("- Paid through " + formatTime(m.PaidThrough) + ": that time stays yours. A new mandate for this plan starts its payments then.\n")
			} else {
				b.WriteString("- Paid through " + formatTime(m.PaidThrough) + ", but that time could not be kept: a wallet keeps paid time for at most " +
					strconv.Itoa(MaxCreditsPerPayer) + " plans it has left, and a creator's cancel never pushes another one out. A new mandate for this plan would pay at once.\n")
			}
		}
		b.WriteString("\n")
		if m.Status != "cancelled" {
			b.WriteString("Revoke the session (your own key):\n\n")
			if m.SessionPubKey != "" {
				b.WriteString("```\ngnokey maketx session revoke -pubkey " + m.SessionPubKey + " " + callGas + " " + netFlags() + " YOUR_KEY\n```\n\n")
			} else {
				b.WriteString("This session's public key is not recorded here. List your sessions to find it, then run `gnokey maketx session revoke -pubkey <its gpub1 key> ... YOUR_KEY`:\n\n")
				b.WriteString("```\ngnokey query auth/accounts/" + payer.String() + "/sessions -remote " + Remote + "\n```\n\n")
			}
			b.WriteString("Cancel the mandate (your own key):\n\n")
			b.WriteString("```\ngnokey maketx call -pkgpath " + realmPath + " -func Cancel -args " + payer.String() + " -args " + m.Session.String() + " " + callGas + " " + netFlags() + " YOUR_KEY\n```\n\n")
		}
	}
	b.WriteString(pager("payer/"+payer.String(), page, len(list) == PageSize))
	return b.String()
}

func renderPayee(payee address, page int) string {
	var b strings.Builder
	b.WriteString("# Creator " + payee.String() + "\n\n")
	pe := payeeOf(payee)
	if pe == nil {
		b.WriteString("No plans from this address.\n")
		return b.String()
	}
	b.WriteString("| Plans | Payments | Received | Last payment |\n|---|---|---|---|\n")
	b.WriteString("| " + strconv.Itoa(pe.Plans) + " | " + itoa(pe.Pulls) + " | " + formatUgnot(pe.Paid) + " | " + formatTimeOrNever(pe.LastPullAt) + " |\n\n")
	if pe.CollectorKey == "" {
		b.WriteString("Collector key: **not published**. Supporters cannot subscribe until it is (see [help](" + link("help") + ")).\n\n")
	} else {
		b.WriteString("Collector key: `" + pe.CollectorAddr.String() + "` (`" + pe.CollectorKey + "`)\n\n")
		if collectorFunded(pe.CollectorAddr) {
			b.WriteString("**This collector key's address has received coins, so the chain refuses new sessions for it: nobody new can subscribe.** The creator must publish a new collector key; existing mandates keep being collected with this one until they expire, and renewing needs the new key.\n\n")
		}
	}
	b.WriteString("## Plans\n\n")
	list := PlansOf(payee, page)
	if len(list) == 0 {
		b.WriteString("No plans on this page.\n")
		return b.String()
	}
	b.WriteString("| Plan | Price | Payments this / last period | All payments | Last payment |\n|---|---|---|---|---|\n")
	for _, p := range list {
		b.WriteString("| [#" + utoa(p.ID) + " " + escCell(p.Title) + "](" + link("plan/"+utoa(p.ID)) + ") | " + price(p.Amount, p.Period) + " | " +
			infoPayingCell(p) + " | " + itoa(p.Pulls) + " | " + formatTimeOrNever(p.LastPullAt) + " |\n")
	}
	b.WriteString(pager("payee/"+payee.String(), page, len(list) == PageSize))
	return b.String()
}

func renderHelp() string {
	var b strings.Builder
	b.WriteString("# How to use Mandate\n\n")
	b.WriteString("Every command is for the **" + ChainID + "** test network and uses test GNOT. Replace the words in capitals. ")
	b.WriteString("Amounts are in ugnot (1 GNOT = 1,000,000 ugnot); periods and times are in seconds and unix seconds.\n\n")

	b.WriteString("## For creators\n\n")
	b.WriteString("1. Publish a plan with your own key: a title (one line, at most " + strconv.Itoa(MaxTitleLen) + " characters, no invisible formatting characters: direction controls and zero-width characters, the joiner included, are refused, so emoji joined into one, such as families, cannot be used), the amount (at least " +
		formatUgnot(MinAmount) + ") and the period (" + itoa(MinPeriod) + " seconds to " + itoa(MaxPeriod/86400) + " days). Plans cannot be changed.\n\n")
	b.WriteString("```\ngnokey maketx call -pkgpath " + realmPath + " -func Offer -args \"TITLE\" -args 1000000 -args 604800 " + callGas + " " + netFlags() + " YOUR_KEY\n```\n\n")
	b.WriteString("2. Make a separate key for collecting (`gnokey add COLLECTOR_KEY`) and publish its public key (the `gpub1...` value `gnokey list` shows), signed with your own key. " +
		"**Never send coins to the collector key's address**, not even for fees (the supporter pays every fee): an address that has received coins is an account, and the chain refuses to create a session for it, so nobody new could subscribe. " +
		"Anyone can do this to a published key with a 1 ugnot send, and a realm can even make the address an account that holds nothing. In most cases the plan page then says so; in every case supporters get the chain error `session key address collides with existing account` when they create the session, and the collector script warns. " +
		"Then the key can no longer be used for new sessions: make a new key and publish it (this command again). New supporters then use the new key, and existing mandates keep being collected with the old one: run one collector per key. " +
		"`Subscribe` accepts any session key you hand out, so you can also give supporters a fresh key privately:\n\n")
	b.WriteString("```\ngnokey maketx call -pkgpath " + realmPath + " -func SetCollectorKey -args GPUB_OF_COLLECTOR_KEY " + callGas + " " + netFlags() + " YOUR_KEY\n```\n\n")
	b.WriteString("3. Collect each payment when it is due, signed with the collector key on behalf of the supporter. Only the exact price is accepted, at most once per period. The fee counts against the supporter's fee allowance, so keep it small. " +
		"The command below uses today's minimum fee on " + ChainID + " (1 ugnot per 1,000 gas); when the chain raises its gas price, raise `-gas-fee` with it (`gnokey query auth/gasprice`), within the allowance. The collector script does this itself:\n\n")
	b.WriteString("```\ngnokey maketx call -pkgpath " + realmPath + " -func Pull -send AMOUNTugnot -master SUPPORTER_ADDRESS " + pullGas + " " + netFlags() + " COLLECTOR_KEY\n```\n\n")
	b.WriteString("The repository has a collector script that finds what is due through free queries and pulls it.\n\n")

	b.WriteString("## For supporters\n\n")
	b.WriteString("Open a plan's page: it shows the two exact commands, with the creator's collector key, the spend limit (price plus " + formatUgnot(FeeAllowance) +
		" for fees) and the period filled in. The general form:\n\n")
	b.WriteString("```\ngnokey maketx session create -pubkey COLLECTOR_GPUB -allow-paths vm/exec:" + realmPath + " -spend-limit PRICE_PLUS_" + itoa(FeeAllowance) +
		"ugnot -spend-period PERIOD_SECONDS -expires-at UNIX_TIME " + callGas + " " + netFlags() + " YOUR_KEY\n")
	b.WriteString("gnokey maketx call -pkgpath " + realmPath + " -func Subscribe -args PLAN_ID -args COLLECTOR_ADDRESS -args UNIX_TIME " + callGas + " " + netFlags() + " YOUR_KEY\n```\n\n")
	b.WriteString("Use the same UNIX_TIME for both, at most " + itoa(MaxTerm/86400) + " days ahead. The session must allow exactly `vm/exec:" + realmPath +
		"` and nothing else, or Pull refuses it. PERIOD_SECONDS is the plan's period, at most " + itoa(MaxPeriod/86400) + " days (the chain's limit on a spend period). " +
		"You can support one plan of each creator at a time: all of a creator's plans are collected by one key, and the chain allows one session per key.\n\n")
	b.WriteString("### Stop a mandate\n\n")
	b.WriteString("Do both, with your own key. Your page (`" + link("payer/YOUR_ADDRESS") + "`) shows them filled in.\n\n")
	b.WriteString("```\ngnokey maketx session revoke -pubkey COLLECTOR_GPUB " + callGas + " " + netFlags() + " YOUR_KEY\n")
	b.WriteString("gnokey maketx call -pkgpath " + realmPath + " -func Cancel -args YOUR_ADDRESS -args COLLECTOR_ADDRESS " + callGas + " " + netFlags() + " YOUR_KEY\n```\n\n")

	b.WriteString("## Checking a supporter (free)\n\n")
	b.WriteString("To decide whether to deliver something to a supporter, ask how long their latest payment covers them: `PaidThrough` returns a unix time (0 if they never paid); deliver while now is before it. Paid time stays the supporter's after a cancel or an expiry. ")
	b.WriteString("Do not rely on a mandate merely existing: anyone can record one without paying. A realm cannot see a session revoked on chain either, but a revoked supporter stops paying, so `PaidThrough` stops moving and runs out within one period. It runs out at the due time and moves on only when the creator's collector takes the next payment, so allow a grace equal to how often the collector runs (an hour, say) before treating someone as lapsed. The second query shows the chain's view of the session.\n\n")
	b.WriteString("```\ngnokey query vm/qeval -data '" + realmPath + ".PaidThrough(address(\"PAYER\"), PLAN_ID)' -remote " + Remote + "\n")
	b.WriteString("gnokey query auth/accounts/PAYER/session/COLLECTOR_ADDRESS -remote " + Remote + "\n```\n\n")

	b.WriteString("## Rules the realm enforces\n\n")
	b.WriteString("- Pull: signed with a session key as a direct call; the session allows exactly this realm; a recorded, active mandate for that payer and key; exactly the price in ugnot; at most once per period (the next one is due one period after the last); not after the expiry.\n")
	b.WriteString("- Every other function refuses session keys and coins.\n")
	b.WriteString("- The first payment can be pulled as soon as the mandate is recorded (billing in advance). A missed period is never collected later.\n")
	b.WriteString("- A wallet can have at most " + strconv.Itoa(MaxSessionsPerWallet) + " sessions, so at most " + strconv.Itoa(MaxSessionsPerWallet) + " mandates at a time.\n")
	return b.String()
}

func renderNotFound() string {
	return "# Not found\n\nThere is no such page. [Back to Mandate](" + link("") + ")\n"
}

// payingText is the plan headline's count of payments per period. It
// counts payments, not distinct people: a creator paying its own plan from
// a second wallet counts too.
func payingText(p *Plan, now int64) string {
	current, previous := p.paidWindows(now)
	start := now / p.Period * p.Period
	return plural(current, "payment", "payments") + " in the current period (since " + formatTime(start) + "), " +
		strconv.Itoa(previous) + " in the one before"
}

// payingCell is the count in tables: paid this period / the one before.
func payingCell(p *Plan, now int64) string {
	current, previous := p.paidWindows(now)
	return strconv.Itoa(current) + " / " + strconv.Itoa(previous)
}

func infoPayingCell(p PlanInfo) string {
	return strconv.Itoa(p.PaidThisPeriod) + " / " + strconv.Itoa(p.PaidLastPeriod)
}

// intParam returns the integer value of key in the query, or def.
func intParam(query, key string, def int) int {
	for _, kv := range strings.Split(query, "&") {
		if strings.HasPrefix(kv, key+"=") {
			n, err := strconv.Atoi(kv[len(key)+1:])
			if err == nil && n >= 0 && n <= 1_000_000_000 {
				return n
			}
		}
	}
	return def
}

// link returns the gnoweb link to a page of this realm.
func link(page string) string {
	p := strings.TrimPrefix(realmPath, "gno.land")
	if page == "" {
		return p
	}
	return p + ":" + page
}

func pager(page string, n int, more bool) string {
	s := ""
	if n > 1 {
		s += "[Previous page](" + link(page) + "?page=" + strconv.Itoa(n-1) + ") "
	}
	if more {
		s += "[Next page](" + link(page) + "?page=" + strconv.Itoa(n+1) + ")"
	}
	if s == "" {
		return ""
	}
	return s + "\n\n"
}

func pageParam(query string) int {
	for _, kv := range strings.Split(query, "&") {
		if strings.HasPrefix(kv, "page=") {
			n, err := strconv.Atoi(kv[5:])
			if err == nil && n >= 1 && n <= 1_000_000 {
				return n
			}
		}
	}
	return 1
}

func plural(n int, one, many string) string {
	if n == 1 {
		return "1 " + one
	}
	return strconv.Itoa(n) + " " + many
}

func netFlags() string {
	return "-broadcast -chainid " + ChainID + " -remote " + Remote
}

func price(amount, period int64) string {
	return formatUgnot(amount) + " every " + formatPeriod(period)
}

// formatUgnot shows an amount in GNOT with up to six decimals.
func formatUgnot(n int64) string {
	whole := n / 1_000_000
	frac := n % 1_000_000
	s := itoa(whole)
	if frac != 0 {
		f := strconv.FormatInt(frac+1_000_000, 10)[1:]
		s += "." + strings.TrimRight(f, "0")
	}
	return s + " GNOT"
}

// formatPeriod shows a number of seconds in the largest exact unit.
func formatPeriod(sec int64) string {
	unit := func(n int64, one, many string) string {
		if n == 1 {
			return one
		}
		return itoa(n) + " " + many
	}
	switch {
	case sec%604800 == 0:
		return unit(sec/604800, "week", "weeks")
	case sec%86400 == 0:
		return unit(sec/86400, "day", "days")
	case sec%3600 == 0:
		return unit(sec/3600, "hour", "hours")
	case sec%60 == 0:
		return unit(sec/60, "minute", "minutes")
	}
	return unit(sec, "second", "seconds")
}

func formatTime(unix int64) string {
	return time.Unix(unix, 0).UTC().Format("2006-01-02 15:04 UTC")
}

func formatTimeOrNever(unix int64) string {
	if unix == 0 {
		return "never"
	}
	return formatTime(unix)
}

func short(a address) string {
	s := a.String()
	if len(s) < 14 {
		return s
	}
	return s[:8] + "…" + s[len(s)-4:]
}
