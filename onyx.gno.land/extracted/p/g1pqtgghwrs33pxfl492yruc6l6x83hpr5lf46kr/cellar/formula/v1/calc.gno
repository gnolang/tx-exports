package formula

// Book is the data a Calc works on. Sheet "" never reaches a Book: the Calc
// always passes the name of a sheet.
type Book interface {
	// Bounds returns the size of a sheet, and false if it does not exist.
	Bounds(sheet string) (cols, rows int, ok bool)
	// Raw returns the content of a cell, "" when it is empty.
	Raw(sheet string, col, row int) string
	// Each calls fn for the non-empty cells of one column from row lo to row
	// hi, in order, until fn returns true.
	Each(sheet string, col, lo, hi int, fn func(row int, raw string) bool)
	// Host evaluates a function listed with Host set in Functions, and
	// returns false if the Book does not support it.
	Host(sheet, name string, args []Arg) (Value, bool)
}

// Arg is an argument of a host function. A reference is passed unevaluated in
// Range, with Sheet filled in; IsRef tells which field is set.
type Arg struct {
	Value Value
	Range Range
	IsRef bool
}

// DefaultFuel is enough work for a full page of formulas, and little enough
// for a query: one unit costs up to about 200,000 gas, and nodes stop a query at
// 3 billion.
const DefaultFuel = 10000

// Calc evaluates cells of a Book and remembers the results. Make a new one
// whenever the Book may have changed.
type Calc struct {
	book   Book
	cells  map[int]*cell
	sheets map[string]sheetSize
	fuel   int

	// Tarjan's strongly connected components, for finding cycles.
	stack []*cell
	count int
}

type sheetSize struct {
	cols, rows int
	ok         bool
	number     int // tells sheets apart in cell keys
}

// cell is one evaluated or pending cell.
type cell struct {
	sheet    string
	col, row int
	formula  *Formula
	value    Value
	done     bool
	deps     []*cell
	next     int // next dependency to visit
	index    int // order of discovery, from 1
	low      int // lowest index reachable
	self     bool
}

// NewCalc returns a Calc that spends at most fuel units of work, such as
// reading a cell or applying an operator. When fuel runs out, the remaining
// results are #LIMIT!.
func NewCalc(book Book, fuel int) *Calc {
	return &Calc{
		book:   book,
		cells:  map[int]*cell{},
		sheets: map[string]sheetSize{},
		fuel:   fuel,
	}
}

// Fuel returns the work left.
func (c *Calc) Fuel() int { return c.fuel }

// Value returns the value of a cell.
func (c *Calc) Value(sheet string, col, row int) Value {
	size := c.size(sheet)
	if !size.ok || col < 1 || row < 1 || col > size.cols || row > size.rows {
		return NewError(ErrRef)
	}
	x := c.find(sheet, size, col, row)
	if x == nil {
		return Value{}
	}
	if !x.done {
		c.resolve(x)
	}
	return x.value
}

// Eval evaluates a formula that is not stored anywhere, as if it stood in the
// given cell.
func (c *Calc) Eval(f *Formula, sheet string, col, row int) Value {
	x := &cell{sheet: sheet, col: col, row: row, formula: f}
	c.link(x)
	for _, d := range x.deps {
		if !d.done {
			c.resolve(d)
		}
	}
	return c.run(x)
}

func (c *Calc) size(sheet string) sheetSize {
	s, ok := c.sheets[sheet]
	if !ok {
		s.cols, s.rows, s.ok = c.book.Bounds(sheet)
		s.number = len(c.sheets)
		c.sheets[sheet] = s
	}
	return s
}

// spend uses fuel and reports whether there was enough.
func (c *Calc) spend(n int) bool {
	if c.fuel < n {
		c.fuel = 0
		return false
	}
	c.fuel -= n
	return true
}

// cellKey identifies a cell among the cells of a Calc.
func cellKey(size sheetSize, col, row int) int {
	return (size.number*(MaxCols+1)+col)*(MaxRows+1) + row
}

// find returns the record of a cell, or nil if the cell is empty. Data cells
// are evaluated right away.
func (c *Calc) find(sheet string, size sheetSize, col, row int) *cell {
	key := cellKey(size, col, row)
	if x, ok := c.cells[key]; ok {
		return x
	}
	x := c.load(sheet, col, row, c.book.Raw(sheet, col, row))
	c.cells[key] = x
	return x
}

