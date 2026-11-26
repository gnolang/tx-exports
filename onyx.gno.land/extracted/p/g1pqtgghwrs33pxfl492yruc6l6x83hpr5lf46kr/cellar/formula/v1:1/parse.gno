package formula

import (
	"errors"
	"strconv"
	"strings"
)

const (
	// MaxSource is the longest cell content, in bytes.
	MaxSource = 256
	maxDepth  = 24 // nesting of parentheses, calls and signs
)

// Node kinds. Operators use their own character.
const (
	nodeConst = 'k'
	nodeRef   = 'r'
	nodeRange = 'R'
	nodeCall  = 'c'
	nodeNeg   = '~'
	nodePct   = '%'
	nodeLE    = 'l' // <=
	nodeGE    = 'g' // >=
	nodeNE    = '!' // <>
)

// node is a parsed expression.
type node struct {
	kind byte
	val  Value  // constants
	name string // function name
	rng  Range  // references
	args []*node
}

// Formula is a parsed formula.
type Formula struct {
	root *node
}

// IsFormula reports whether cell content is a formula rather than data.
func IsFormula(src string) bool { return len(src) > 0 && src[0] == '=' }

// Parse parses a formula, including its leading "=".
func Parse(src string) (*Formula, error) {
	if !IsFormula(src) {
		return nil, errors.New("a formula starts with =")
	}
	if len(src) > MaxSource {
		return nil, errors.New("a formula is at most " + strconv.Itoa(MaxSource) + " bytes")
	}
	p := &parser{src: src, pos: 1}
	p.next()
	n := p.expr(0)
	if p.err == nil && p.kind != tokEnd {
		p.fail("unexpected " + p.text())
	}
	if p.err != nil {
		return nil, p.err
	}
	return &Formula{n}, nil
}

// Refs returns the cells and ranges the formula mentions, in order.
func (f *Formula) Refs() []Range {
	var out []Range
	collectRefs(f.root, &out)
	return out
}

func collectRefs(n *node, out *[]Range) {
	if n.kind == nodeRef || n.kind == nodeRange {
		*out = append(*out, n.rng)
	}
	for _, a := range n.args {
		collectRefs(a, out)
	}
}

// Shift rewrites a formula copied dcol columns right and drow rows down: the
// parts of each reference without a "$" move along. It fails if a reference
// would leave the sheet. Data is returned unchanged.
func Shift(src string, dcol, drow int) (string, error) {
	if !IsFormula(src) {
		return src, nil
	}
	if _, err := Parse(src); err != nil {
		return "", err
	}
	p := &parser{src: src, pos: 1}
	out, last := "", 0
	for p.next(); p.kind != tokEnd; p.next() {
		if p.kind != tokRef {
			continue
		}
		r := p.ref
		if !r.AbsCol {
			r.Col += dcol
		}
		if !r.AbsRow {
			r.Row += drow
		}
		if r.Col < 1 || r.Col > MaxCols || r.Row < 1 || r.Row > MaxRows {
			return "", errors.New("the copy would refer to a cell outside the sheet")
		}
		out += src[last:p.start] + r.String()
		last = p.end
	}
	out += src[last:]
	if len(out) > MaxSource {
		return "", errors.New("the copied formula is too long")
	}
	return out, nil
}

// Token kinds.
const (
	tokEnd = iota
	tokNum
	tokText
	tokName
	tokRef
	tokOp
	tokErr
)

// parser holds the source and the current token. Its fields are set one by one
// because copying a struct for every token is slow in the GnoVM.
type parser struct {
	src   string
	pos   int // where the next token starts
	depth int
	err   error

	kind       int
	start, end int    // of the current token
	op         byte   // tokOp
	num        Num    // tokNum
	str        string // tokText, tokName (upper case), tokErr
	ref        Ref    // tokRef
}

func (p *parser) fail(msg string) {
	if p.err == nil {
		p.err = errors.New("at character " + strconv.Itoa(p.start+1) + ": " + msg)
	}
	p.kind, p.start, p.end, p.pos = tokEnd, len(p.src), len(p.src), len(p.src)
}

