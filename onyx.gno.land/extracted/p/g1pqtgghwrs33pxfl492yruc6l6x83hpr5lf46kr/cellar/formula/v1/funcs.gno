package formula

import (
	"sort"
	"strings"
)

const manyArgs = 99

// arity returns how many arguments a function takes.
func arity(name string) (lo, hi int, ok bool) {
	switch name {
	case "HEIGHT", "NOW", "OWNER":
		return 0, 0, true
	case "ROW", "COLUMN":
		return 0, 1, true
	case "ABS", "INT", "SQRT", "SIGN", "NOT", "ISERROR", "ISBLANK", "ISNUMBER",
		"ISTEXT", "LEN", "UPPER", "LOWER", "TRIM", "VALUE", "MEDIAN",
		"COUNTBLANK", "SPARK", "BALANCE", "EDITOR", "EDITED":
		return 1, 1, true
	case "ROUND", "ROUNDUP", "ROUNDDOWN", "LEFT", "RIGHT":
		return 1, 2, true
	case "SUM", "PRODUCT", "AVERAGE", "MIN", "MAX", "COUNT", "COUNTA", "AND",
		"OR", "CONCAT", "SUMPRODUCT":
		return 1, manyArgs, true
	case "MOD", "POWER", "IFERROR", "LARGE", "SMALL", "COUNTIF", "REPT",
		"EXACT", "TOKEN":
		return 2, 2, true
	case "IF", "SUMIF", "AVERAGEIF", "FIND", "INDEX", "BAR", "RANK":
		return 2, 3, true
	case "IFS", "CHOOSE":
		return 2, manyArgs, true
	case "MID", "SUBSTITUTE", "MATCH":
		return 3, 3, true
	case "FIXED":
		return 1, 3, true
	case "TEXTJOIN":
		return 3, manyArgs, true
	case "XLOOKUP":
		return 3, 4, true
	}
	return 0, 0, false
}

