package cellar

import (
	"chain"
	"chain/runtime"
	"strconv"
	"strings"

	"gno.land/p/g1pqtgghwrs33pxfl492yruc6l6x83hpr5lf46kr/cellar/formula/v1"
	"gno.land/p/nt/bptree/v0"
)

// NewSheet opens an empty sheet that belongs to the caller. The name is part
// of its address and cannot change.
func NewSheet(cur realm, name, title string, cols, rows int) {
	open(cur.Previous().Address(), name, title, cols, rows)
}

func open(owner address, name, title string, cols, rows int) *sheet {
	if !validName(name) {
		panic("cellar: a sheet name is 2 to 24 lower case letters, digits or _, starting with a letter")
	}
	if sheets.Has(name) {
		panic("cellar: the name " + name + " is taken")
	}
	if cols < 1 || cols > MaxCols || rows < 1 || rows > MaxRows {
		panic("cellar: a sheet has 1 to 26 columns and 1 to 200 rows")
	}
	assertTitle(title)
	s := &sheet{
		name:    name,
		title:   title,
		owner:   owner,
		cols:    cols,
		rows:    rows,
		cells:   bptree.NewBPTree32(),
		changed: runtime.ChainHeight(),
	}
	sheets.Set(name, s)
	n := strconv.Itoa(order.Size())
	order.Set("00000000"[len(n):]+n, name)
	chain.Emit("SheetOpened", "sheet", name, "owner", owner.String())
	return s
}

// Set writes one cell: a number, text, or a formula starting with "=". An
// empty value clears the cell. Start text with an apostrophe to keep it from
// being read as a number or a formula.
func Set(cur realm, sheet, cell, value string) {
	s := mustSheet(sheet)
	col, row := s.mustCell(cell)
	s.write(cur.Previous().Address(), col, row, strings.TrimSpace(value))
}

// Paste writes a block of cells, its top left corner at the given cell. The
// block has one line per row; columns are separated by tabs, as when copying
// from a spreadsheet, or by "|" when a line has no tab. Empty fields leave
// their cell as it is.
func Paste(cur realm, sheet, at, block string) {
	s := mustSheet(sheet)
	col, row := s.mustCell(at)
	s.paste(cur.Previous().Address(), col, row, block)
}

func (s *sheet) paste(who address, col, row int, block string) {
	count := 0
	for i, line := range strings.Split(strings.TrimRight(block, "\r\n"), "\n") {
		for j, field := range fields(line) {
			if field == "" {
				continue
			}
			s.assertInside(col+j, row+i)
			count++
			assertCount(count)
			s.write(who, col+j, row+i, field)
		}
	}
	if count == 0 {
		panic("cellar: nothing to paste")
	}
}

// AddRow fills the first row of an area that is still empty there. Values are
// separated by "|". It suits open areas: visitors do not have to pick a row.
func AddRow(cur realm, sheet, area, values string) {
	s := mustSheet(sheet)
	a := s.mustArea(area)
	who := cur.Previous().Address()
	vals := fields(values)
	if len(vals) > a.Cols() {
		panic("cellar: " + a.String() + " has room for " + strconv.Itoa(a.Cols()) + " values")
	}
	row := s.freeRow(a)
	if row == 0 {
		panic("cellar: " + a.String() + " has no empty row left")
	}
	count := 0
	for i, v := range vals {
		if v != "" {
			s.write(who, a.A.Col+i, row, v)
			count++
		}
	}
	if count == 0 {
		panic("cellar: nothing to add")
	}
}

// Copy writes the content of one cell into every cell of an area. References
// without "$" move along, as in other spreadsheets.
func Copy(cur realm, sheet, from, to string) {
	s := mustSheet(sheet)
	col, row := s.mustCell(from)
	s.fill(cur.Previous().Address(), col, row, s.mustArea(to))
}

func (s *sheet) fill(who address, col, row int, a formula.Range) {
	assertCount(a.Size())
	e := s.get(col, row)
	if e == nil {
		panic("cellar: " + formula.CellName(col, row) + " is empty")
	}
	for c := a.A.Col; c <= a.B.Col; c++ {
		for r := a.A.Row; r <= a.B.Row; r++ {
			if c == col && r == row {
				continue
			}
			moved, err := formula.Shift(e.src, c-col, r-row)
			if err != nil {
				panic("cellar: " + formula.CellName(c, r) + ": " + err.Error())
			}
			s.write(who, c, r, moved)
		}
	}
}

// Clear empties an area. Cells that are empty already need no permission.
func Clear(cur realm, sheet, area string) {
	s := mustSheet(sheet)
	a := s.mustArea(area)
	who := cur.Previous().Address()
	count := 0
	for c := a.A.Col; c <= a.B.Col; c++ {
		var rows []int
		s.each(c, a.A.Row, a.B.Row, func(row int, _ string) bool {
			rows = append(rows, row)
			return false
		})
		for _, r := range rows {
			count++
			assertCount(count)
			s.write(who, c, r, "")
		}
	}
}

// Grant lets someone write in an area: an address, or "anyone" to open the
// area to visitors. Only the owner can grant.
func Grant(cur realm, sheet, area, who string) {
	s := mustSheet(sheet)
	s.assertOwner(cur.Previous().Address())
	a := s.addGrant(area, who, false)
	chain.Emit("Granted", "sheet", s.name, "area", a.String(), "who", who)
}

// Entrust hands an area over for good, to an address or to "anyone". The owner
// keeps no right to write or lock there, and there is no way back. Only the
// owner can entrust.
func Entrust(cur realm, sheet, area, who string) {
	s := mustSheet(sheet)
	s.assertOwner(cur.Previous().Address())
	a := s.addGrant(area, who, true)
	chain.Emit("Entrusted", "sheet", s.name, "area", a.String(), "who", who)
}

