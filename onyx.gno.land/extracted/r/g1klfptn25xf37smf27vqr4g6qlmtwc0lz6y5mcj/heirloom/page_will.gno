package heirloom

import (
	"strconv"
	"strings"

	"gno.land/p/jeronimoalbi/mdform/v0"
	"gno.land/p/nt/ufmt/v0"
)

func renderWill(w *Will) string {
	held, snapshot := w.assets(), w.snapshotAssets()
	listed := held
	if w.isReleased() {
		listed = snapshot
	}
	infos := describeAll(listed)

	var b strings.Builder
	b.WriteString(ufmt.Sprintf("# Will %d of %s\n\n", w.ID, shortAddr(w.Owner)))
	b.WriteString(backLink() + " · " + userLink(w.Owner) + "\n\n")
	b.WriteString(countdownRing(w) + "\n\n")
	b.WriteString(statusTable(w))
	b.WriteString(assetsSection(w, held, infos))
	b.WriteString(heirsSection(w))
	b.WriteString(adminSection(w))
	if w.isReleased() {
		b.WriteString(claimSection(w, snapshot, infos))
	} else {
		b.WriteString(actionsSection(w, held, infos))
	}
	return b.String()
}

func statusTable(w *Will) string {
	label, whenLabel, when := string(w.status()), "Releasable from", formatTimeFrom(w.releaseAt())
	switch w.status() {
	case statusReleased:
		whenLabel, when = "Released on", formatTime(w.ReleasedAt)
	case statusDue:
		label += ": anyone but the owner can release it"
	}
	return "| Status | Last sign of life | Silence period | " + whenLabel + " |\n| :--- | :--- | :--- | :--- |\n" +
		ufmt.Sprintf("| %s | %s | %s | %s |\n\n", label, formatTime(w.LastSeen), formatDuration(w.Silence), when)
}

func assetsSection(w *Will, held []string, infos assetInfos) string {
	if len(held) == 0 {
		return "## Assets\n\nNothing held.\n\n"
	}
	var b strings.Builder
	b.WriteString("## Assets\n\n| Asset | Held |\n| :--- | ---: |\n")
	for _, asset := range held {
		b.WriteString("| " + infos[asset].label + " | " + infos[asset].amount(w.balance(asset)) + " |\n")
	}
	return b.String() + "\n"
}

func heirsSection(w *Will) string {
	var b strings.Builder
	b.WriteString("## Heirs\n\n| Heir | Share |\n| :--- | ---: |\n")
	for _, heir := range w.Heirs {
		b.WriteString(ufmt.Sprintf("| %s | %d%% |\n", userLink(heir.Addr), heir.Percent))
	}
	return b.String() + "\n"
}

func adminSection(w *Will) string {
	outcome, h := adminOutcomeOf(w)
	released := w.isReleased()
	text := ""
	switch {
	case outcome == adminHandedOverHere:
		text = "When this will was released, it handed them to " + userLink(h.To) + "." + nowHeldBy(h.To)
	case outcome == adminHandedOverByAnother:
		text = "Releasing " + willLink(h.WillID) + " handed them to " + userLink(h.To) + "." + nowHeldBy(h.To)
	case outcome == adminNoSuccessor && released:
		text = "No successor was named, so the owner kept them."
	case outcome == adminNoSuccessor:
		text = "No successor: the owner keeps them after release."
	case outcome == adminStaysWithOwner && released:
		text = "The owner kept them: the rights of the successor, " + userLink(w.Successor) + ", already passed to the owner."
	case outcome == adminStaysWithOwner:
		text = "The owner will keep them: the rights of the successor, " + userLink(w.Successor) + ", already pass to the owner."
	default:
		text = "On release, they pass to the successor, " + userLink(w.Successor) + "."
		if holder := holderOf(w.Successor); holder != w.Successor {
			text += " The successor's own rights already passed to " + userLink(holder) + ", so they will end up there."
		}
	}
	return "## Admin rights\n\n" + text + "\n\n"
}

func nowHeldBy(successor address) string {
	if holder := holderOf(successor); holder != successor {
		return " They are now held by " + userLink(holder) + "."
	}
	return ""
}

