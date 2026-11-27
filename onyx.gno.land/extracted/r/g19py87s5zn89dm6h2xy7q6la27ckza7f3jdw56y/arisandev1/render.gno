package arisandev1

import (
	"chain/runtime"
	"chain/runtime/unsafe"
	"strconv"
	"strings"
	"time"

	"gno.land/p/g19py87s5zn89dm6h2xy7q6la27ckza7f3jdw56y/arisan"
	"gno.land/p/moul/txlink/v0"
	"gno.land/p/nt/ufmt/v0"
)

// Render serves the gnoweb UI.
//
//	""                 home: stats, open / running / finished circles
//	"circle/{id}"      one circle: wheel, actions, members, history, debts
//	"member/{address}" a member's reputation and circles
//	"new"              form to start a circle
//	"how"              how arisan and ArisanKu work (EN + ID)
func Render(path string) string {
	path = strings.Trim(path, "/")
	if i := strings.IndexByte(path, '?'); i >= 0 {
		path = path[:i]
	}
	parts := strings.Split(path, "/")
	switch {
	case path == "":
		return renderHome()
	case parts[0] == "circle" && len(parts) == 2:
		id, err := strconv.Atoi(parts[1])
		if err != nil {
			return renderNotFound()
		}
		return renderCircle(id)
	case parts[0] == "member" && len(parts) == 2:
		return renderMember(address(parts[1]))
	case path == "new":
		return renderNew()
	case path == "how":
		return renderHow()
	}
	return renderNotFound()
}

func realmPath() string {
	return strings.TrimPrefix(unsafe.CurrentRealm().PkgPath(), runtime.ChainDomain())
}

func link(sub string) string {
	if sub == "" {
		return realmPath()
	}
	return realmPath() + ":" + sub
}

func header(b *strings.Builder) {
	b.WriteString("# 🫙 ArisanKu\n")
	b.WriteString("*Arisan tanpa bandar — trustless rotating savings circles on Gno.land*\n\n")
	b.WriteString("[Home](" + link("") + ") · [Start a circle](" + link("new") + ") · [How it works](" + link("how") + ")\n\n")
}

func renderHome() string {
	var b strings.Builder
	header(&b)

	var open, running, done []*Circle
	members := 0
	circles.ReverseIterate("", "", func(_ string, v any) bool {
		c := v.(*Circle)
		switch c.Status {
		case StatusOpen:
			open = append(open, c)
		case StatusRunning:
			running = append(running, c)
		case StatusFinished:
			done = append(done, c)
		}
		if c.Status != StatusCancelled {
			members += len(c.Members)
		}
		return false
	})

	b.WriteString("<gno-columns>\n")
	stat(&b, strconv.Itoa(nextCircleID), "circles created")
	b.WriteString("<gno-columns-sep>\n")
	stat(&b, strconv.Itoa(reps.Size()), "unique members")
	b.WriteString("<gno-columns-sep>\n")
	stat(&b, strconv.Itoa(totalRounds), "rounds decided")
	b.WriteString("<gno-columns-sep>\n")
	stat(&b, arisan.FormatGNOT(totalPaidOut), "paid to winners")
	b.WriteString("</gno-columns>\n\n")

	b.WriteString("> [!TIP] What is arisan?\n")
	b.WriteString("> A group agrees on a fixed contribution. Every round everyone pays in and one member takes the whole pot home, until each member has won once. Here the realm holds the pot, picks the winner by a public rule and pays out instantly — no organiser to trust.\n\n")
	b.WriteString(`<gno-button href="` + link("new") + `" label="Start a circle" variant="success" /> <gno-button href="` + link("how") + `" label="How it works" variant="outline" />` + "\n\n")

	b.WriteString("## 🟢 Open circles — join now\n\n")
	if len(open) == 0 {
		b.WriteString("*No circle is recruiting right now. [Start one](" + link("new") + ").*\n\n")
	} else {
		b.WriteString("| Circle | Iuran / round | Mode | Seats | |\n|---|---|---|---|---|\n")
		for _, c := range open {
			b.WriteString(ufmt.Sprintf("| [%s](%s) | %s | %s | %s %d/%d | [Join](%s) |\n",
				c.Name, link("circle/"+strconv.Itoa(c.ID)), arisan.FormatGNOT(c.Contribution), c.Mode.Label(),
				arisan.ProgressBar(len(c.Members), c.Size, 6), len(c.Members), c.Size,
				txlink.NewLink("Join").AddArgs("circleID", strconv.Itoa(c.ID), "nickname", "").URL()))
		}
		b.WriteString("\n")
	}

	b.WriteString("## 🔄 Running circles\n\n")
	if len(running) == 0 {
		b.WriteString("*None yet.*\n\n")
	} else {
		b.WriteString("| Circle | Pot | Round | Paid this round | Deadline |\n|---|---|---|---|---|\n")
		for _, c := range running {
			b.WriteString(ufmt.Sprintf("| [%s](%s) | %s | %d / %d | %s %d/%d | %s |\n",
				c.Name, link("circle/"+strconv.Itoa(c.ID)), arisan.FormatGNOT(c.Contribution*int64(len(c.Members))),
				c.Round, len(c.Members), arisan.ProgressBar(c.paidCount(), len(c.Members), 6), c.paidCount(), len(c.Members), relTime(c.Deadline)))
		}
		b.WriteString("\n")
	}

	if len(done) > 0 {
		b.WriteString("## 🏁 Finished circles\n\n")
		b.WriteString("| Circle | Members | Total paid out |\n|---|---|---|\n")
		for _, c := range done {
			var sum int64
			for _, h := range c.History {
				if !h.Refunded {
					sum += h.Pot
				}
			}
			b.WriteString(ufmt.Sprintf("| [%s](%s) | %d | %s |\n", c.Name, link("circle/"+strconv.Itoa(c.ID)), len(c.Members), arisan.FormatGNOT(sum)))
		}
		b.WriteString("\n")
	}

	footer(&b)
	return b.String()
}