// call evaluates a function.
func (e *eval) call(n *node) Value {
	args := n.args
	switch n.name {
	// Choosing: only the arguments that matter are evaluated.
	case "IF":
		yes, bad := asBool(e.scalar(args[0]))
		if bad.IsError() {
			return bad
		}
		if yes {
			return e.scalar(args[1])
		}
		if len(args) == 3 {
			return e.scalar(args[2])
		}
		return NewBool(false)
	case "IFS":
		for i := 0; i+1 < len(args); i += 2 {
			yes, bad := asBool(e.scalar(args[i]))
			if bad.IsError() {
				return bad
			}
			if yes {
				return e.scalar(args[i+1])
			}
		}
		return NewError(ErrNA)
	case "IFERROR":
		v := e.scalar(args[0])
		if v.IsError() {
			return e.scalar(args[1])
		}
		return v
	case "CHOOSE":
		i, bad := e.whole(args[0])
		if bad.IsError() {
			return bad
		}
		if i < 1 || i >= len(args) {
			return NewError(ErrValue)
		}
		return e.scalar(args[i])

	// Totals.
	case "SUM":
		sum, bad := Num(0), Value{}
		bad = e.numbers(args, func(x Num) bool {
			var ok bool
			sum, ok = Add(sum, x)
			return !ok
		})
		return result(sum, bad)
	case "PRODUCT":
		p, seen := Unit, false
		bad := e.numbers(args, func(x Num) bool {
			var ok bool
			p, ok = Mul(p, x)
			seen = true
			return !ok
		})
		if !seen {
			p = 0
		}
		return result(p, bad)
	case "AVERAGE":
		sum, count := Num(0), int64(0)
		bad := e.numbers(args, func(x Num) bool {
			var ok bool
			sum, ok = Add(sum, x)
			count++
			return !ok
		})
		return average(sum, count, bad)
	case "MIN", "MAX":
		best, seen := Num(0), false
		bad := e.numbers(args, func(x Num) bool {
			if !seen || (x < best) == (n.name == "MIN") {
				best = x
			}
			seen = true
			return false
		})
		return result(best, bad)
	case "COUNT", "COUNTA":
		return e.count(args, n.name == "COUNTA")
	case "COUNTBLANK":
		cells, bad := e.cells(args[0])
		if bad.IsError() {
			return bad
		}
		blank := int64(0)
		for _, v := range cells {
			if v.kind == Empty || v.kind == Text && v.str == "" {
				blank++
			}
		}
		return NewInt(blank)
	case "MEDIAN", "LARGE", "SMALL":
		return e.ordered(n)
	case "RANK":
		return e.rank(args)
	case "SUMPRODUCT":
		return e.sumProduct(args)
	case "COUNTIF":
		return e.countIf(args)
	case "SUMIF", "AVERAGEIF":
		return e.sumIf(args, n.name == "AVERAGEIF")

	// Logic.
	case "AND", "OR":
		return e.logic(args, n.name == "AND")
	case "NOT":
		b, bad := asBool(e.scalar(args[0]))
		if bad.IsError() {
			return bad
		}
		return NewBool(!b)
	case "ISERROR":
		return NewBool(e.scalar(args[0]).IsError())
	case "ISBLANK":
		return NewBool(e.scalar(args[0]).kind == Empty)
	case "ISNUMBER":
		return NewBool(e.scalar(args[0]).kind == Number)
	case "ISTEXT":
		return NewBool(e.scalar(args[0]).kind == Text)

	// Lookup.
	case "ROW", "COLUMN":
		at := Ref{Col: e.at.col, Row: e.at.row}
		if len(args) == 1 {
			if !isRange(args[0]) {
				return NewError(ErrValue)
			}
			at = args[0].rng.A
		}
		if n.name == "ROW" {
			return NewInt(int64(at.Row))
		}
		return NewInt(int64(at.Col))
	case "INDEX":
		return e.index(args)
	case "MATCH":
		return e.match(args)
	case "XLOOKUP":
		return e.lookup(args)

	// Text.
	case "CONCAT", "TEXTJOIN":
		return e.join(n)

	// Pictures made of characters.
	case "SPARK":
		return e.spark(args[0])
	}
	if v, ok := e.host(n); ok {
		return v
	}
	return e.simple(n)
}

// simple handles functions whose arguments are all single values.
func (e *eval) simple(n *node) Value {
	var v [4]Value
	for i, a := range n.args {
		v[i] = e.scalar(a)
		if v[i].IsError() {
			return v[i]
		}
	}
	count := len(n.args)
	if !e.c.spend(textCost(v[0]) + textCost(v[1])) {
		return NewError(ErrLimit)
	}

	// Functions of text.
	s := v[0].String()
	switch n.name {
	case "LEN":
		return NewInt(int64(len([]rune(s))))
	case "UPPER":
		return NewText(strings.ToUpper(s))
	case "LOWER":
		return NewText(strings.ToLower(s))
	case "TRIM":
		return NewText(strings.Join(strings.Fields(s), " "))
	case "VALUE":
		x, bad := asNum(v[0])
		return result(x, bad)
	case "EXACT":
		return NewBool(s == v[1].String())
	case "SUBSTITUTE":
		if v[1].String() == "" {
			return NewText(s)
		}
		return NewText(strings.ReplaceAll(s, v[1].String(), v[2].String()))
	case "LEFT", "RIGHT", "MID", "REPT", "FIND":
		return textFunc(n.name, s, v, count)
	}

	// Functions of numbers.
	a, bad := asNum(v[0])
	if bad.IsError() {
		return bad
	}
	b, bad := asNum(v[1])
	if bad.IsError() {
		return bad
	}
	switch n.name {
	case "ABS":
		if a < 0 {
			a = -a
		}
		return NewNumber(a)
	case "SIGN":
		switch {
		case a > 0:
			return NewInt(1)
		case a < 0:
			return NewInt(-1)
		}
		return NewInt(0)
	case "INT":
		return number(Floor(a))
	case "SQRT":
		if a < 0 {
			return NewError(ErrNum)
		}
		if !e.c.spend(15) {
			return NewError(ErrLimit)
		}
		return NewNumber(Sqrt(a))
	case "POWER":
		return e.raise(a, b)
	case "MOD":
		if b == 0 {
			return NewError(ErrDiv)
		}
		return NewNumber(Mod(a, b))
	case "ROUND":
		return number(Round(a, small(b)))
	case "ROUNDUP":
		return number(RoundUp(a, small(b)))
	case "ROUNDDOWN":
		return number(RoundDown(a, small(b)))
	case "FIXED":
		places := 2
		if count > 1 {
			places = small(b)
		}
		plain, bad := asBool(v[2])
		if bad.IsError() {
			return bad
		}
		return fixed(a, places, plain)
	case "BAR":
		width := 10
		if count == 3 {
			w, bad := asNum(v[2])
			if bad.IsError() {
				return bad
			}
			width = small(w)
		}
		return bar(a, b, width)
	}
	return NewError(ErrName)
}

