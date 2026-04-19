package poker

import (
	"strings"

	"gno.land/p/demo/poker"
)

// Render displays the poker realm state as Markdown
func Render(path string) string {
	var sb strings.Builder

	if path == "" || path == "/" {
		renderLobby(&sb)
	} else if strings.HasPrefix(path, "table/") {
		tableID := path[6:]
		renderTable(&sb, tableID)
	} else {
		sb.WriteString("# 🃏 GnoPoker\n\n")
		sb.WriteString("Unknown path: " + path + "\n\n")
		sb.WriteString("[Back to Lobby](/r/demo/poker)\n")
	}

	return sb.String()
}

func renderLobby(sb *strings.Builder) {
	sb.WriteString("# 🃏 GnoPoker — Decentralized Texas Hold'em\n\n")
	sb.WriteString("Play poker on gno.land blockchain. Provably fair, GNOT-powered.\n\n")
	sb.WriteString("---\n\n")

	totalPlayers := 0
	totalPot := int64(0)
	for _, id := range tableList {
		t := tables[id]
		totalPlayers += len(t.Players)
		totalPot += t.Pot
	}

	sb.WriteString("## 📊 Platform Stats\n\n")
	sb.WriteString("| Metric | Value |\n")
	sb.WriteString("|--------|-------|\n")
	sb.WriteString("| Tables | " + poker.IntToStr(len(tableList)) + " |\n")
	sb.WriteString("| Players | " + poker.IntToStr(totalPlayers) + " |\n")
	sb.WriteString("| Total Pot | " + int64ToStr(totalPot/1_000_000) + " GNOT |\n")
	sb.WriteString("| Rake | " + int64ToStr(rakePercent/100) + "." + int64ToStr(rakePercent%100) + "% |\n\n")

	sb.WriteString("## 🎰 Active Tables\n\n")
	sb.WriteString("| Name | Players | Blinds | Pot | Status |\n")
	sb.WriteString("|------|---------|--------|-----|--------|\n")

	for _, id := range tableList {
		t := tables[id]
		sb.WriteString("| [" + t.Name + "](/r/demo/poker:table/" + t.ID + ")")
		sb.WriteString(" | " + poker.IntToStr(len(t.Players)) + "/" + poker.IntToStr(t.MaxPlayers))
		sb.WriteString(" | " + int64ToStr(t.SmallBlind/1_000_000) + "/" + int64ToStr(t.BigBlind/1_000_000) + " GNOT")
		sb.WriteString(" | " + int64ToStr(t.Pot/1_000_000) + " GNOT")
		sb.WriteString(" | " + t.State.String() + " |\n")
	}

	sb.WriteString("\n---\n\n")
	sb.WriteString("*Connect your [Adena Wallet](https://adena.app) and join a table!*\n")
}

func renderTable(sb *strings.Builder, tableID string) {
	table, ok := tables[tableID]
	if !ok {
		sb.WriteString("# ❌ Table Not Found\n\n")
		sb.WriteString("Table `" + tableID + "` does not exist.\n\n")
		sb.WriteString("[Back to Lobby](/r/demo/poker)\n")
		return
	}

	sb.WriteString("# 🃏 " + table.Name + "\n\n")
	sb.WriteString("**" + poker.IntToStr(table.MaxPlayers) + "-Max** | ")
	sb.WriteString("State: **" + table.State.String() + "** | ")
	sb.WriteString("Pot: **" + int64ToStr(table.Pot/1_000_000) + " GNOT**\n\n")

	sb.WriteString("## 👥 Players\n\n")
	sb.WriteString("| Seat | Address | Chips | Status |\n")
	sb.WriteString("|------|---------|-------|--------|\n")

	for i, p := range table.Players {
		status := "Active"
		if p.HasFolded {
			status = "Folded"
		} else if p.IsAllIn {
			status = "All-In"
		}
		if i == table.CurrentTurn && table.State != poker.StateWaiting {
			status += " ◀"
		}

		addr := p.Address
		shortAddr := addr[:8] + "..." + addr[len(addr)-4:]

		sb.WriteString("| " + poker.IntToStr(i+1))
		sb.WriteString(" | " + shortAddr)
		sb.WriteString(" | " + int64ToStr(p.Chips/1_000_000) + " GNOT")
		sb.WriteString(" | " + status + " |\n")
	}

	if len(table.Community) > 0 {
		sb.WriteString("\n## 🂠 Community Cards\n\n")
		for _, c := range table.Community {
			sb.WriteString(poker.CardString(c) + " ")
		}
		sb.WriteString("\n")
	}

	sb.WriteString("\n---\n\n")
	sb.WriteString("[← Back to Lobby](/r/demo/poker)\n")
}
