package formula

// eval evaluates the formula of one cell.
type eval struct {
	c  *Calc
	at *cell
}

// scalar evaluates n to a single value.
func (e *eval) scalar(n *node) Value {
	if !e.c.spend(1) {
		return NewError(ErrLimit)
	}
	switch n.kind {
	case nodeConst:
		return n.val
	case nodeRef:
		return e.cell(n.rng.A.Sheet, n.rng.A.Col, n.rng.A.Row)
	case nodeRange:
		return NewError(ErrValue)
	case nodeCall:
		return e.call(n)
	case nodeNeg:
		a, bad := asNum(e.scalar(n.args[0]))
		if bad.IsError() {
			return bad
		}
		return NewNumber(-a)
	case nodePct:
		a, bad := asNum(e.scalar(n.args[0]))
		if bad.IsError() {
			return bad
		}
		return number(Div(a, 100*Unit))
	}
	return e.binary(n)
}

func (e *eval) binary(n *node) Value {
	l := e.scalar(n.args[0])
	if l.IsError() {
		return l
	}
	r := e.scalar(n.args[1])
	if r.IsError() {
		return r
	}
	if !e.c.spend(textCost(l) + textCost(r)) {
		return NewError(ErrLimit)
	}
	switch n.kind {
	case '&':
		return NewText(l.String() + r.String())
	case '=':
		return NewBool(compare(l, r) == 0)
	case nodeNE:
		return NewBool(compare(l, r) != 0)
	case '<':
		return NewBool(compare(l, r) < 0)
	case '>':
		return NewBool(compare(l, r) > 0)
	case nodeLE:
		return NewBool(compare(l, r) <= 0)
	case nodeGE:
		return NewBool(compare(l, r) >= 0)
	}
	a, bad := asNum(l)
	if bad.IsError() {
		return bad
	}
	b, bad := asNum(r)
	if bad.IsError() {
		return bad
	}
	switch n.kind {
	case '+':
		return number(Add(a, b))
	case '-':
		return number(Sub(a, b))
	case '*':
		return number(Mul(a, b))
	case '/':
		return divide(a, b)
	}
	return e.raise(a, b)
}

// textCost is the extra fuel for handling a text: reading, changing and
// comparing text takes time for every character.
func textCost(v Value) int {
	if v.kind == Text {
		return len(v.str) / 5
	}
	return 0
}

func divide(a, b Num) Value {
	if b == 0 {
		return NewError(ErrDiv)
	}
	return number(Div(a, b))
}

func (e *eval) raise(a, b Num) Value {
	if !e.c.spend(30) {
		return NewError(ErrLimit)
	}
	if !b.IsInt() || b > MaxExponent*Unit || b < -MaxExponent*Unit {
		return NewError(ErrNum)
	}
	if a == 0 {
		if b == 0 {
			return NewError(ErrNum)
		}
		if b < 0 {
			return NewError(ErrDiv)
		}
	}
	return number(Pow(a, int(b.Int64())))
}

// number wraps the result of a Num operation.
func number(n Num, ok bool) Value {
	if !ok {
		return NewError(ErrNum)
	}
	return NewNumber(n)
}

// cell returns the value of a cell this formula refers to.
func (e *eval) cell(sheet string, col, row int) Value {
	if sheet == "" {
		sheet = e.at.sheet
	}
	return e.c.Value(sheet, col, row)
}

// isRange reports whether an argument is a range or a single cell.
func isRange(n *node) bool { return n.kind == nodeRange || n.kind == nodeRef }

// fits returns an error value if a range reaches outside its sheet.
func (e *eval) fits(r Range) Value {
	sheet := r.A.Sheet
	if sheet == "" {
		sheet = e.at.sheet
	}
	if size := e.c.size(sheet); !size.ok || r.B.Col > size.cols || r.B.Row > size.rows {
		return NewError(ErrRef)
	}
	return Value{}
}

// each visits the non-empty cells of a range, column by column, until fn
// returns true. It returns an error value if the range cannot be read.
func (e *eval) each(r Range, fn func(Value) bool) Value {
	if bad := e.fits(r); bad.IsError() {
		return bad
	}
	sheet := r.A.Sheet
	if sheet == "" {
		sheet = e.at.sheet
	}
	size, stop := e.c.size(sheet), false
	for col := r.A.Col; col <= r.B.Col && !stop && e.c.spend(1); col++ {
		e.c.each(sheet, size, col, r.A.Row, r.B.Row, func(x *cell) {
			if stop || !e.c.spend(1) {
				stop = true
				return
			}
			if !x.done {
				// Only Eval with a formula that is not stored, or a
				// cell past the fuel limit, can get here.
				e.c.resolve(x)
			}
			stop = fn(x.value)
		})
	}
	if e.c.fuel == 0 {
		return NewError(ErrLimit)
	}
	return Value{}
}

// grid returns every cell of a range, row by row, empty cells included.
func (e *eval) grid(r Range) ([]Value, Value) {
	if bad := e.fits(r); bad.IsError() {
		return nil, bad
	}
	if !e.c.spend(r.Size()) {
		return nil, NewError(ErrLimit)
	}
	out := make([]Value, 0, r.Size())
	for row := r.A.Row; row <= r.B.Row; row++ {
		for col := r.A.Col; col <= r.B.Col; col++ {
			v := e.cell(r.A.Sheet, col, row)
			if !e.c.spend(textCost(v)) {
				return nil, NewError(ErrLimit)
			}
			out = append(out, v)
		}
	}
	if e.c.fuel == 0 {
		return nil, NewError(ErrLimit)
	}
	return out, Value{}
}