// small converts to an int, clamping to a range that is safe for any use.
func small(n Num) int {
	const limit = 10000
	switch i := n.Int64(); {
	case i > limit:
		return limit
	case i < -limit:
		return -limit
	default:
		return int(i)
	}
}

// int evaluates an argument that counts something.
func (e *eval) whole(n *node) (int, Value) {
	x, bad := asNum(e.scalar(n))
	return small(x), bad
}

// result returns x, or bad if it is an error.
func result(x Num, bad Value) Value {
	if bad.IsError() {
		return bad
	}
	return NewNumber(x)
}

// numbers calls fn for every number among the arguments. In a range, anything
// that is not a number is skipped; a single argument is converted. fn returns
// true to report an overflow.
func (e *eval) numbers(args []*node, fn func(Num) bool) Value {
	var bad Value
	for _, a := range args {
		if isRange(a) {
			stop := e.each(a.rng, func(v Value) bool {
				switch {
				case v.IsError():
					bad = v
				case v.kind == Number && fn(v.num):
					bad = NewError(ErrNum)
				}
				return bad.IsError()
			})
			if bad.IsError() {
				return bad
			}
			if stop.IsError() {
				return stop
			}
			continue
		}
		x, err := asNum(e.scalar(a))
		if err.IsError() {
			return err
		}
		if fn(x) {
			return NewError(ErrNum)
		}
	}
	return Value{}
}

// cells returns the cells of a range argument, row by row.
func (e *eval) cells(n *node) ([]Value, Value) {
	if !isRange(n) {
		return nil, NewError(ErrValue)
	}
	return e.grid(n.rng)
}

// line returns the cells of a range that is one row or one column.
func (e *eval) line(n *node) ([]Value, Value) {
	if !isRange(n) || n.rng.Cols() > 1 && n.rng.Rows() > 1 {
		return nil, NewError(ErrValue)
	}
	return e.grid(n.rng)
}

func average(sum Num, count int64, bad Value) Value {
	if bad.IsError() {
		return bad
	}
	if count == 0 {
		return NewError(ErrDiv)
	}
	return number(mulDiv(sum, 1, Num(count)))
}

func (e *eval) count(args []*node, all bool) Value {
	count := int64(0)
	for _, a := range args {
		if isRange(a) {
			bad := e.each(a.rng, func(v Value) bool {
				if all || v.kind == Number {
					count++
				}
				return false
			})
			if bad.IsError() {
				return bad
			}
			continue
		}
		v := e.scalar(a)
		if all {
			count++
			continue
		}
		if _, bad := asNum(v); !bad.IsError() && v.kind != Empty {
			count++
		}
	}
	return NewInt(count)
}