func stat(b *strings.Builder, value, label string) {
	b.WriteString("<gno-frame>\n\n### " + value + "\n" + label + "\n\n</gno-frame>\n")
}

func renderCircle(id int) string {
	c := getCircle(id)
	if c == nil {
		return renderNotFound()
	}
	var b strings.Builder
	header(&b)
	idS := strconv.Itoa(c.ID)
	pot := c.Contribution * int64(len(c.Members))
	if c.Status == StatusOpen {
		pot = c.Contribution * int64(c.Size)
	}

	b.WriteString("## " + c.Name + "  " + statusBadge(c.Status) + "\n\n")

	// wheel + facts side by side
	slots := make([]arisan.Slot, 0, len(c.Members))
	var lastWinner address
	if n := len(c.History); n > 0 {
		lastWinner = c.History[n-1].Winner
	}
	for i, m := range c.Members {
		st := arisan.SlotWaiting
		switch {
		case m.OpenDebts > 0:
			st = arisan.SlotLate
		case m.Addr == lastWinner && m.WonRound > 0:
			st = arisan.SlotWinner
		case m.WonRound > 0:
			st = arisan.SlotWon
		case m.Paid:
			st = arisan.SlotPaid
		}
		slots = append(slots, arisan.Slot{Label: strconv.Itoa(i + 1), Caption: displayName(m), State: st})
	}
	sub := "recruiting " + strconv.Itoa(len(c.Members)) + "/" + strconv.Itoa(c.Size)
	switch c.Status {
	case StatusRunning:
		sub = "Putaran " + strconv.Itoa(c.Round) + " / " + strconv.Itoa(len(c.Members))
	case StatusFinished:
		sub = "selesai · finished"
	case StatusCancelled:
		sub = "cancelled"
	}

	b.WriteString("<gno-columns>\n")
	b.WriteString(arisan.WheelImage("Arisan wheel of "+c.Name, slots, arisan.FormatGNOT(pot), sub) + "\n")
	b.WriteString("<gno-columns-sep>\n\n")
	b.WriteString("| | |\n|---|---|\n")
	b.WriteString("| **Iuran** (per member, per round) | " + arisan.FormatGNOT(c.Contribution) + " |\n")
	b.WriteString("| **Pot** (paid to each winner) | " + arisan.FormatGNOT(pot) + " |\n")
	b.WriteString("| **Mode** | " + c.Mode.Label() + " |\n")
	b.WriteString("| **Members** | " + strconv.Itoa(len(c.Members)) + " / " + strconv.Itoa(c.Size) + " |\n")
	b.WriteString("| **Round length** | " + durStr(c.Period) + " |\n")
	if c.Status == StatusRunning {
		b.WriteString("| **Round** | " + strconv.Itoa(c.Round) + " of " + strconv.Itoa(len(c.Members)) + " |\n")
		b.WriteString("| **Paid this round** | " + arisan.ProgressBar(c.paidCount(), len(c.Members), 8) + " " + strconv.Itoa(c.paidCount()) + "/" + strconv.Itoa(len(c.Members)) + " |\n")
		b.WriteString("| **Held in realm** | " + arisan.FormatGNOT(c.Held) + " |\n")
		b.WriteString("| **Deadline** | " + c.Deadline.UTC().Format("02 Jan 2006 15:04 UTC") + " (" + relTime(c.Deadline) + ") |\n")
	}
	b.WriteString("| **Created by** | " + addrLink(c.Creator) + " |\n")
	b.WriteString("\n</gno-columns>\n\n")

	// actions
	b.WriteString("### Actions\n\n")
	switch c.Status {
	case StatusOpen:
		b.WriteString(`<gno-button href="` + txlink.NewLink("Join").AddArgs("circleID", idS, "nickname", "").URL() + `" label="Join this circle" variant="success" />`)
		if len(c.Members) >= MinMembers {
			b.WriteString(` <gno-button href="` + txlink.NewLink("Start").AddArgs("circleID", idS).URL() + `" label="Start now (creator)" variant="outline" />`)
		}
		b.WriteString(` <gno-button href="` + txlink.NewLink("Cancel").AddArgs("circleID", idS).URL() + `" label="Cancel (creator)" variant="caution outline" />` + "\n\n")
		b.WriteString("*The circle starts by itself when the last seat is taken. Share this page to invite friends.*\n\n")
	case StatusRunning:
		send := strconv.FormatInt(c.Contribution, 10) + denom
		b.WriteString(`<gno-button href="` + txlink.NewLink("Pay").AddArgs("circleID", idS).SetSend(send).URL() + `" label="Pay ` + arisan.FormatGNOT(c.Contribution) + `" variant="success" />`)
		ready := c.allPaid() || time.Now().After(c.Deadline)
		if ready {
			b.WriteString(` <gno-button href="` + txlink.NewLink("Draw").AddArgs("circleID", idS).URL() + `" label="🎲 Draw round ` + strconv.Itoa(c.Round) + `" variant="warning" />` + "\n\n")
			b.WriteString("> [!SUCCESS] Ready to draw\n> " + readyReason(c) + " Anyone can call **Draw** to decide the round and pay the winner.\n\n")
		} else {
			b.WriteString("\n\n> [!NOTE] Waiting for payments\n> " + strconv.Itoa(len(c.Members)-c.paidCount()) + " member(s) still need to pay. Draw opens when everyone has paid or at the deadline (" + relTime(c.Deadline) + ").\n\n")
		}
	case StatusFinished:
		b.WriteString("> [!SUCCESS] Arisan complete\n> Every member received the pot once. Terima kasih semuanya!\n\n")
	case StatusCancelled:
		b.WriteString("> [!CAUTION] This circle was cancelled before it started. No funds were held.\n\n")
	}

	// members
	b.WriteString("### Members\n\n| # | Member | Trust | This round | Won |\n|---|---|---|---|---|\n")
	for i, m := range c.Members {
		paid := "⏳ unpaid"
		if c.Status != StatusRunning {
			paid = "—"
		} else if m.Paid {
			paid = "✅ paid"
		}
		won := "—"
		if m.WonRound > 0 {
			won = "🏆 round " + strconv.Itoa(m.WonRound)
		}
		if m.OpenDebts > 0 {
			won += " · ⚠️ " + strconv.Itoa(m.OpenDebts) + " debt"
		}
		b.WriteString(ufmt.Sprintf("| %d | %s | %s | %s | %s |\n", i+1, memberCell(m), trustCell(m.Addr), paid, won))
	}
	b.WriteString("\n")

	// history
	if len(c.History) > 0 {
		b.WriteString("### Round history\n\n| Round | Winner | Pot | Paid | Missed | Block |\n|---|---|---|---|---|---|\n")
		for i := len(c.History) - 1; i >= 0; i-- {
			h := c.History[i]
			winner := "↩️ rolled over, payers refunded"
			if !h.Refunded {
				winner = "🏆 " + nameOf(c, h.Winner)
			}
			missed := "—"
			if len(h.Missed) > 0 {
				names := make([]string, 0, len(h.Missed))
				for _, a := range h.Missed {
					names = append(names, nameOf(c, a))
				}
				missed = strings.Join(names, ", ")
			}
			b.WriteString(ufmt.Sprintf("| %d | %s | %s | %d/%d | %s | #%d |\n", h.Round, winner, arisan.FormatGNOT(h.Pot), h.Payers, len(c.Members), missed, h.Height))
		}
		b.WriteString("\n")
	}

	// debts
	var rows []string
	debts.Iterate("", "", func(_ string, v any) bool {
		d := v.(*Debt)
		if d.CircleID != c.ID {
			return false
		}
		state := `<gno-button href="` + txlink.NewLink("PayDebt").AddArgs("debtID", strconv.Itoa(d.ID)).SetSend(strconv.FormatInt(d.Amount, 10)+denom).URL() + `" label="Settle" variant="warning outline" />`
		if d.Settled {
			state = "✅ settled"
		}
		rows = append(rows, ufmt.Sprintf("| %d | %d | %s | %s | %s | %s |", d.ID, d.Round, nameOf(c, d.Debtor), nameOf(c, d.Creditor), arisan.FormatGNOT(d.Amount), state))
		return false
	})
	if len(rows) > 0 {
		b.WriteString("### Utang (debts)\n\nA missed payment is owed directly to the winner of that round. Members with open debts cannot win until they settle.\n\n")
		b.WriteString("| Debt | Round | Debtor | Owed to | Amount | |\n|---|---|---|---|---|---|\n")
		b.WriteString(strings.Join(rows, "\n") + "\n\n")
	}

	if c.Mode == arisan.ModeKocok {
		b.WriteString("> [!NOTE]- How the kocok draw works\n> Every join and payment is folded into a SHA-256 seed together with its block height and time; the draw adds its own height and time. The winner is `candidates[seed mod n]` among members who paid, have not won and have no debt. It is auditable and nobody controls it alone, but it is not a VRF: for high stakes use Giliran mode.\n\n")
	}
	b.WriteString("*Machine-readable: `CircleJSON(" + idS + ")`*\n\n")
	footer(&b)
	return b.String()
}

