package cellar

import (
	"chain/banker"
	"chain/runtime"
	"strconv"
	"time"

	"gno.land/p/g1pqtgghwrs33pxfl492yruc6l6x83hpr5lf46kr/cellar/formula/v1"
	"gno.land/r/nt/grc20reg/v0"
)

// The functions in this file only read. Any realm may call them.

// Exists reports whether there is a sheet with this name.
func Exists(sheet string) bool { return sheets.Has(sheet) }

// Owner returns the owner of a sheet.
func Owner(sheet string) address { return mustSheet(sheet).owner }

// Value returns the calculated value of a cell.
func Value(sheet, cell string) formula.Value {
	s := mustSheet(sheet)
	col, row := s.mustCell(cell)
	return newCalc().Value(s.name, col, row)
}

// Number returns a cell as a count of millionths, and whether the cell is a
// number.
func Number(sheet, cell string) (int64, bool) {
	n, ok := Value(sheet, cell).Num()
	return int64(n), ok
}

// Text returns a cell the way the sheet shows it.
func Text(sheet, cell string) string { return Value(sheet, cell).String() }

// Values returns the calculated values of an area, row by row. It is cheaper
// than asking for each cell.
func Values(sheet, area string) []formula.Value {
	s := mustSheet(sheet)
	a := s.mustArea(area)
	c := newCalc()
	out := make([]formula.Value, 0, a.Size())
	for row := a.A.Row; row <= a.B.Row; row++ {
		for col := a.A.Col; col <= a.B.Col; col++ {
			out = append(out, c.Value(s.name, col, row))
		}
	}
	return out
}

// Source returns what was written into a cell.
func Source(sheet, cell string) string {
	s := mustSheet(sheet)
	if e := s.get(s.mustCell(cell)); e != nil {
		return e.src
	}
	return ""
}

// Editor returns who wrote a cell, or "" if it is empty.
func Editor(sheet, cell string) address {
	s := mustSheet(sheet)
	if e := s.get(s.mustCell(cell)); e != nil {
		return e.by
	}
	return ""
}

// IsLocked reports whether every cell of an area is locked for good.
func IsLocked(sheet, area string) bool {
	s := mustSheet(sheet)
	a := s.mustArea(area)
	for col := a.A.Col; col <= a.B.Col; col++ {
		for row := a.A.Row; row <= a.B.Row; row++ {
			if !s.locked(col, row) {
				return false
			}
		}
	}
	return true
}

// Trustee returns who a cell is entrusted to: an address, "anyone", or "" if it
// is not entrusted.
func Trustee(sheet, cell string) string {
	s := mustSheet(sheet)
	if g := s.entrusted(s.mustCell(cell)); g != nil {
		return g.who
	}
	return ""
}

// each calls fn for the filled cells of part of a column, from the top, until
// fn returns true.
func (s *sheet) each(col, lo, hi int, fn func(row int, src string) bool) {
	s.cells.Iterate(key(col, lo), key(col, hi+1), func(k string, v any) bool {
		row, _ := strconv.Atoi(k[1:])
		return fn(row, unpack(v.(string)).src)
	})
}

func newCalc() *formula.Calc { return formula.NewCalc(book{}, formula.DefaultFuel) }

// book lets formulas see the sheets and the chain. It implements formula.Book.
type book struct{}

func (book) Bounds(name string) (cols, rows int, ok bool) {
	s := sheets.Get(name)
	if s == nil {
		return 0, 0, false
	}
	return s.(*sheet).cols, s.(*sheet).rows, true
}

func (book) Raw(name string, col, row int) string {
	if e := mustSheet(name).get(col, row); e != nil {
		return e.src
	}
	return ""
}

func (book) Each(name string, col, lo, hi int, fn func(row int, raw string) bool) {
	mustSheet(name).each(col, lo, hi, fn)
}

func (book) Host(name, fn string, args []formula.Arg) (formula.Value, bool) {
	switch fn {
	case "HEIGHT":
		return formula.NewInt(runtime.ChainHeight()), true
	case "NOW":
		return formula.NewInt(time.Now().Unix()), true
	case "OWNER":
		return formula.NewText(mustSheet(name).owner.String()), true
	case "BALANCE":
		return balance(args[0].Value.String()), true
	case "TOKEN":
		return tokenBalance(args[0].Value.String(), args[1].Value.String()), true
	case "EDITOR", "EDITED":
		at := args[0].Range.A
		e := mustSheet(at.Sheet).get(at.Col, at.Row)
		switch {
		case e == nil && fn == "EDITOR":
			return formula.NewText(""), true
		case e == nil:
			return formula.NewInt(0), true
		case fn == "EDITOR":
			return formula.NewText(e.by.String()), true
		}
		return formula.NewInt(e.at), true
	}
	return formula.Value{}, false
}

// balance is the GNOT held by an address. One millionth is one ugnot.
func balance(addr string) formula.Value {
	if !address(addr).IsValid() {
		return formula.NewError(formula.ErrValue)
	}
	ugnot := banker.NewReadonlyBanker().GetCoin(address(addr), "ugnot")
	return formula.NewNumber(formula.Num(ugnot))
}

// tokenBalance is the amount of a registered GRC20 token held by an address.
func tokenBalance(id, addr string) formula.Value {
	if !address(addr).IsValid() {
		return formula.NewError(formula.ErrValue)
	}
	token := grc20reg.Get(id)
	if token == nil {
		return formula.NewError(formula.ErrNA)
	}
	n, ok := formula.FromUnits(token.BalanceOf(address(addr)), token.GetDecimals())
	if !ok {
		return formula.NewError(formula.ErrNum)
	}
	return formula.NewNumber(n)
}
