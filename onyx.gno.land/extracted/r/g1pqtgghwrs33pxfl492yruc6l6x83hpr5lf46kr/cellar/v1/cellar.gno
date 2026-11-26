// Package cellar keeps shared sheets whose rules are enforced by the chain.
//
// Anyone can open a sheet, fill it with numbers, text and formulas, and decide
// who may write where, for now or for good. This realm works out formulas
// whenever a sheet is read, so nobody has to run anything to keep a sheet up to
// date, and other realms can use a cell as easily as a constant:
//
//	n, ok := cellar.Number("bakeoff", "E2") // millionths
//
// # Who may write
//
//   - The owner of a sheet may write anywhere that is not locked.
//   - Grant gives one address an area to write in, formulas included.
//   - Grant to "anyone" opens an area to visitors. A visitor may fill an empty
//     cell with data, not formulas, and afterwards only that visitor or the
//     owner may change it.
//   - Entrust hands an area over for good, to one address or to "anyone". From
//     then on the owner may write there no more than any stranger.
//   - Lock freezes an area for good. Nobody can change a locked cell again,
//     the owner included, so a locked formula can be relied on.
package cellar

import (
	"chain"
	"chain/runtime"
	"chain/runtime/unsafe"
	"strconv"
	"strings"

	"gno.land/p/g1pqtgghwrs33pxfl492yruc6l6x83hpr5lf46kr/cellar/formula/v1"
	"gno.land/p/nt/avl/v0"
	"gno.land/p/nt/bptree/v0"
)

const (
	MaxCols   = formula.MaxCols // A to Z
	MaxRows   = 200
	maxTitle  = 60
	maxName   = 24
	maxGrants = 32
	maxLocks  = 32
	maxCharts = 4
	maxBlock  = 400 // cells changed by one call

	// anyone is the grantee that stands for every visitor.
	anyone = "anyone"
)

// sheet is one spreadsheet.
type sheet struct {
	name       string
	title      string
	owner      address
	cols, rows int
	cells      *bptree.BPTree // cell key -> packed entry
	grants     []grant
	locks      []formula.Range
	charts     []chart
	changed    int64 // height of the last change
}

// entry is the content of a cell that is not empty.
type entry struct {
	src string
	by  address // who wrote it
	at  int64   // at which height
}

// pack turns an entry into one string, which takes less than half the storage
// of a struct of its own.
func (e entry) pack() string {
	return e.by.String() + " " + strconv.FormatInt(e.at, 10) + " " + e.src
}

func unpack(s string) entry {
	by, rest, _ := strings.Cut(s, " ")
	at, src, _ := strings.Cut(rest, " ")
	height, _ := strconv.ParseInt(at, 10, 64)
	return entry{src, address(by), height}
}

// grant lets someone write in an area.
type grant struct {
	area formula.Range
	who  string // an address, or anyone
	sole bool   // entrusted: nobody else may write there, and it cannot be revoked
}

var (
	sheets = avl.NewTree() // name -> *sheet
	order  = avl.NewTree() // number, with leading zeros -> name
	home   string          // path of this realm on gnoweb
)

func init() {
	home = strings.TrimPrefix(unsafe.CurrentRealm().PkgPath(), runtime.ChainDomain())
}

// key sorts the cells of a column together, from top to bottom.
func key(col, row int) string {
	s := strconv.Itoa(row)
	return string(rune('A'+col-1)) + "000"[len(s):] + s
}

func (s *sheet) get(col, row int) *entry {
	v := s.cells.Get(key(col, row))
	if v == nil {
		return nil
	}
	e := unpack(v.(string))
	return &e
}

// put stores content, which must be valid, or removes the cell when src is
// empty. The caller has checked permission.
func (s *sheet) put(by address, col, row int, src string) {
	if src == "" {
		s.cells.Remove(key(col, row))
	} else {
		s.cells.Set(key(col, row), entry{src, by, runtime.ChainHeight()}.pack())
	}
	s.changed = runtime.ChainHeight()
	chain.Emit("CellWritten",
		"sheet", s.name,
		"cell", formula.CellName(col, row),
		"by", by.String(),
	)
}

func (s *sheet) inside(a formula.Range) bool {
	return a.B.Col <= s.cols && a.B.Row <= s.rows
}

func mustSheet(name string) *sheet {
	s := sheets.Get(name)
	if s == nil {
		panic("cellar: no sheet named " + strconv.Quote(name))
	}
	return s.(*sheet)
}

func (s *sheet) mustCell(name string) (col, row int) {
	col, row, ok := formula.ParseCell(name)
	if !ok || col > s.cols || row > s.rows {
		panic("cellar: " + s.name + " has no cell " + strconv.Quote(name))
	}
	return col, row
}

func (s *sheet) mustArea(name string) formula.Range {
	a, ok := formula.ParseArea(name)
	if !ok || !s.inside(a) {
		panic("cellar: " + s.name + " has no area " + strconv.Quote(name))
	}
	// "$" marks mean nothing here.
	a.A.AbsCol, a.A.AbsRow, a.B.AbsCol, a.B.AbsRow = false, false, false, false
	return a
}
