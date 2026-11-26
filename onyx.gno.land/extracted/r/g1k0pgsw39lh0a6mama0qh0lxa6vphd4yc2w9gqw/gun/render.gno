package gun

import (
	"chain"
	"chain/banker"
	"strconv"
	"strings"
	"time"

	"gno.land/p/nt/markdown/sanitize/v0"
	"gno.land/p/nt/ufmt/v0"

	"gno.land/p/g1k0pgsw39lh0a6mama0qh0lxa6vphd4yc2w9gqw/rosca"
)

const (
	pkgPath = "gno.land/r/g1k0pgsw39lh0a6mama0qh0lxa6vphd4yc2w9gqw/gun"
	self    = "/r/g1k0pgsw39lh0a6mama0qh0lxa6vphd4yc2w9gqw/gun"
	perPage = 10
)

// Render shows the circles. Paths: "" (home, ?page=N), "c/<id>" (one
// circle), "u/<address>" (one member's circles).
func Render(path string) string {
	route, query := path, ""
	if i := strings.Index(path, "?"); i >= 0 {
		route, query = path[:i], path[i+1:]
	}
	switch {
	case route == "":
		return renderHome(pageParam(query))
	case strings.HasPrefix(route, "c/"):
		id, err := strconv.Atoi(route[2:])
		if err != nil {
			return notFound()
		}
		c, ok := get(id)
		if !ok {
			return notFound()
		}
		return renderCircle(id, c)
	case strings.HasPrefix(route, "u/"):
		a := address(route[2:])
		if !a.IsValid() {
			return notFound()
		}
		return renderMember(a)
	}
	return notFound()
}

func notFound() string {
	return "# Not found\n\n[Back to all circles](" + self + ")\n"
}

func pageParam(query string) int {
	for _, kv := range strings.Split(query, "&") {
		if strings.HasPrefix(kv, "page=") {
			if n, err := strconv.Atoi(kv[5:]); err == nil && n > 0 && n < 1_000_000 {
				return n
			}
		}
	}
	return 1
}

func renderHome(page int) string {
	var b strings.Builder
	b.WriteString("# Gün: savings circles on gno.land\n\n")
	b.WriteString("_Altın günü, on chain._ A group of friends pays the same amount every round, ")
	b.WriteString("and each round the whole pot goes to one of them, in turn, until everyone has had it once. ")
	b.WriteString("It is how millions of people save without a bank: the *altın günü* in Turkey, ")
	b.WriteString("the *tanda* in Mexico, the *susu* in West Africa, the *hui* in China.\n\n")
	b.WriteString("This realm holds the coins and keeps the books in the open, so nobody has to trust the organizer:\n\n")
	b.WriteString("- **Everyone joins on purpose.** The organizer lists the members; each one joins by locking their collateral.\n")
	b.WriteString("- **Collateral covers missed payments.** Each member locks a number of contributions up front. ")
	b.WriteString("With *members − 1* of them the circle is fully secured: every member is guaranteed the full pot.\n")
	b.WriteString("- **Payouts are pulled, not pushed.** Pots, refunds and released collateral are credited, and their owner withdraws them.\n")
	b.WriteString("- **Late is visible.** Every payment is marked on time, late or covered, round by round.\n\n")
	b.WriteString("[Start a circle](" + self + "$help&func=Create) · ")
	b.WriteString("[How the rules work](" + self + "$source)\n\n")

	total := circles.Size()
	b.WriteString("## Circles\n\n")
	if total == 0 {
		b.WriteString("No circles yet.\n\n")
	} else {
		pages := (total + perPage - 1) / perPage
		if page > pages {
			page = pages
		}
		b.WriteString("| # | Name | Members | Contribution | Status |\n|---|---|---|---|---|\n")
		offset := (page - 1) * perPage
		circles.ReverseIterateByOffset(offset, perPage, func(k string, v any) bool {
			c := v.(*rosca.Circle)
			id, _ := strconv.Atoi(strings.TrimLeft(k, "0"))
			b.WriteString(ufmt.Sprintf("| %d | [%s](%s:c/%d) | %d | %s | %s |\n",
				id, sanitize.InlineText(c.Name()), self, id, c.Size(),
				gnot(c.Contribution()), statusLine(c)))
			return false
		})
		if pages > 1 {
			b.WriteString("\n")
			if page > 1 {
				b.WriteString(ufmt.Sprintf("[← newer](%s:?page=%d) ", self, page-1))
			}
			b.WriteString(ufmt.Sprintf("page %d of %d", page, pages))
			if page < pages {
				b.WriteString(ufmt.Sprintf(" [older →](%s:?page=%d)", self, page+1))
			}
			b.WriteString("\n")
		}
	}
	b.WriteString("\n---\n\n")
	bal := banker.NewReadonlyBanker().GetCoin(chain.PackageAddress(pkgPath), denom)
	b.WriteString(ufmt.Sprintf("**Books.** The circles account for %s; the realm holds %s.", gnot(totalHeld), gnot(bal)))
	if bal < totalHeld {
		b.WriteString(" **The realm holds less than it owes. Please report this.**")
	}
	b.WriteString("\n")
	return b.String()
}