// sorted returns the numbers of a range in increasing order.
func (e *eval) sorted(n *node) ([]int, Value) {
	if !isRange(n) {
		return nil, NewError(ErrValue)
	}
	var xs []int
	bad := e.numbers([]*node{n}, func(x Num) bool {
		xs = append(xs, int(x))
		return false
	})
	if bad.IsError() {
		return nil, bad
	}
	if !e.c.spend(2 * len(xs)) {
		return nil, NewError(ErrLimit)
	}
	sort.Ints(xs)
	return xs, Value{}
}

func (e *eval) ordered(n *node) Value {
	xs, bad := e.sorted(n.args[0])
	if bad.IsError() {
		return bad
	}
	if n.name == "MEDIAN" {
		if len(xs) == 0 {
			return NewError(ErrNum)
		}
		mid := len(xs) / 2
		if len(xs)%2 == 1 {
			return NewNumber(Num(xs[mid]))
		}
		sum, ok := Add(Num(xs[mid-1]), Num(xs[mid]))
		if !ok {
			return NewError(ErrNum)
		}
		return average(sum, 2, Value{})
	}
	k, bad := e.whole(n.args[1])
	if bad.IsError() {
		return bad
	}
	if k < 1 || k > len(xs) {
		return NewError(ErrNum)
	}
	if n.name == "LARGE" {
		return NewNumber(Num(xs[len(xs)-k]))
	}
	return NewNumber(Num(xs[k-1]))
}

func (e *eval) rank(args []*node) Value {
	x, bad := asNum(e.scalar(args[0]))
	if bad.IsError() {
		return bad
	}
	if !isRange(args[1]) {
		return NewError(ErrValue)
	}
	up := false
	if len(args) == 3 {
		up, bad = asBool(e.scalar(args[2]))
		if bad.IsError() {
			return bad
		}
	}
	rank, found := int64(1), false
	bad = e.numbers(args[1:2], func(y Num) bool {
		switch {
		case y == x:
			found = true
		case (y < x) == up:
			rank++
		}
		return false
	})
	if bad.IsError() {
		return bad
	}
	if !found {
		return NewError(ErrNA)
	}
	return NewInt(rank)
}

func (e *eval) sumProduct(args []*node) Value {
	var acc []Num
	for i, a := range args {
		cells, bad := e.cells(a)
		if bad.IsError() {
			return bad
		}
		if i > 0 && (a.rng.Cols() != args[0].rng.Cols() || len(cells) != len(acc)) {
			return NewError(ErrValue)
		}
		for j, v := range cells {
			if v.IsError() {
				return v
			}
			x := Num(0)
			if v.kind == Number {
				x = v.num
			}
			if i == 0 {
				acc = append(acc, x)
				continue
			}
			var ok bool
			if acc[j], ok = Mul(acc[j], x); !ok {
				return NewError(ErrNum)
			}
		}
	}
	sum := Num(0)
	for _, x := range acc {
		var ok bool
		if sum, ok = Add(sum, x); !ok {
			return NewError(ErrNum)
		}
	}
	return NewNumber(sum)
}

// criterion is a condition such as 5, "red" or ">=10".
type criterion struct {
	op  byte
	val Value
}

func newCriterion(v Value) criterion {
	if v.kind != Text {
		return criterion{'=', v}
	}
	s, op := v.str, byte('=')
	switch {
	case strings.HasPrefix(s, "<="):
		op, s = nodeLE, s[2:]
	case strings.HasPrefix(s, ">="):
		op, s = nodeGE, s[2:]
	case strings.HasPrefix(s, "<>"):
		op, s = nodeNE, s[2:]
	case strings.HasPrefix(s, "<"), strings.HasPrefix(s, ">"), strings.HasPrefix(s, "="):
		op, s = s[0], s[1:]
	}
	return criterion{op, ParseData(s)}
}

