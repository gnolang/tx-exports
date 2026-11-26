package cellar

import (
	"net/url"
	"strconv"
	"strings"

	"gno.land/p/g1pqtgghwrs33pxfl492yruc6l6x83hpr5lf46kr/cellar/formula/v1"
	"gno.land/p/nt/markdown/sanitize/v0"
)

const (
	pageRows  = 30  // rows of a sheet on one page, at most
	pageCells = 300 // cells of a sheet on one page
	csvRows   = 100 // rows of a sheet on one page as CSV, at most
	csvBytes  = 12000
	pageItems = 20 // sheets on one page of a list
	cellChars = 60 // characters of a cell in a table
)

// Render shows the pages of the realm:
//
//	""                 front page
//	"all"              every sheet
//	"new"              how to open a sheet
//	"help"             the formula language
//	"NAME"             a sheet
//	"NAME/B2"          one cell
//	"NAME/edit"        forms for changing a sheet
//	"NAME/rows"        a sheet row by row, for narrow screens
//	"NAME/formulas"    a sheet with formulas in place of their results
//	"NAME/rules"       who may write where
//	"NAME/csv"         the results as text
func Render(path string) string {
	path, query := splitQuery(path)
	path = strings.Trim(path, "/")
	switch path {
	case "":
		return renderHome()
	case "all":
		return renderAll(number(query, "from", 1))
	case "new":
		return renderNew()
	case "help":
		return renderHelp()
	}
	name, rest := path, ""
	if i := strings.IndexByte(path, '/'); i >= 0 {
		name, rest = path[:i], path[i+1:]
	}
	v := sheets.Get(name)
	if v == nil {
		return "# No such sheet\n\nThere is no sheet called " + sanitize.InlineCode(clip(name, 40)) +
			". See [all sheets](" + link("all") + ").\n"
	}
	s := v.(*sheet)
	switch rest {
	case "":
		return renderSheet(s, number(query, "from", 1), false)
	case "formulas":
		return renderSheet(s, number(query, "from", 1), true)
	case "rows":
		return renderRows(s, number(query, "from", 1))
	case "edit":
		return renderEdit(s)
	case "rules":
		return renderRules(s)
	case "csv":
		return renderCSV(s, number(query, "from", 1))
	}
	col, row, ok := formula.ParseCell(rest)
	if !ok || col > s.cols || row > s.rows {
		return "# No such page\n\nBack to " + s.link() + ".\n"
	}
	return renderCell(s, col, row)
}

func splitQuery(path string) (string, url.Values) {
	i := strings.IndexByte(path, '?')
	if i < 0 {
		return path, nil
	}
	q, err := url.ParseQuery(path[i+1:])
	if err != nil {
		q = nil
	}
	return path[:i], q
}

// number reads a whole number from a query, or returns the fallback.
func number(q url.Values, name string, fallback int) int {
	n, err := strconv.Atoi(q.Get(name))
	if err != nil || n < 1 || n > 100000 {
		return fallback
	}
	return n
}

func link(path string) string { return home + ":" + path }

// link returns a markdown link to the sheet.
func (s *sheet) link() string {
	return "[" + sanitize.InlineText(s.title) + "](" + link(s.name) + ")"
}

// person links to the page of an address.
func person(a address) string {
	s := a.String()
	if len(s) < 16 {
		return sanitize.InlineText(s)
	}
	return "[" + s[:6] + "…" + s[len(s)-4:] + "](/u/" + s + ")"
}