func renderCircle(id int, c *rosca.Circle) string {
	var b strings.Builder
	t := now()
	b.WriteString(ufmt.Sprintf("# %s\n\n", sanitize.InlineText(c.Name())))
	b.WriteString(ufmt.Sprintf("Circle #%d · **%s** · organized by %s\n\n", id, statusLine(c), who(c.Organizer())))

	b.WriteString(ufmt.Sprintf("- **Contribution:** %s per member per round\n", gnot(c.Contribution())))
	b.WriteString(ufmt.Sprintf("- **Pot:** %s to one member each round, %d rounds\n", gnot(c.Pot()), c.Size()))
	b.WriteString(ufmt.Sprintf("- **Round length:** %s\n", duration(c.Period())))
	b.WriteString(ufmt.Sprintf("- **Collateral:** %s per member (%d contributions). ", gnot(c.CollateralDue()), c.CollateralRounds()))
	switch {
	case c.FullySecured():
		b.WriteString("Fully secured: every member is guaranteed the full pot.\n")
	case c.CollateralRounds() == 0:
		b.WriteString("None: the circle runs on trust, and the first missed payment ends it.\n")
	default:
		b.WriteString(ufmt.Sprintf("Covers %d missed payments per member; one more ends the circle.\n", c.CollateralRounds()))
	}

	switch c.Status() {
	case rosca.Forming:
		b.WriteString(ufmt.Sprintf("- **Join by:** %s (%s)\n", when(c.JoinBy()), relative(c.JoinBy(), t)))
	case rosca.Active:
		due := c.DueAt()
		b.WriteString(ufmt.Sprintf("- **Round %d of %d** is due %s (%s). Recipient: %s\n",
			c.Round()+1, c.Size(), when(due), relative(due, t), who(c.Recipient(c.Round()))))
	default:
		b.WriteString(ufmt.Sprintf("- **Ended:** %s", when(c.EndedAt())))
		if c.Note() != "" {
			b.WriteString(" · " + c.Note())
		}
		b.WriteString("\n")
	}

	// Members, in turn order. Amounts in GNOT; columns that say nothing in
	// the current status are left out to keep the table readable.
	forming, active := c.Status() == rosca.Forming, c.Status() == rosca.Active
	b.WriteString("\n## Members\n\nAmounts in GNOT.\n\n| Turn | Member |")
	if forming {
		b.WriteString(" Joined |")
	}
	if active {
		b.WriteString(" This round |")
	}
	b.WriteString(" Paid in | Received | Locked | To withdraw |\n|---|---|")
	if forming {
		b.WriteString("---|")
	}
	if active {
		b.WriteString("---|")
	}
	b.WriteString("---|---|---|---|\n")
	for r := 0; r < c.Size(); r++ {
		a := c.Recipient(r)
		m, _ := c.MemberOf(a)
		turn := strconv.Itoa(r + 1)
		if active && r == c.Round() {
			turn = "**" + turn + " ◀**"
		}
		flags := ""
		if m.Defaulted {
			flags = " · defaulted"
		} else if m.Covered > 0 || m.Late > 0 {
			flags = ufmt.Sprintf(" · %d late, %d covered", m.Late, m.Covered)
		}
		b.WriteString(ufmt.Sprintf("| %s | %s%s |", turn, who(a), flags))
		if forming {
			if m.Joined {
				b.WriteString(" yes |")
			} else {
				b.WriteString(" not yet |")
			}
		}
		if active {
			b.WriteString(" " + markText(c.MarkOf(a)) + " |")
		}
		b.WriteString(ufmt.Sprintf(" %s | %s | %s | %s |\n",
			num(m.PaidIn), num(m.Received+m.Compensated), num(m.Collateral), num(m.Claimable)))
	}

	b.WriteString("\n## Actions\n\n")
	switch c.Status() {
	case rosca.Forming:
		b.WriteString(ufmt.Sprintf("- [Join](%s$help&func=Join&id=%d&.send=%dugnot): send exactly %s\n",
			self, id, c.CollateralDue(), gnot(c.CollateralDue())))
		b.WriteString(ufmt.Sprintf("- [Cancel](%s$help&func=Cancel&id=%d): organizer any time, anyone after the join window\n", self, id))
	case rosca.Active:
		b.WriteString(ufmt.Sprintf("- [Pay this round](%s$help&func=Pay&id=%d&.send=%dugnot): send exactly %s\n",
			self, id, c.Contribution(), gnot(c.Contribution())))
		if t > c.DueAt() {
			b.WriteString(ufmt.Sprintf("- [Settle](%s$help&func=Settle&id=%d): the round is overdue; anyone can close it\n", self, id))
		} else {
			b.WriteString(ufmt.Sprintf("- Settle: possible after %s\n", when(c.DueAt())))
		}
	}
	if c.Status() == rosca.Forming || c.Status() == rosca.Active {
		b.WriteString(ufmt.Sprintf("- [Propose a turn swap](%s$help&func=ProposeSwap&id=%d) · [accept one](%s$help&func=AcceptSwap&id=%d)\n",
			self, id, self, id))
	}
	b.WriteString(ufmt.Sprintf("- [Withdraw what you are owed](%s$help&func=Withdraw&id=%d)\n", self, id))

	h := c.History()
	if len(h) > 0 {
		b.WriteString("\n## Rounds\n\n")
		b.WriteString("Marks are per member in listed order: **P** on time · **L** late · **C** covered from collateral · **X** missed with no collateral.\n\n")
		b.WriteString("| Round | Recipient | Pot | Closed | Marks |\n|---|---|---|---|---|\n")
		for i, r := range h {
			pot := gnot(r.Pot)
			if r.Pot == 0 {
				pot = "not formed"
			}
			b.WriteString(ufmt.Sprintf("| %d | %s | %s | %s | `%s` |\n", i+1, who(r.Recipient), pot, when(r.ClosedAt), r.Marks))
		}
	}
	b.WriteString("\n[All circles](" + self + ")\n")
	return b.String()
}