func (c criterion) matches(v Value) bool {
	if c.val.kind == Empty && (c.op == '=' || c.op == nodeNE) {
		return (v.kind == Empty || v.kind == Text && v.str == "") == (c.op == '=')
	}
	if v.kind != c.val.kind || v.kind == Empty || v.kind == Error {
		return c.op == nodeNE
	}
	d := compare(v, c.val)
	switch c.op {
	case '<':
		return d < 0
	case '>':
		return d > 0
	case nodeLE:
		return d <= 0
	case nodeGE:
		return d >= 0
	case nodeNE:
		return d != 0
	}
	return d == 0
}

func (e *eval) countIf(args []*node) Value {
	cells, bad := e.cells(args[0])
	if bad.IsError() {
		return bad
	}
	want := e.scalar(args[1])
	if want.IsError() {
		return want
	}
	c, count := newCriterion(want), int64(0)
	if !e.c.spend(len(cells) * textCost(want)) {
		return NewError(ErrLimit)
	}
	for _, v := range cells {
		if c.matches(v) {
			count++
		}
	}
	return NewInt(count)
}

func (e *eval) sumIf(args []*node, mean bool) Value {
	cells, bad := e.cells(args[0])
	if bad.IsError() {
		return bad
	}
	want := e.scalar(args[1])
	if want.IsError() {
		return want
	}
	amounts := cells
	if len(args) == 3 {
		amounts, bad = e.cells(args[2])
		if bad.IsError() {
			return bad
		}
		if len(amounts) != len(cells) || args[2].rng.Cols() != args[0].rng.Cols() {
			return NewError(ErrValue)
		}
	}
	if !e.c.spend(len(cells) * textCost(want)) {
		return NewError(ErrLimit)
	}
	c := newCriterion(want)
	sum, count := Num(0), int64(0)
	for i, v := range cells {
		if !c.matches(v) {
			continue
		}
		a := amounts[i]
		if a.IsError() {
			return a
		}
		if a.kind != Number {
			continue
		}
		var ok bool
		if sum, ok = Add(sum, a.num); !ok {
			return NewError(ErrNum)
		}
		count++
	}
	if mean {
		return average(sum, count, Value{})
	}
	return NewNumber(sum)
}

func (e *eval) logic(args []*node, all bool) Value {
	seen, out := false, all
	check := func(v Value, loose bool) Value {
		if v.IsError() {
			return v
		}
		if loose && (v.kind == Text || v.kind == Empty) {
			return Value{}
		}
		b, bad := asBool(v)
		if bad.IsError() {
			return bad
		}
		seen = true
		if b != all {
			out = b
		}
		return Value{}
	}
	for _, a := range args {
		var bad Value
		if isRange(a) {
			stop := e.each(a.rng, func(v Value) bool {
				bad = check(v, true)
				return bad.IsError()
			})
			if !bad.IsError() {
				bad = stop
			}
		} else {
			bad = check(e.scalar(a), false)
		}
		if bad.IsError() {
			return bad
		}
	}
	if !seen {
		return NewError(ErrValue)
	}
	return NewBool(out)
}

// index is INDEX(range, row, [column]); in a single row the first number
// counts columns.
func (e *eval) index(args []*node) Value {
	if !isRange(args[0]) {
		return NewError(ErrValue)
	}
	r := args[0].rng
	if bad := e.fits(r); bad.IsError() {
		return bad
	}
	row, bad := e.whole(args[1])
	if bad.IsError() {
		return bad
	}
	col := 1
	if len(args) == 3 {
		col, bad = e.whole(args[2])
		if bad.IsError() {
			return bad
		}
	} else if r.Rows() == 1 {
		row, col = 1, row
	}
	if row < 1 || col < 1 || row > r.Rows() || col > r.Cols() {
		return NewError(ErrRef)
	}
	return e.cell(r.A.Sheet, r.A.Col+col-1, r.A.Row+row-1)
}

// position returns where key is in a line of cells, from 0, or -1.
func position(key Value, cells []Value) int {
	for i, v := range cells {
		if same(key, v) {
			return i
		}
	}
	return -1
}