func (c *Calc) load(sheet string, col, row int, raw string) *cell {
	if raw == "" {
		return nil
	}
	x := &cell{sheet: sheet, col: col, row: row}
	cost := 1 + len(raw)/32
	if IsFormula(raw) {
		cost = 1 + len(raw)/2 // parsing
	}
	if !c.spend(cost) {
		x.value, x.done = NewError(ErrLimit), true
		return x
	}
	if !IsFormula(raw) {
		x.value, x.done = ParseData(raw), true
		return x
	}
	f, err := Parse(raw)
	if err != nil { // a Book should not store these
		x.value, x.done = NewError(ErrName), true
		return x
	}
	x.formula = f
	return x
}

// link lists the formulas that x refers to, whether or not evaluating x would
// read them.
func (c *Calc) link(x *cell) {
	for _, r := range x.formula.Refs() {
		sheet := r.A.Sheet
		if sheet == "" {
			sheet = x.sheet
		}
		size := c.size(sheet)
		if !size.ok {
			continue
		}
		for col := r.A.Col; col <= r.B.Col && col <= size.cols; col++ {
			if !c.spend(2) {
				return // run will answer #LIMIT!
			}
			hi := r.B.Row
			if hi > size.rows {
				hi = size.rows
			}
			c.each(sheet, size, col, r.A.Row, hi, func(d *cell) {
				if d.done {
					return
				}
				if d == x {
					x.self = true
					return
				}
				x.deps = append(x.deps, d)
			})
		}
	}
}

// each calls fn for the non-empty cells of part of a column.
func (c *Calc) each(sheet string, size sheetSize, col, lo, hi int, fn func(*cell)) {
	if lo == hi {
		if x := c.find(sheet, size, col, lo); x != nil {
			fn(x)
		}
		return
	}
	c.book.Each(sheet, col, lo, hi, func(row int, raw string) bool {
		key := cellKey(size, col, row)
		x, ok := c.cells[key]
		if !ok {
			x = c.load(sheet, col, row, raw)
			c.cells[key] = x
		}
		if x != nil {
			fn(x)
		}
		return c.fuel == 0
	})
}

// resolve evaluates root and everything it refers to, dependencies first.
//
// A cell is circular when it can reach itself through references, counting
// branches of IF that are not taken, so the outcome does not depend on which
// cell is looked at first. This is Tarjan's algorithm with an explicit stack:
// long chains of cells do not nest calls.
func (c *Calc) resolve(root *cell) {
	path := []*cell{root}
	c.enter(root)
	for len(path) > 0 {
		x := path[len(path)-1]
		if x.next < len(x.deps) {
			d := x.deps[x.next]
			x.next++
			switch {
			case d.done:
			case d.index == 0:
				c.enter(d)
				path = append(path, d)
			case d.index < x.low: // on the stack: not done means not popped
				x.low = d.index
			}
			continue
		}
		path = path[:len(path)-1]
		if len(path) > 0 {
			if up := path[len(path)-1]; x.low < up.low {
				up.low = x.low
			}
		}
		if x.low == x.index {
			c.finish(x)
		}
	}
}

func (c *Calc) enter(x *cell) {
	c.count++
	x.index, x.low = c.count, c.count
	c.stack = append(c.stack, x)
	c.link(x)
}

// finish pops the component whose first cell is x and gives it values.
func (c *Calc) finish(x *cell) {
	n := len(c.stack) - 1
	if c.stack[n] == x && !x.self {
		c.stack = c.stack[:n]
		x.value = c.run(x)
		x.done = true
		return
	}
	for {
		n := len(c.stack) - 1
		y := c.stack[n]
		c.stack = c.stack[:n]
		y.value, y.done = NewError(ErrCycle), true
		if y == x {
			return
		}
	}
}

// run evaluates the formula of x. Its dependencies are done.
func (c *Calc) run(x *cell) Value {
	e := &eval{c: c, at: x}
	v := e.scalar(x.formula.root)
	if v.kind == Empty { // =A1 of an empty cell shows 0
		return NewNumber(0)
	}
	return v
}