func readyReason(c *Circle) string {
	if c.allPaid() {
		return "Everyone has paid."
	}
	return "The deadline has passed; unpaid members will owe the winner."
}

func renderMember(a address) string {
	var b strings.Builder
	header(&b)
	if !a.IsValid() {
		b.WriteString("Invalid address.\n")
		return b.String()
	}
	b.WriteString("## 👤 " + arisan.ShortAddr(a.String()) + "\n\n`" + a.String() + "`\n\n")
	var r Reputation
	if v := reps.Get(a.String()); v != nil {
		r = *(v.(*Reputation))
	}
	score := TrustScore(a)
	b.WriteString("<gno-columns>\n")
	stat(&b, strconv.Itoa(score)+"/100", "trust score · skor amanah")
	b.WriteString("<gno-columns-sep>\n")
	stat(&b, strconv.Itoa(r.OnTime)+" / "+strconv.Itoa(r.Late)+" / "+strconv.Itoa(r.Missed), "on time / late / missed")
	b.WriteString("<gno-columns-sep>\n")
	stat(&b, strconv.Itoa(r.Wins), "pots received")
	b.WriteString("</gno-columns>\n\n")
	b.WriteString("| | |\n|---|---|\n")
	b.WriteString("| Circles joined | " + strconv.Itoa(r.Circles) + " |\n")
	b.WriteString("| Debts settled | " + strconv.Itoa(r.Settled) + " |\n")
	b.WriteString("| Contributed | " + arisan.FormatGNOT(r.Contributed) + " |\n")
	b.WriteString("| Received | " + arisan.FormatGNOT(r.Received) + " |\n\n")
	b.WriteString("*Score: starts at 50; +5 per on-time payment, +2 per late payment, +4 per settled debt, −15 per missed round (0–100).*\n\n")

	if v := memberships.Get(a.String()); v != nil {
		ids := v.([]int)
		if len(ids) > 0 {
			b.WriteString("### Circles\n\n| Circle | Status | Iuran |\n|---|---|---|\n")
			for i := len(ids) - 1; i >= 0; i-- {
				if c := getCircle(ids[i]); c != nil {
					b.WriteString("| [" + c.Name + "](" + link("circle/"+strconv.Itoa(c.ID)) + ") | " + statusBadge(c.Status) + " | " + arisan.FormatGNOT(c.Contribution) + " |\n")
				}
			}
			b.WriteString("\n")
		}
	}
	var open []string
	debts.Iterate("", "", func(_ string, v any) bool {
		d := v.(*Debt)
		if d.Debtor == a && !d.Settled {
			open = append(open, ufmt.Sprintf("| %d | [circle %d](%s) | %s | [Settle](%s) |", d.ID, d.CircleID, link("circle/"+strconv.Itoa(d.CircleID)), arisan.FormatGNOT(d.Amount),
				txlink.NewLink("PayDebt").AddArgs("debtID", strconv.Itoa(d.ID)).SetSend(strconv.FormatInt(d.Amount, 10)+denom).URL()))
		}
		return false
	})
	if len(open) > 0 {
		b.WriteString("### Open debts\n\n| Debt | Circle | Amount | |\n|---|---|---|---|\n" + strings.Join(open, "\n") + "\n\n")
	}
	footer(&b)
	return b.String()
}