func renderHome() string {
	out := `# Cellar

**Shared sheets with rules nobody can bend.** Say who may write where, lock the
formulas you agreed on, and let the chain do the arithmetic. Score sheets, sign-up
lists, tabs and treasuries that everyone can check and no one can quietly edit.

<gno-columns>
<gno-frame>
**Locked means locked**

Lock a formula and nobody can ever change it, not even the owner.
</gno-frame>
<gno-columns-sep>
<gno-frame>
**Open a column to everyone**

Visitors fill empty cells. What you wrote, nobody else can overwrite.
</gno-frame>
<gno-columns-sep>
<gno-frame>
**Formulas see the chain**

` + "`=BALANCE(\"g1…\")`" + ` is live. Other realms can read your cells.
</gno-frame>
</gno-columns>

`
	out += `<gno-button href="` + link("new") + `" label="Open a sheet" /> <gno-button href="` +
		link("help") + `" label="Formula guide" variant="outline" />` + "\n\n"
	out += "## Latest sheets\n\n" + listSheets(1, 8)
	if order.Size() > 8 {
		out += "\n[All " + strconv.Itoa(order.Size()) + " sheets](" + link("all") + ")\n"
	}
	return out
}

// listSheets shows count sheets, newest first, starting with the from-th.
func listSheets(from, count int) string {
	out := ""
	order.ReverseIterateByOffset(from-1, count, func(_ string, name any) bool {
		s := mustSheet(name.(string))
		out += "- **" + s.link() + "** `" + s.name + "` · " + strconv.Itoa(s.cells.Size()) +
			" cells · by " + person(s.owner) + "\n"
		return false
	})
	if out == "" {
		return "None yet.\n"
	}
	return out
}

func renderAll(from int) string {
	if from > order.Size() {
		from = 1
	}
	out := "# All sheets\n\n" + listSheets(from, pageItems)
	if next := from + pageItems; next <= order.Size() {
		out += "\n[Older sheets](" + link("all?from="+strconv.Itoa(next)) + ")\n"
	}
	return out + "\n[Back](" + home + ")\n"
}

func renderNew() string {
	out := "# Open a sheet\n\n## Ready made\n\n"
	options := ""
	for i, t := range templates() {
		out += "- **" + t.name + "**: " + t.help + "\n"
		options += `<gno-select name="template" value="` + t.name + `"`
		if i == 0 {
			options += ` description="Which one" selected="true"`
		}
		options += " />\n"
	}
	out += "\n" + `<gno-form exec="NewFromTemplate">
` + options + `<gno-input name="name" placeholder="name, such as bakeoff" description="Name: 2 to 24 lower case letters, digits or _. It cannot change later." required="true" />
<gno-input name="title" placeholder="title" description="Title, up to 60 bytes" required="true" />
</gno-form>

`
	return out + "## Empty\n\n" + `<gno-form exec="NewSheet">
<gno-input name="name" placeholder="name, such as trip_costs" description="Name: 2 to 24 lower case letters, digits or _. It cannot change later." required="true" />
<gno-input name="title" placeholder="title" description="Title, up to 60 bytes" required="true" />
<gno-input name="cols" type="number" value="6" placeholder="columns" description="Columns, 1 to 26" />
<gno-input name="rows" type="number" value="20" placeholder="rows" description="Rows, 1 to 200" />
</gno-form>
` + "\nEmpty cells take no storage, so a large sheet costs no more than a small one.\n\n[Back](" + home + ")\n"
}

// renderSheet shows the used part of a sheet.
func renderSheet(s *sheet, from int, formulas bool) string {
	cols, rows := s.used()
	from, last := window(from, rows, tableRows(cols))
	c := newCalc()

	head, align := "| |", "|--:|"
	for col := 1; col <= cols; col++ {
		head += " " + string(rune('A'+col-1)) + " |"
		if !formulas && s.mostlyNumbers(c, col, from, last) {
			align += "--:|"
		} else {
			align += ":--|"
		}
	}
	out := s.heading() + head + "\n" + align + "\n"
	for row := from; row <= last; row++ {
		line := "| **" + strconv.Itoa(row) + "** |"
		for col := 1; col <= cols; col++ {
			line += " " + s.show(c, col, row, formulas) + " |"
		}
		out += line + "\n"
	}
	if formulas {
		return out + "\n" + s.pages("/formulas", cols, from, last, rows) + s.menu()
	}
	out += "\n" + s.pages("", cols, from, last, rows) +
		"Linked values are formulas: follow one to see how it is worked out. On a narrow screen, read the sheet [row by row](" +
		link(s.name+"/rows") + ").\n\n"
	for _, ch := range s.charts {
		out += "### " + sanitize.InlineText(ch.title) + "\n\n" + ch.markdown(s, c) + "\n"
	}
	return out + s.openForms(2) + s.menu()
}