// text describes the current token for a message.
func (p *parser) text() string {
	if p.kind == tokEnd {
		return "end of formula"
	}
	return strconv.Quote(p.src[p.start:p.end])
}

func (p *parser) isOp(op byte) bool { return p.kind == tokOp && p.op == op }

// next scans one token.
func (p *parser) next() {
	src, i := p.src, p.pos
	for i < len(src) && (src[i] == ' ' || src[i] == '\t') {
		i++
	}
	p.start, p.end = i, i
	if i == len(src) {
		p.kind = tokEnd
		return
	}
	c := src[i]
	if c >= 'A' && c <= 'Z' || c >= 'a' && c <= 'z' || c == '$' || c == '_' {
		p.word(i)
		return
	}
	if c >= '0' && c <= '9' || c == '.' {
		j := i + 1
		for j < len(src) && (src[j] >= '0' && src[j] <= '9' || src[j] == '.') {
			j++
		}
		n, ok := ParseNum(src[i:j])
		if !ok {
			p.fail("bad number " + src[i:j])
			return
		}
		p.num = n
		p.emit(tokNum, j)
		return
	}
	switch c {
	case '+', '-', '*', '/', '^', '&', '=', '%', '(', ')', ',', ':':
		p.op = c
		p.emit(tokOp, i+1)
	case '<', '>':
		p.op = c
		j := i + 1
		if j < len(src) {
			switch {
			case src[j] == '=' && c == '<':
				p.op = nodeLE
				j++
			case src[j] == '=':
				p.op = nodeGE
				j++
			case src[j] == '>' && c == '<':
				p.op = nodeNE
				j++
			}
		}
		p.emit(tokOp, j)
	case '"':
		p.quoted(i)
	case '#':
		for _, code := range []string{ErrDiv, ErrValue, ErrRef, ErrName, ErrNum, ErrNA, ErrCycle, ErrLimit} {
			if strings.HasPrefix(src[i:], code) {
				p.str = code
				p.emit(tokErr, i+len(code))
				return
			}
		}
		p.fail("unknown error value")
	default:
		p.fail("unexpected character")
	}
}

// emit makes the text from p.start to end the current token.
func (p *parser) emit(kind, end int) {
	p.kind, p.end, p.pos = kind, end, end
}

// quoted scans a text in quotes, where "" stands for one quote.
func (p *parser) quoted(i int) {
	src, s := p.src, ""
	i++
	from := i
	for ; i < len(src); i++ {
		if src[i] != '"' {
			continue
		}
		s += src[from:i]
		if i+1 == len(src) || src[i+1] != '"' {
			p.str = s
			p.emit(tokText, i+1)
			return
		}
		s += "\""
		i++
		from = i + 1
	}
	p.fail("text is missing its closing quote")
}

// word scans a cell, a cell on another sheet, or a name.
func (p *parser) word(i int) {
	src := p.src
	if r, n := scanRef(src[i:]); n > 0 {
		if end := i + n; end == len(src) || src[end] != '!' {
			p.ref = r
			p.emit(tokRef, end)
			return
		}
	}
	j := i
	for j < len(src) && isWord(src[j]) {
		j++
	}
	if j == i {
		p.fail("bad reference")
		return
	}
	if j == len(src) || src[j] != '!' {
		p.str = strings.ToUpper(src[i:j])
		p.emit(tokName, j)
		return
	}
	r, n := scanRef(src[j+1:])
	if n == 0 {
		p.fail("expected a cell after " + src[i:j] + "!")
		return
	}
	r.Sheet = strings.ToLower(src[i:j])
	p.ref = r
	p.emit(tokRef, j+1+n)
}

// power returns how tightly the current token binds, as in other
// spreadsheets, or 0 if it is not a binary operator. All of them associate to
// the left.
func (p *parser) power() int {
	if p.kind != tokOp {
		return 0
	}
	switch p.op {
	case '+', '-':
		return 3
	case '*', '/':
		return 4
	case '=', '<', '>', nodeLE, nodeGE, nodeNE:
		return 1
	case '&':
		return 2
	case '^':
		return 5
	}
	return 0
}