func renderNew() string {
	var b strings.Builder
	header(&b)
	b.WriteString("## Start a new circle\n\n")
	b.WriteString("You become member #1. The circle starts automatically when every seat is filled (or press **Start** with at least 2 members).\n\n")
	b.WriteString(`<gno-form exec="CreateCircle">
  <gno-input name="name" placeholder="e.g. Arisan Kantor Lt. 3" description="Circle" required="true" />
  <gno-input name="nickname" placeholder="your nickname on the wheel (optional)" />
  <gno-input name="contribution" placeholder="iuran per round in GNOT, e.g. 1 or 0.5" required="true" description="Money" />
  <gno-input name="members" type="number" placeholder="number of members, 2-12 (= number of rounds)" required="true" description="Size and pace" />
  <gno-input name="periodMinutes" type="number" placeholder="round length in minutes (10080 = weekly, 43200 = monthly)" required="true" />
  <gno-select name="mode" value="giliran" description="How is each winner chosen?" selected="true" />
  <gno-select name="mode" value="kocok" />
</gno-form>
`)
	b.WriteString("\n> [!TIP] Modes\n> **giliran** — fixed turns in join order (skipping anyone not eligible). **kocok** — random draw among eligible members, like shaking the name jar.\n\n")
	footer(&b)
	return b.String()
}