// renderRows shows a sheet as a list, with the first row as labels.
func renderRows(s *sheet, from int) string {
	cols, rows := s.used()
	from, last := window(from, rows, tableRows(cols))
	c := newCalc()
	labels := make([]string, cols+1)
	for col := 1; col <= cols; col++ {
		labels[col] = string(rune('A' + col - 1))
		if v := c.Value(s.name, col, 1); v.Kind() == formula.Text && v.String() != "" {
			labels[col] = sanitize.InlineText(clip(v.String(), 20))
		}
	}
	out := s.heading()
	for row := from; row <= last; row++ {
		line := ""
		for col := 1; col <= cols; col++ {
			txt := s.show(c, col, row, false)
			if txt == "" {
				continue
			}
			if row > 1 {
				txt = labels[col] + ": " + txt
			}
			line += " · " + txt
		}
		if line != "" {
			out += "**" + strconv.Itoa(row) + "**" + line + "\n\n"
		}
	}
	return out + s.pages("/rows", cols, from, last, rows) + s.menu()
}

// heading is the top of a page that shows a sheet.
func (s *sheet) heading() string {
	return "# " + sanitize.InlineText(s.title) + "\n\n" +
		"`" + s.name + "` · " + strconv.Itoa(s.cols) + " × " + strconv.Itoa(s.rows) +
		" · owner " + person(s.owner) + " · last change in block " + strconv.FormatInt(s.changed, 10) + "\n\n"
}

// tableRows returns how many rows go on one page, fewer for a wide sheet.
func tableRows(cols int) int {
	if n := pageCells / cols; n < pageRows {
		return n
	}
	return pageRows
}

// window returns the first and last row of a page that starts at from.
func window(from, rows, size int) (first, last int) {
	if from > rows {
		from = 1
	}
	last = from + size - 1
	if last > rows {
		last = rows
	}
	return from, last
}

// pages links to the rows above and below.
func (s *sheet) pages(view string, cols, from, last, rows int) string {
	out := ""
	if from > 1 {
		prev := from - tableRows(cols)
		if prev < 1 {
			prev = 1
		}
		out += "[Rows above](" + link(s.name+view+"?from="+strconv.Itoa(prev)) + ") "
	}
	if last < rows {
		out += "[Rows below](" + link(s.name+view+"?from="+strconv.Itoa(last+1)) + ")"
	}
	if out == "" {
		return ""
	}
	return out + "\n\n"
}

// menu links the pages of a sheet.
func (s *sheet) menu() string {
	return "[Sheet](" + link(s.name) + ") · [Rows](" + link(s.name+"/rows") + ") · [Edit](" + link(s.name+"/edit") + ") · [Formulas](" +
		link(s.name+"/formulas") + ") · [Rules](" + link(s.name+"/rules") + ") · [CSV](" +
		link(s.name+"/csv") + ") · [Help](" + link("help") + ") · [All sheets](" + home + ")\n"
}

// used returns how many columns and rows to show: up to the last filled cell,
// or a few if there is none.
func (s *sheet) used() (cols, rows int) {
	cols, rows = 4, 5
	s.cells.Iterate("", "", func(k string, _ any) bool {
		if col := int(k[0]-'A') + 1; col > cols {
			cols = col
		}
		if row, _ := strconv.Atoi(k[1:]); row > rows {
			rows = row
		}
		return false
	})
	if cols > s.cols {
		cols = s.cols
	}
	if rows > s.rows {
		rows = s.rows
	}
	return cols, rows
}

