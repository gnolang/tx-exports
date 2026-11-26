package pot

import (
	"chain/runtime"
	"strconv"
	"strings"

	"gno.land/p/g1pqtgghwrs33pxfl492yruc6l6x83hpr5lf46kr/cellar/formula/v1"
	"gno.land/p/nt/markdown/sanitize/v0"
)

// Render lists the pots, or shows one by its number.
func Render(p string) string {
	if p == "" {
		return renderAll()
	}
	number, err := strconv.Atoi(p)
	if err != nil || !pots.Has(strconv.Itoa(number)) {
		return "# No such pot\n\n[All pots](" + link("") + ")\n"
	}
	return renderPot(number)
}

func link(p string) string {
	s := strings.TrimPrefix(path, runtime.ChainDomain())
	if p != "" {
		s += ":" + p
	}
	return s
}

// sheetLink links to a page of the sheet. The cellar is this realm's parent.
func sheetLink(name string) string {
	return strings.Replace(link(""), "/cellar/pot/", "/cellar/", 1) + ":" + name
}

func gnot(ugnot int64) string {
	return formula.Num(ugnot).String() + " GNOT"
}

func renderAll() string {
	out := `# Pots

A pot pays out GNOT the way a [Cellar](` + sheetLink("") + `) sheet says. The payees, the
shares and the condition are locked cells, so the rule cannot change once money
is in.

| Pot | Sheet | Holds | Paid out |
|:--|:--|--:|--:|
`
	for i := pots.Size(); i > 0 && i > pots.Size()-30; i-- {
		p := mustPot(i)
		out += "| [Pot " + strconv.Itoa(i) + "](" + link(strconv.Itoa(i)) + ") | [" + p.sheet + "](" +
			sheetLink(p.sheet) + ") | " + gnot(balance(i)) + " | " + gnot(p.paid) + " |\n"
	}
	return out + `
## Open a pot

<gno-form exec="Open">
<gno-input name="sheet" placeholder="sheet" required="true" />
<gno-input name="payees" placeholder="locked area of addresses, such as G2:G5" required="true" />
<gno-input name="shares" placeholder="locked area of shares, such as F2:F5" required="true" />
<gno-input name="ready" placeholder="locked cell that becomes TRUE, such as H1" required="true" />
<gno-input name="deadline" type="number" placeholder="block after which a refund is possible" description="Now at block ` + strconv.FormatInt(runtime.ChainHeight(), 10) + `" required="true" />
</gno-form>
`
}

func renderPot(number int) string {
	p := mustPot(number)
	total := balance(number)
	plan, problem := p.plan(total)
	n := strconv.Itoa(number)

	out := "# Pot " + n + ": " + gnot(total) + "\n\n" +
		"Pays by sheet [" + p.sheet + "](" + sheetLink(p.sheet) + "): payees " + p.payees +
		", shares " + p.shares + ", ready when " + p.ready + " is TRUE. [Who may write there](" +
		sheetLink(p.sheet+"/rules") + ").\n\n" +
		"To add money, send GNOT to this address:\n\n" +
		sanitize.CodeBlock(Address(number).String()) + "\n"

	switch {
	case problem != "":
		out += "> [!WARNING]\n> Not payable now: " + sanitize.InlineText(problem) + ".\n\n"
		if runtime.ChainHeight() > p.deadline {
			out += `<gno-button href="` + link("") + "$help&func=Refund&number=" + n + `" label="Refund" variant="warning" />` + "\n\n"
		}
	default:
		out += "| Payee | Share | Would get |\n|:--|--:|--:|\n"
		sum := int64(0)
		for _, x := range plan {
			sum += x.amount
			out += "| " + sanitize.TableCell(x.to.String()) + " | " + x.share.String() + " | " + gnot(x.amount) + " |\n"
		}
		out += "\n"
		if sum > 0 {
			out += `<gno-button href="` + link("") + "$help&func=Settle&number=" + n + `" label="Settle" variant="success" />` + "\n\n"
		}
	}
	return out + "Paid out so far: " + gnot(p.paid) + ". Refund possible after block " +
		strconv.FormatInt(p.deadline, 10) + " if the sheet is not ready by then.\n\n[All pots](" + link("") + ")\n"
}