func renderHow() string {
	var b strings.Builder
	header(&b)
	b.WriteString(`## How it works

<gno-columns>
<gno-frame>

### 1 · Gather
Create a circle: name, iuran (contribution), size and round length. Friends **Join**. It starts when full.

</gno-frame>
<gno-columns-sep>
<gno-frame>

### 2 · Pay
Each round every member **Pay**s the exact iuran. The realm holds the pot — no bandar (organiser) holds cash.

</gno-frame>
<gno-columns-sep>
<gno-frame>

### 3 · Draw
When all paid (or the deadline passes) anyone calls **Draw**. The winner gets the whole pot in the same transaction.

</gno-frame>
</gno-columns>

### Fair by construction
- **One win per member.** After N rounds each of the N members has received the pot exactly once.
- **Late payers can't stall the group.** After the deadline the round is decided with whoever paid. A missed payment becomes an **utang** (debt) owed straight to that round's winner, visible to all.
- **No free riding.** A member with an open debt can't win until it's settled — anyone (family!) can settle it for them.
- **Nobody eligible?** Every payer is refunded and the round repeats. Funds are never stuck.
- **Portable reputation.** Every payment, late payment, miss and settlement updates a public trust score any circle can check.

### Kenapa arisan? / Why arisan?
Arisan adalah tradisi menabung bersama yang dijalankan jutaan orang Indonesia — di kantor, kampung, dan keluarga. Masalah klasiknya: bandar kabur, catatan hilang, dan yang sudah dapat malas bayar. ArisanKu memindahkan kas dan catatannya ke blockchain: uang dipegang realm, pemenang dipilih aturan publik, dan utang tercatat permanen.

Rotating savings circles (ROSCAs) exist all over the world — *tanda* in Mexico, *hui* in China, *susu* in West Africa, *chit funds* in India. They work on trust; this realm turns that trust into code.

### For developers
- Reusable logic lives in ` + "`p/…/arisan`" + ` (modes, entropy, SVG wheel). Build your own circle realm on it.
- Read state from bots or apps with ` + "`CircleJSON(id)`" + `, ` + "`TrustScore(addr)`" + `, ` + "`CircleCount()`" + `.
- Events: CircleCreated, Joined, Started, Paid, Drawn, DebtRecorded, DebtSettled, RoundRolledOver, Finished.

`)
	footer(&b)
	return b.String()
}

