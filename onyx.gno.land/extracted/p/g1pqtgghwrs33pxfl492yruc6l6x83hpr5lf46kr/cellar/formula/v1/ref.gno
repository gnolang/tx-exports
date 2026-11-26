package formula

import "strconv"

const (
	// MaxCols and MaxRows bound the cells a reference can name: A1 to Z999.
	MaxCols = 26
	MaxRows = 999
)

// Ref names one cell. Columns and rows count from 1.
type Ref struct {
	Sheet    string // "" for the sheet the formula is on
	Col, Row int
	// AbsCol and AbsRow record a "$", which keeps that part fixed when the
	// formula is copied.
	AbsCol, AbsRow bool
}

// Range names a rectangle of cells, A being its top left corner.
type Range struct {
	A, B Ref
}

// CellName returns the name of a cell, such as "B7".
func CellName(col, row int) string {
	return string(rune('A'+col-1)) + strconv.Itoa(row)
}

// ParseCell reads a plain cell name such as "B7" or "b7".
func ParseCell(s string) (col, row int, ok bool) {
	r, n := scanRef(s)
	if n == 0 || n != len(s) || r.AbsCol || r.AbsRow {
		return 0, 0, false
	}
	return r.Col, r.Row, true
}

// ParseArea reads "B2" or "B2:D9" and returns it with the corners ordered.
func ParseArea(s string) (Range, bool) {
	a, n := scanRef(s)
	if n == 0 {
		return Range{}, false
	}
	if n == len(s) {
		return Range{a, a}, true
	}
	if s[n] != ':' {
		return Range{}, false
	}
	b, m := scanRef(s[n+1:])
	if m == 0 || n+1+m != len(s) {
		return Range{}, false
	}
	return Range{a, b}.ordered(), true
}

// String returns the cell name with its "$" marks and sheet.
func (r Ref) String() string {
	s := ""
	if r.Sheet != "" {
		s = r.Sheet + "!"
	}
	if r.AbsCol {
		s += "$"
	}
	s += string(rune('A' + r.Col - 1))
	if r.AbsRow {
		s += "$"
	}
	return s + strconv.Itoa(r.Row)
}

// String returns the area, as "B2" or "B2:D9".
func (r Range) String() string {
	if r.A.Col == r.B.Col && r.A.Row == r.B.Row {
		return r.A.String()
	}
	return r.A.String() + ":" + r.B.String()
}

// Cols returns the width of the range.
func (r Range) Cols() int { return r.B.Col - r.A.Col + 1 }

// Rows returns the height of the range.
func (r Range) Rows() int { return r.B.Row - r.A.Row + 1 }

// Size returns the number of cells in the range.
func (r Range) Size() int { return r.Cols() * r.Rows() }

// Contains reports whether the cell lies inside the range.
func (r Range) Contains(col, row int) bool {
	return col >= r.A.Col && col <= r.B.Col && row >= r.A.Row && row <= r.B.Row
}

// Overlaps reports whether the two ranges share a cell.
func (r Range) Overlaps(o Range) bool {
	return r.A.Col <= o.B.Col && o.A.Col <= r.B.Col &&
		r.A.Row <= o.B.Row && o.A.Row <= r.B.Row
}

// Covers reports whether every cell of o lies inside r.
func (r Range) Covers(o Range) bool {
	return r.Contains(o.A.Col, o.A.Row) && r.Contains(o.B.Col, o.B.Row)
}

func (r Range) ordered() Range {
	if r.A.Col > r.B.Col {
		r.A.Col, r.B.Col = r.B.Col, r.A.Col
		r.A.AbsCol, r.B.AbsCol = r.B.AbsCol, r.A.AbsCol
	}
	if r.A.Row > r.B.Row {
		r.A.Row, r.B.Row = r.B.Row, r.A.Row
		r.A.AbsRow, r.B.AbsRow = r.B.AbsRow, r.A.AbsRow
	}
	return r
}

// scanRef reads a cell name at the start of s and returns its length, or 0.
func scanRef(s string) (Ref, int) {
	var r Ref
	i := 0
	if i < len(s) && s[i] == '$' {
		r.AbsCol = true
		i++
	}
	if i == len(s) {
		return Ref{}, 0
	}
	c := s[i]
	switch {
	case c >= 'A' && c <= 'Z':
		r.Col = int(c-'A') + 1
	case c >= 'a' && c <= 'z':
		r.Col = int(c-'a') + 1
	default:
		return Ref{}, 0
	}
	i++
	if i < len(s) && s[i] == '$' {
		r.AbsRow = true
		i++
	}
	start := i
	for i < len(s) && s[i] >= '0' && s[i] <= '9' {
		if i-start == 3 {
			return Ref{}, 0
		}
		r.Row = r.Row*10 + int(s[i]-'0')
		i++
	}
	if i == start || s[start] == '0' {
		return Ref{}, 0
	}
	if i < len(s) && isWord(s[i]) {
		return Ref{}, 0
	}
	return r, i
}

func isWord(c byte) bool {
	return c >= 'A' && c <= 'Z' || c >= 'a' && c <= 'z' || c >= '0' && c <= '9' || c == '_'
}