func (s *sheet) addGrant(area, who string, sole bool) formula.Range {
	a := s.mustArea(area)
	if who != anyone && !address(who).IsValid() {
		panic("cellar: grant to an address or to " + strconv.Quote(anyone))
	}
	if len(s.grants) >= maxGrants {
		panic("cellar: a sheet has at most 32 grants")
	}
	for _, g := range s.grants {
		if g.sole && g.area.Overlaps(a) {
			panic("cellar: " + g.area.String() + " is entrusted already")
		}
		if g.who == who && g.area == a && g.sole == sole {
			panic("cellar: that grant exists")
		}
	}
	s.grants = append(s.grants, grant{a, who, sole})
	s.changed = runtime.ChainHeight()
	return a
}

// Revoke takes back a grant. Only the owner can revoke; what was entrusted
// stays entrusted.
func Revoke(cur realm, sheet, area, who string) {
	s := mustSheet(sheet)
	s.assertOwner(cur.Previous().Address())
	a := s.mustArea(area)
	for i, g := range s.grants {
		if g.who != who || g.area != a {
			continue
		}
		if g.sole {
			panic("cellar: what was entrusted cannot be taken back")
		}
		s.grants = append(s.grants[:i], s.grants[i+1:]...)
		s.changed = runtime.ChainHeight()
		chain.Emit("Revoked", "sheet", s.name, "area", a.String(), "who", who)
		return
	}
	panic("cellar: no such grant")
}

// Lock freezes an area for good. Nobody can ever change its cells again, and
// there is no way to unlock. The owner can lock, except where the area was
// entrusted; there, only the address it was entrusted to can.
func Lock(cur realm, sheet, area string) {
	s := mustSheet(sheet)
	a := s.mustArea(area)
	if reason := s.mayLock(cur.Previous().Address(), a); reason != "" {
		panic("cellar: " + a.String() + " " + reason)
	}
	for _, l := range s.locks {
		if l.Covers(a) {
			panic("cellar: " + a.String() + " is locked already")
		}
	}
	if len(s.locks) >= maxLocks {
		panic("cellar: a sheet has at most 32 locks")
	}
	s.locks = append(s.locks, a)
	s.changed = runtime.ChainHeight()
	chain.Emit("Locked", "sheet", s.name, "area", a.String())
}

// AddChart shows a chart under the sheet. kind is "bar" or "line"; labels and
// values are areas of one row or one column, of the same length. Only the
// owner can add charts.
func AddChart(cur realm, sheet, kind, title, labels, values string) {
	s := mustSheet(sheet)
	s.assertOwner(cur.Previous().Address())
	if kind != "bar" && kind != "line" {
		panic("cellar: a chart is a bar or a line")
	}
	assertTitle(title)
	l, v := s.mustArea(labels), s.mustArea(values)
	if !isLine(l) || !isLine(v) || l.Size() != v.Size() || l.Size() > maxPoints {
		panic("cellar: labels and values are lines of the same length, at most 24 cells")
	}
	if len(s.charts) >= maxCharts {
		panic("cellar: a sheet has at most 4 charts")
	}
	s.charts = append(s.charts, chart{kind, title, l, v})
	s.changed = runtime.ChainHeight()
}

// RemoveChart removes a chart, counting from 1. Only the owner can.
func RemoveChart(cur realm, sheet string, number int) {
	s := mustSheet(sheet)
	s.assertOwner(cur.Previous().Address())
	if number < 1 || number > len(s.charts) {
		panic("cellar: no such chart")
	}
	s.charts = append(s.charts[:number-1], s.charts[number:]...)
	s.changed = runtime.ChainHeight()
}

// Retitle changes the title of a sheet. Only the owner can.
func Retitle(cur realm, sheet, title string) {
	s := mustSheet(sheet)
	s.assertOwner(cur.Previous().Address())
	assertTitle(title)
	s.title = title
	s.changed = runtime.ChainHeight()
}

// Transfer gives a sheet to another owner. Only the owner can.
func Transfer(cur realm, sheet, to string) {
	s := mustSheet(sheet)
	s.assertOwner(cur.Previous().Address())
	if !address(to).IsValid() {
		panic("cellar: " + strconv.Quote(to) + " is not an address")
	}
	s.owner = address(to)
	s.changed = runtime.ChainHeight()
	chain.Emit("Transferred", "sheet", s.name, "to", to)
}

// freeRow returns the first row of an area without content there, or 0.
func (s *sheet) freeRow(a formula.Range) int {
	for row := a.A.Row; row <= a.B.Row; row++ {
		empty := true
		for col := a.A.Col; col <= a.B.Col && empty; col++ {
			empty = s.get(col, row) == nil && !s.locked(col, row)
		}
		if empty {
			return row
		}
	}
	return 0
}

func (s *sheet) assertInside(col, row int) {
	if col > s.cols || row > s.rows {
		panic("cellar: the block does not fit into " + s.name)
	}
}

func assertCount(n int) {
	if n > maxBlock {
		panic("cellar: at most 400 cells at a time")
	}
}

func assertTitle(title string) {
	if strings.TrimSpace(title) == "" || len(title) > maxTitle || !printable(title) {
		panic("cellar: a title has 1 to 60 bytes on one line")
	}
}

// fields splits one line of a block.
func fields(line string) []string {
	sep := "|"
	if strings.Contains(line, "\t") {
		sep = "\t"
	}
	out := strings.Split(line, sep)
	for i, f := range out {
		out[i] = strings.TrimSpace(f)
	}
	return out
}