func renderNotFound() string {
	var b strings.Builder
	header(&b)
	b.WriteString("## 404\n\nNothing here. [Back home](" + link("") + ").\n")
	return b.String()
}

func footer(b *strings.Builder) {
	b.WriteString("---\n*ArisanKu · testnet demo, not financial advice · open source (MIT)*\n")
}

func statusBadge(s Status) string {
	switch s {
	case StatusOpen:
		return "🟢 open"
	case StatusRunning:
		return "🔄 running"
	case StatusFinished:
		return "🏁 finished"
	case StatusCancelled:
		return "⛔ cancelled"
	}
	return s.String()
}

func displayName(m *Member) string {
	if m.Nick != "" {
		return m.Nick
	}
	return arisan.ShortAddr(m.Addr.String())
}

func memberCell(m *Member) string {
	if m.Nick != "" {
		return "**" + m.Nick + "** · " + addrLink(m.Addr)
	}
	return addrLink(m.Addr)
}

func nameOf(c *Circle, a address) string {
	if i := c.memberIndex(a); i >= 0 {
		return displayName(c.Members[i])
	}
	return arisan.ShortAddr(a.String())
}

func addrLink(a address) string {
	return "[" + arisan.ShortAddr(a.String()) + "](" + link("member/"+a.String()) + ")"
}

func trustCell(a address) string {
	s := TrustScore(a)
	icon := "🟡"
	if s >= 70 {
		icon = "🟢"
	} else if s < 40 {
		icon = "🔴"
	}
	return icon + " " + strconv.Itoa(s)
}

func durStr(d time.Duration) string {
	mins := int64(d / time.Minute)
	switch {
	case mins%(60*24*7) == 0:
		return plural(mins/(60*24*7), "week")
	case mins%(60*24) == 0:
		return plural(mins/(60*24), "day")
	case mins%60 == 0:
		return plural(mins/60, "hour")
	}
	return plural(mins, "minute")
}

func plural(n int64, unit string) string {
	s := strconv.FormatInt(n, 10) + " " + unit
	if n != 1 {
		s += "s"
	}
	return s
}

func relTime(t time.Time) string {
	d := time.Until(t)
	if d <= 0 {
		return "passed " + short(-d) + " ago"
	}
	return "in " + short(d)
}

func short(d time.Duration) string {
	switch {
	case d < time.Minute:
		return strconv.Itoa(int(d/time.Second)) + "s"
	case d < time.Hour:
		return strconv.Itoa(int(d/time.Minute)) + "m"
	case d < 48*time.Hour:
		return strconv.Itoa(int(d/time.Hour)) + "h " + strconv.Itoa(int((d%time.Hour)/time.Minute)) + "m"
	}
	return strconv.Itoa(int(d/(24*time.Hour))) + " days"
}