// mostlyNumbers decides how to align a column. The first row usually holds
// labels, so it does not count.
func (s *sheet) mostlyNumbers(c *formula.Calc, col, from, last int) bool {
	balance := 0
	s.each(col, from, last, func(row int, _ string) bool {
		switch c.Value(s.name, col, row).Kind() {
		case formula.Number:
			balance++
		case formula.Text:
			if row > 1 {
				balance--
			}
		}
		return false
	})
	return balance > 0
}

// show returns a cell for a table. Results of formulas link to their cell, and
// addresses to their page.
func (s *sheet) show(c *formula.Calc, col, row int, formulas bool) string {
	e := s.get(col, row)
	if e == nil {
		return ""
	}
	isFormula := formula.IsFormula(e.src)
	if formulas && isFormula {
		return sanitize.TableCell(clip(e.src, cellChars))
	}
	txt := c.Value(s.name, col, row).String()
	if a := address(txt); len(txt) == 40 && a.IsValid() {
		if !isFormula {
			return person(a)
		}
		txt = txt[:6] + "…" + txt[36:]
	}
	txt = sanitize.TableCell(clip(txt, cellChars))
	if isFormula && txt != "" {
		return "[" + txt + "](" + link(s.name+"/"+formula.CellName(col, row)) + ")"
	}
	return txt
}

func renderCell(s *sheet, col, row int) string {
	name := formula.CellName(col, row)
	c := newCalc()
	v := c.Value(s.name, col, row)
	e := s.get(col, row)

	out := "# " + s.link() + " / " + name + "\n\n"
	if e == nil {
		out += "This cell is empty.\n\n"
	} else {
		out += "## " + sanitize.InlineText(clip(v.String(), 120)) + "\n\n"
		if formula.IsFormula(e.src) {
			out += sanitize.CodeBlock(e.src) + "\n\n"
		}
		out += "Written by " + person(e.by) + " in block " + strconv.FormatInt(e.at, 10) + ".\n\n"
		if v.IsError() {
			out += "> [!WARNING]\n> " + explain(v.String()) + "\n\n"
		}
		out += s.renderInputs(c, e.src)
	}
	if s.locked(col, row) {
		out += "> [!NOTE]\n> This cell is locked for good. Nobody can change it, the owner included.\n\n"
	} else {
		if g := s.entrusted(col, row); g != nil {
			out += "> [!NOTE]\n> This cell is entrusted for good to " + grantee(g.who) + ".\n\n"
		}
		out += s.setForm(name, e)
	}
	return out + s.menu()
}

// renderInputs lists what a formula reads.
func (s *sheet) renderInputs(c *formula.Calc, src string) string {
	if !formula.IsFormula(src) {
		return ""
	}
	f, err := formula.Parse(src)
	if err != nil {
		return ""
	}
	refs := f.Refs()
	if len(refs) == 0 {
		return ""
	}
	out := "| Reads | Value |\n|:--|--:|\n"
	seen := map[string]bool{}
	for _, r := range refs {
		label := sanitize.TableCell(r.String())
		if seen[label] || len(seen) >= 20 {
			continue
		}
		seen[label] = true
		at := r.A
		if at.Sheet == "" {
			at.Sheet = s.name
		}
		target := sheets.Get(at.Sheet)
		if target == nil || !target.(*sheet).inside(r) {
			out += "| " + label + " | not there |\n"
			continue
		}
		if r.Size() > 1 {
			out += "| " + label + " | " + strconv.Itoa(r.Size()) + " cells |\n"
			continue
		}
		cell := formula.CellName(at.Col, at.Row)
		out += "| [" + label + "](" + link(at.Sheet+"/"+cell) + ") | " +
			sanitize.TableCell(clip(c.Value(at.Sheet, at.Col, at.Row).String(), 60)) + " |\n"
	}
	return out + "\n"
}