func (e *eval) match(args []*node) Value {
	key := e.scalar(args[0])
	if key.IsError() {
		return key
	}
	cells, bad := e.line(args[1])
	if bad.IsError() {
		return bad
	}
	mode, bad := e.whole(args[2])
	if bad.IsError() {
		return bad
	}
	if mode != 0 {
		return NewError(ErrNA)
	}
	if !e.c.spend(len(cells) * textCost(key)) {
		return NewError(ErrLimit)
	}
	i := position(key, cells)
	if i < 0 {
		return NewError(ErrNA)
	}
	return NewInt(int64(i + 1))
}

func (e *eval) lookup(args []*node) Value {
	key := e.scalar(args[0])
	if key.IsError() {
		return key
	}
	keys, bad := e.line(args[1])
	if bad.IsError() {
		return bad
	}
	vals, bad := e.line(args[2])
	if bad.IsError() {
		return bad
	}
	if len(keys) != len(vals) {
		return NewError(ErrValue)
	}
	if !e.c.spend(len(keys) * textCost(key)) {
		return NewError(ErrLimit)
	}
	if i := position(key, keys); i >= 0 {
		return vals[i]
	}
	if len(args) == 4 {
		return e.scalar(args[3])
	}
	return NewError(ErrNA)
}

// join is CONCAT(values...) and TEXTJOIN(separator, skip empty, values...).
func (e *eval) join(n *node) Value {
	args, sep, skip := n.args, "", false
	if n.name == "TEXTJOIN" {
		v := e.scalar(args[0])
		if v.IsError() {
			return v
		}
		sep = v.String()
		var bad Value
		skip, bad = asBool(e.scalar(args[1]))
		if bad.IsError() {
			return bad
		}
		args = args[2:]
	}
	var out []string
	size := 0
	for _, a := range args {
		var cells []Value
		if isRange(a) {
			var bad Value
			cells, bad = e.grid(a.rng)
			if bad.IsError() {
				return bad
			}
		} else {
			cells = []Value{e.scalar(a)}
		}
		for _, v := range cells {
			if v.IsError() {
				return v
			}
			s := v.String()
			if s == "" && skip {
				continue
			}
			size += len(s) + len(sep)
			if size > MaxText+len(sep) {
				return NewError(ErrLimit)
			}
			out = append(out, s)
		}
	}
	return NewText(strings.Join(out, sep))
}

// textFunc handles functions that count characters.
func textFunc(name, s string, v [4]Value, count int) Value {
	if name == "FIND" { // FIND(needle, text, [start])
		return find(s, v[1].String(), v[2], count == 3)
	}
	n := 1
	if count > 1 {
		x, bad := asNum(v[1])
		if bad.IsError() {
			return bad
		}
		n = small(x)
	}
	if n < 0 {
		return NewError(ErrValue)
	}
	if name == "REPT" {
		if n*len(s) > MaxText {
			return NewError(ErrLimit)
		}
		return NewText(strings.Repeat(s, n))
	}
	r := []rune(s)
	switch name {
	case "LEFT":
		if n < len(r) {
			r = r[:n]
		}
	case "RIGHT":
		if n < len(r) {
			r = r[len(r)-n:]
		}
	case "MID":
		x, bad := asNum(v[2])
		if bad.IsError() {
			return bad
		}
		size := small(x)
		if n < 1 || size < 0 {
			return NewError(ErrValue)
		}
		if n > len(r) {
			return NewText("")
		}
		r = r[n-1:]
		if size < len(r) {
			r = r[:size]
		}
	}
	return NewText(string(r))
}

func find(needle, s string, from Value, hasFrom bool) Value {
	start := 1
	if hasFrom {
		x, bad := asNum(from)
		if bad.IsError() {
			return bad
		}
		start = small(x)
	}
	r := []rune(s)
	if start < 1 || start > len(r)+1 {
		return NewError(ErrValue)
	}
	tail := string(r[start-1:])
	i := strings.Index(tail, needle)
	if i < 0 {
		return NewError(ErrValue)
	}
	return NewInt(int64(start + len([]rune(tail[:i]))))
}