func renderMember(a address) string {
	var b strings.Builder
	b.WriteString("# Circles of " + short(a) + "\n\n")
	v := byMember.Get(a.String())
	if v == nil {
		b.WriteString("Not in any circle yet. Circles show up here once you create or join them.\n")
	} else {
		b.WriteString("| # | Name | Status | Your turn | Withdrawable |\n|---|---|---|---|---|\n")
		ids := v.([]int)
		for i := len(ids) - 1; i >= 0; i-- {
			c, ok := get(ids[i])
			if !ok {
				continue
			}
			m, _ := c.MemberOf(a)
			b.WriteString(ufmt.Sprintf("| %d | [%s](%s:c/%d) | %s | %d of %d | %s |\n",
				ids[i], sanitize.InlineText(c.Name()), self, ids[i], statusLine(c),
				c.TurnOf(a)+1, c.Size(), gnot(m.Claimable)))
		}
	}
	b.WriteString("\n[All circles](" + self + ")\n")
	return b.String()
}

// ---------------------------------------------------------------- format

func statusLine(c *rosca.Circle) string {
	switch c.Status() {
	case rosca.Active:
		return ufmt.Sprintf("round %d of %d", c.Round()+1, c.Size())
	}
	return c.Status().String()
}

func markText(m rosca.Mark) string {
	switch m {
	case rosca.OnTime:
		return "paid"
	case rosca.Late:
		return "paid late"
	case rosca.Covered:
		return "covered"
	case rosca.Missed:
		return "missed"
	}
	return "not yet"
}

func who(a address) string {
	return ufmt.Sprintf("[%s](%s:u/%s)", short(a), self, a.String())
}

func short(a address) string {
	s := a.String()
	if len(s) < 14 {
		return s
	}
	return s[:8] + "…" + s[len(s)-4:]
}

// gnot formats ugnot as GNOT with the unit.
func gnot(u int64) string { return num(u) + " GNOT" }

// num formats ugnot as a GNOT amount, dropping trailing zeros.
func num(u int64) string {
	neg := u < 0
	if neg {
		u = -u
	}
	whole := strconv.FormatInt(u/1_000_000, 10)
	frac := strconv.FormatInt(u%1_000_000, 10)
	for len(frac) < 6 {
		frac = "0" + frac
	}
	frac = strings.TrimRight(frac, "0")
	s := whole
	if frac != "" {
		s += "." + frac
	}
	if neg {
		s = "-" + s
	}
	return s
}

func when(unix int64) string {
	return time.Unix(unix, 0).UTC().Format("2006-01-02 15:04 UTC")
}

func relative(at, t int64) string {
	if at >= t {
		return "in " + duration(at-t)
	}
	return duration(t-at) + " ago"
}

func duration(s int64) string {
	switch {
	case s >= 86400:
		d, h := s/86400, (s%86400)/3600
		if h == 0 {
			return ufmt.Sprintf("%d days", d)
		}
		return ufmt.Sprintf("%dd %dh", d, h)
	case s >= 3600:
		return ufmt.Sprintf("%dh %dm", s/3600, (s%3600)/60)
	case s >= 60:
		return ufmt.Sprintf("%d min", s/60)
	}
	return ufmt.Sprintf("%d s", s)
}