func claimSection(w *Will, snapshot []string, infos assetInfos) string {
	if len(snapshot) == 0 {
		return "## Claims\n\nNothing to claim.\n\n"
	}
	id := strconv.Itoa(w.ID)
	var b strings.Builder
	b.WriteString("## Claims\n\nAnyone can pay out a share; it always goes to the heir.\n\n")
	b.WriteString("| Heir | Asset | Share | Status |\n| :--- | :--- | ---: | :--- |\n")
	for _, asset := range snapshot {
		for _, h := range w.Heirs {
			share := w.shareOf(h, asset)
			status := "paid"
			switch {
			case share == 0:
				status = "nothing to pay"
			case !h.hasClaimed(asset):
				status = link("pay out", txURL("Claim", 0, "id", id, "heir", h.Addr.String(), "asset", asset))
			}
			b.WriteString("| " + userLink(h.Addr) + " | " + infos[asset].label + " | " + infos[asset].amount(share) + " | " + status + " |\n")
		}
	}
	return b.String() + "\n"
}

func actionsSection(w *Will, held []string, infos assetInfos) string {
	id := strconv.Itoa(w.ID)
	var b strings.Builder
	b.WriteString("## Actions\n\n")
	if w.isDue() {
		b.WriteString("Anyone but the owner: " + link("release the will", txURL("Release", 0, "id", id)) + ". Then anyone can pay out each heir's share.\n\n")
	}
	b.WriteString("### Owner only\n\n")
	b.WriteString(link("I am alive", txURL("Ping", 0, "id", id)) + " · Deposit " +
		link("1 GNOT", txURL("Deposit", 1_000_000, "id", id)) + " · " + link("10 GNOT", txURL("Deposit", 10_000_000, "id", id)) + " · " +
		link("Revoke the will", txURL("Revoke", 0, "id", id)) + "\n\n")

	b.WriteString("Deposit a GRC20 token, in its smallest unit. First approve `" + selfAddr.String() + "` as a spender in the token's realm.\n\n")
	b.WriteString(ownerForm("DepositToken", id).
		Input("token", "placeholder", "gno.land/r/gnoland/wugnot.wugnot", "description", "Token key").
		Input("amount", "type", mdform.InputTypeNumber, "description", "Amount").
		String() + "\n\n")

	if len(held) > 0 {
		var units []string
		form := ownerForm("Withdraw", id)
		for i, asset := range held {
			if note := infos[asset].unitNote(); note != "" {
				units = append(units, note)
			}
			if i == 0 {
				form.Select("asset", asset, "description", "Asset")
			} else {
				form.Select("asset", asset)
			}
		}
		note := ""
		if len(units) > 0 {
			note = " (" + strings.Join(units, ", ") + ")"
		}
		b.WriteString("Withdraw, in the asset's smallest unit" + note + ":\n\n")
		b.WriteString(form.Input("amount", "type", mdform.InputTypeNumber, "description", "Amount").String() + "\n\n")
	}

	b.WriteString("Change heirs:\n\n")
	b.WriteString(ownerForm("SetHeirs", id).Input("heirs", "value", heirList(w), "description", "Heirs").String() + "\n\n")

	if _, done := handoverOf(w.Owner); !done {
		b.WriteString("Successor, who inherits your admin rights; leave empty for nobody:\n\n")
		b.WriteString(ownerForm("SetSuccessor", id).Input("successor", "value", w.Successor.String(), "placeholder", "g1...", "description", "Successor").String() + "\n\n")
	}

	b.WriteString("Change the silence period, in days:\n\n")
	b.WriteString(ownerForm("SetSilence", id).Input("silence", "type", mdform.InputTypeNumber, "value", strconv.Itoa(int(w.Silence/day)), "description", "Silence, in days").String() + "\n")
	return b.String()
}

func ownerForm(fn, id string) *mdform.Form {
	return mdform.New("exec", fn).Input("id", "value", id, "readonly", "true", "description", "Will")
}

func heirList(w *Will) string {
	items := make([]string, len(w.Heirs))
	for i, h := range w.Heirs {
		items[i] = h.Addr.String() + ":" + strconv.Itoa(h.Percent)
	}
	return strings.Join(items, ", ")
}