// fixed formats a number with thousands separators unless plain is set.
func fixed(a Num, places int, plain bool) Value {
	show := places
	if show < 0 {
		r, ok := Round(a, places)
		if !ok {
			return NewError(ErrNum)
		}
		a, show = r, 0
	}
	extra := 0
	if show > decimals {
		if show > 20 {
			return NewError(ErrValue)
		}
		extra, show = show-decimals, decimals
	}
	s, ok := a.Fixed(show)
	if !ok {
		return NewError(ErrNum)
	}
	if extra > 0 {
		s += strings.Repeat("0", extra)
	}
	if plain {
		return NewText(s)
	}
	sign := ""
	if s[0] == '-' {
		sign, s = "-", s[1:]
	}
	whole, frac := s, ""
	if i := strings.IndexByte(s, '.'); i >= 0 {
		whole, frac = s[:i], s[i:]
	}
	for i := len(whole) - 3; i > 0; i -= 3 {
		whole = whole[:i] + "," + whole[i:]
	}
	return NewText(sign + whole + frac)
}

// bar draws value as a share of max, such as "██████░░░░".
func bar(value, max Num, width int) Value {
	if max <= 0 || width < 1 || width > 40 {
		return NewError(ErrNum)
	}
	if value < 0 {
		value = 0
	}
	if value > max {
		value = max
	}
	full, _ := mulDiv(value, Num(width), max)
	return NewText(strings.Repeat("█", int(full)) + strings.Repeat("░", width-int(full)))
}

// spark draws the numbers of a range as a line of blocks, such as "▁▃▇▅".
func (e *eval) spark(n *node) Value {
	if !isRange(n) {
		return NewError(ErrValue)
	}
	var xs []Num
	bad := e.numbers([]*node{n}, func(x Num) bool {
		xs = append(xs, x)
		return false
	})
	if bad.IsError() {
		return bad
	}
	if len(xs) == 0 {
		return NewText("")
	}
	if len(xs) > 100 {
		return NewError(ErrLimit)
	}
	lo, hi := xs[0], xs[0]
	for _, x := range xs {
		if x < lo {
			lo = x
		}
		if x > hi {
			hi = x
		}
	}
	span, ok := Sub(hi, lo)
	if !ok {
		return NewError(ErrNum)
	}
	blocks := []string{"▁", "▂", "▃", "▄", "▅", "▆", "▇", "█"}
	s := ""
	for _, x := range xs {
		level := Num(3)
		if span > 0 {
			level, _ = mulDiv(x-lo, 7, span)
		}
		s += blocks[int(level)]
	}
	return NewText(s)
}

// host passes a function to the Book. References stay references.
func (e *eval) host(n *node) (Value, bool) {
	switch n.name {
	case "HEIGHT", "NOW", "OWNER", "BALANCE", "TOKEN", "EDITOR", "EDITED":
	default:
		return Value{}, false
	}
	if !e.c.spend(20) {
		return NewError(ErrLimit), true
	}
	byRef := n.name == "EDITOR" || n.name == "EDITED"
	var args []Arg
	for _, a := range n.args {
		if byRef {
			if a.kind != nodeRef {
				return NewError(ErrValue), true
			}
			if bad := e.fits(a.rng); bad.IsError() {
				return bad, true
			}
			r := a.rng
			if r.A.Sheet == "" {
				r.A.Sheet = e.at.sheet
			}
			args = append(args, Arg{Range: r, IsRef: true})
			continue
		}
		v := e.scalar(a)
		if v.IsError() {
			return v, true
		}
		args = append(args, Arg{Value: v})
	}
	v, ok := e.c.book.Host(e.at.sheet, n.name, args)
	if !ok {
		return NewError(ErrName), true
	}
	return v, true
}