// explain describes an error value in words.
func explain(code string) string {
	switch code {
	case formula.ErrDiv:
		return "The formula divides by zero."
	case formula.ErrValue:
		return "An operand has the wrong type, such as text where a number is needed."
	case formula.ErrRef:
		return "The formula refers to a sheet or a cell that does not exist."
	case formula.ErrNum:
		return "The result does not fit, or is not defined."
	case formula.ErrNA:
		return "A lookup found nothing."
	case formula.ErrCycle:
		return "The cell depends on itself."
	case formula.ErrLimit:
		return "The formula needs too much work or makes too much text."
	}
	return "The formula cannot be evaluated."
}

// setForm is a form for one cell, filled with its content.
func (s *sheet) setForm(cell string, e *entry) string {
	src := ""
	if e != nil {
		src = ` value="` + sanitize.HTMLEscape(e.src) + `"`
	}
	return `<gno-form exec="Set">
<gno-input name="sheet" value="` + s.name + `" readonly="true" placeholder="sheet" />
<gno-input name="cell" value="` + cell + `" readonly="true" placeholder="cell" />
<gno-input name="value"` + src + ` placeholder="number, text or =formula" />
</gno-form>

`
}

// openForms shows a form for each of the first areas that visitors may fill.
func (s *sheet) openForms(max int) string {
	out := ""
	for _, g := range s.grants {
		if g.who != anyone || max == 0 {
			continue
		}
		max--
		hint := ""
		for col := g.area.A.Col; col <= g.area.B.Col; col++ {
			label := formula.CellName(col, 1)[:1]
			if g.area.A.Row > 1 {
				if e := s.get(col, g.area.A.Row-1); e != nil && !formula.IsFormula(e.src) {
					label = clip(e.src, 20)
				}
			}
			if hint != "" {
				hint += " | "
			}
			hint += strings.ReplaceAll(label, "|", "/")
		}
		out += "### Add a row\n\n" + `<gno-form exec="AddRow">
<gno-input name="sheet" value="` + s.name + `" readonly="true" placeholder="sheet" />
<gno-input name="area" value="` + g.area.String() + `" readonly="true" placeholder="area" />
<gno-input name="values" placeholder="` + sanitize.HTMLEscape(hint) + `" description="Values, separated by |" required="true" />
</gno-form>

`
	}
	return out
}

func renderEdit(s *sheet) string {
	sheetInput := `<gno-input name="sheet" value="` + s.name + `" readonly="true" placeholder="sheet" />` + "\n"
	return "# Edit " + s.link() + `

## Write a cell

<gno-form exec="Set">
` + sheetInput + `<gno-input name="cell" placeholder="cell, such as B2" required="true" />
<gno-input name="value" placeholder="number, text or =formula; empty clears" />
</gno-form>

## Paste a block

Copy cells from any spreadsheet and paste them here.

<gno-form exec="Paste">
` + sheetInput + `<gno-input name="at" value="A1" placeholder="top left cell" required="true" />
<gno-textarea name="block" placeholder="one line per row, columns separated by tabs or |" rows="6" required="true" />
</gno-form>

## Fill an area from one cell

<gno-form exec="Copy">
` + sheetInput + `<gno-input name="from" placeholder="cell to copy, such as D2" required="true" />
<gno-input name="to" placeholder="area to fill, such as D3:D9" required="true" />
</gno-form>

## Clear an area

<gno-form exec="Clear">
` + sheetInput + `<gno-input name="area" placeholder="area, such as A2:C9" required="true" />
</gno-form>

## Let someone write

<gno-form exec="Grant">
` + sheetInput + `<gno-input name="area" placeholder="area, such as A2:C9" required="true" />
<gno-input name="who" placeholder="an address, or anyone" required="true" />
</gno-form>

## Hand an area over for good

<gno-form exec="Entrust">
` + sheetInput + `<gno-input name="area" placeholder="area, such as B2:B9" description="You lose the right to write there" required="true" />
<gno-input name="who" placeholder="an address, or anyone" required="true" />
</gno-form>

## Lock an area for good

<gno-form exec="Lock">
` + sheetInput + `<gno-input name="area" placeholder="area, such as D2:D9" description="This cannot be undone" required="true" />
</gno-form>

## Add a chart

<gno-form exec="AddChart">
` + sheetInput + `<gno-select name="kind" value="bar" selected="true" />
<gno-select name="kind" value="line" />
<gno-input name="title" placeholder="title" required="true" />
<gno-input name="labels" placeholder="area of labels, such as A2:A9" required="true" />
<gno-input name="values" placeholder="area of values, such as D2:D9" required="true" />
</gno-form>

` + s.menu()
}