// expr parses operators that bind tighter than min.
func (p *parser) expr(min int) *node {
	if !p.enter() {
		return nil
	}
	left := p.unary()
	for p.err == nil {
		bp := p.power()
		if bp <= min {
			break
		}
		op := p.op
		p.next()
		right := p.expr(bp)
		left = &node{kind: op, args: []*node{left, right}}
	}
	p.depth--
	return left
}

// enter counts a level of nesting.
func (p *parser) enter() bool {
	p.depth++
	if p.depth > maxDepth {
		p.fail("too deeply nested")
		return false
	}
	return true
}

// unary parses signs and "%". A sign binds tighter than "^", so -2^2 is 4.
func (p *parser) unary() *node {
	if p.isOp('-') || p.isOp('+') {
		neg := p.op == '-'
		if !p.enter() {
			return nil
		}
		p.next()
		n := p.unary()
		p.depth--
		if neg && p.err == nil {
			n = &node{kind: nodeNeg, args: []*node{n}}
		}
		return n
	}
	n := p.primary()
	for p.err == nil && p.isOp('%') {
		p.next()
		n = &node{kind: nodePct, args: []*node{n}}
	}
	return n
}

func (p *parser) primary() *node {
	var n *node
	switch p.kind {
	case tokNum:
		n = &node{kind: nodeConst, val: NewNumber(p.num)}
	case tokText:
		n = &node{kind: nodeConst, val: NewText(p.str)}
	case tokErr:
		n = &node{kind: nodeConst, val: NewError(p.str)}
	case tokRef:
		return p.reference()
	case tokName:
		return p.name()
	case tokOp:
		if p.op == '(' {
			p.next()
			n := p.expr(0)
			p.expect(')')
			return n
		}
	}
	if n == nil {
		p.fail("expected a value, found " + p.text())
		return nil
	}
	p.next()
	return n
}

// name parses TRUE, FALSE or a function call.
func (p *parser) name() *node {
	name, text, start := p.str, p.text(), p.start
	p.next()
	if p.isOp('(') {
		return p.call(name, start)
	}
	if name == "TRUE" || name == "FALSE" {
		return &node{kind: nodeConst, val: NewBool(name == "TRUE")}
	}
	p.start = start
	p.fail("unknown name " + text + " (cells run from A1 to Z" + strconv.Itoa(MaxRows) + ")")
	return nil
}

func (p *parser) reference() *node {
	a := p.ref
	p.next()
	if !p.isOp(':') {
		return &node{kind: nodeRef, rng: Range{a, a}}
	}
	p.next()
	if p.kind != tokRef {
		p.fail("expected a cell after :")
		return nil
	}
	b := p.ref
	if b.Sheet != "" && b.Sheet != a.Sheet {
		p.fail("a range must stay on one sheet")
		return nil
	}
	b.Sheet = ""
	p.next()
	return &node{kind: nodeRange, rng: Range{a, b}.ordered()}
}

func (p *parser) call(name string, start int) *node {
	lo, hi, ok := arity(name)
	if !ok {
		p.start = start
		p.fail("unknown function " + name)
		return nil
	}
	n := &node{kind: nodeCall, name: name}
	p.next() // the parenthesis
	if p.isOp(')') {
		p.next()
	} else {
		for p.err == nil {
			n.args = append(n.args, p.expr(0))
			if p.isOp(',') {
				p.next()
				continue
			}
			p.expect(')')
			break
		}
	}
	if p.err == nil && (len(n.args) < lo || len(n.args) > hi) {
		p.start = start
		p.fail(name + " takes " + countText(lo, hi))
	}
	return n
}

func (p *parser) expect(op byte) {
	if p.err != nil {
		return
	}
	if !p.isOp(op) {
		p.fail("expected " + string(rune(op)) + ", found " + p.text())
		return
	}
	p.next()
}

func countText(lo, hi int) string {
	s := strconv.Itoa(lo)
	if hi >= manyArgs {
		return s + " or more arguments"
	}
	if hi != lo {
		s += " to " + strconv.Itoa(hi)
	}
	if s == "1" {
		return "1 argument"
	}
	return s + " arguments"
}