func renderRules(s *sheet) string {
	out := "# Who may write in " + s.link() + "\n\n"
	out += "The owner, " + person(s.owner) + ", may write anywhere that is not locked or entrusted.\n\n"
	if len(s.grants) > 0 {
		out += "| Area | Who | For how long |\n|:--|:--|:--|\n"
		open := false
		for _, g := range s.grants {
			open = open || g.who == anyone
			term := "until revoked, besides the owner"
			if g.sole {
				term = "for good, and the owner has no say there"
			}
			out += "| " + g.area.String() + " | " + grantee(g.who) + " | " + term + " |\n"
		}
		out += "\n"
		if open {
			out += "Anyone means: data only, and only into empty cells or cells they filled themselves.\n\n"
		}
	}
	if len(s.locks) == 0 {
		out += "Nothing is locked.\n\n"
	} else {
		out += "Locked for good, for everyone:"
		for i, l := range s.locks {
			if i > 0 {
				out += ","
			}
			out += " " + l.String()
		}
		out += "\n\n"
	}
	return out + s.menu()
}

func grantee(who string) string {
	if who == anyone {
		return anyone
	}
	return person(address(who))
}

func renderCSV(s *sheet, from int) string {
	cols, rows := s.used()
	from, last := window(from, rows, csvRows)
	c := newCalc()
	var b strings.Builder
	for row := from; row <= last; row++ {
		for col := 1; col <= cols; col++ {
			if col > 1 {
				b.WriteByte(',')
			}
			b.WriteString(csvField(c.Value(s.name, col, row).String()))
		}
		b.WriteByte('\n')
		if b.Len() > csvBytes {
			last = row
		}
	}
	out := "# " + s.link() + " as CSV\n\n" + sanitize.CodeBlock(b.String()) + "\n\n"
	if last < rows {
		out += "[Rows below](" + link(s.name+"/csv?from="+strconv.Itoa(last+1)) + ")\n\n"
	}
	return out + s.menu()
}

func csvField(s string) string {
	if strings.ContainsAny(s, ",\"") {
		return `"` + strings.ReplaceAll(s, `"`, `""`) + `"`
	}
	return s
}

func renderHelp() string {
	out := `# Formula guide

A cell holds a number, text, TRUE or FALSE, or a formula that starts with ` + "`=`" + `.

- **Cells** ` + "`B2`" + `, **ranges** ` + "`B2:B9`" + `, **other sheets** ` + "`rates!B2`" + `. A ` + "`$`" + ` keeps a
  column or row fixed when the formula is copied.
- **Operators** ` + "`+ - * / ^ %`" + `, ` + "`&`" + ` to join text, ` + "`= <> < <= > >=`" + ` to compare.
- **Numbers** have six decimals. Adding is exact; multiplying and dividing
  round to the nearest millionth. A result that does not fit is ` + "`#NUM!`" + `.
- **Circular** references show ` + "`#CYCLE!`" + `.
- **Text** that looks like a number: put an apostrophe first, ` + "`'007`" + `.

The examples below use A1:A4 = 4, 8, 15, 16 and B1:B4 = ale, mead, ale, rum.

`
	group := ""
	for _, f := range formula.Functions() {
		if f.Group != group {
			group = f.Group
			out += "\n## " + group + "\n\n"
		}
		out += "- `" + f.Usage + "` " + f.Help
		if f.Example != "" {
			out += " `" + f.Example + "` is " + sanitize.InlineText(f.Result)
		}
		out += "\n"
	}
	return out + "\n[Back](" + home + ")\n"
}
