package cellar

import (
	"strconv"
	"unicode/utf8"

	"gno.land/p/g1pqtgghwrs33pxfl492yruc6l6x83hpr5lf46kr/cellar/formula/v1"
)

// locked reports whether a cell is frozen for good.
func (s *sheet) locked(col, row int) bool {
	for _, l := range s.locks {
		if l.Contains(col, row) {
			return true
		}
	}
	return false
}

// entrusted returns the grant that hands a cell over for good, or nil.
func (s *sheet) entrusted(col, row int) *grant {
	for i := range s.grants {
		if g := &s.grants[i]; g.sole && g.area.Contains(col, row) {
			return g
		}
	}
	return nil
}

// mayWrite returns "" if who may write src into a cell, or else the reason
// why not.
func (s *sheet) mayWrite(who address, col, row int, src string) string {
	if s.locked(col, row) {
		return "is locked for good"
	}
	if g := s.entrusted(col, row); g != nil {
		return s.allows(*g, who, col, row, src)
	}
	if who == s.owner {
		return ""
	}
	reason := notYours
	for _, g := range s.grants {
		if !g.area.Contains(col, row) {
			continue
		}
		r := s.allows(g, who, col, row, src)
		if r == "" {
			return ""
		}
		if r != notYours {
			reason = r
		}
	}
	return reason
}

const notYours = "is not yours to write"

// allows applies one grant to a cell in its area.
func (s *sheet) allows(g grant, who address, col, row int, src string) string {
	if g.who == who.String() {
		return ""
	}
	if g.who != anyone {
		return notYours
	}
	if e := s.get(col, row); e != nil && e.by != who {
		return "was filled by someone else"
	}
	if formula.IsFormula(src) {
		return "takes data from visitors, not formulas"
	}
	return ""
}

// mayLock returns "" if who may lock an area, or else the reason why not. An
// entrusted cell can only be locked by the address it is entrusted to.
func (s *sheet) mayLock(who address, a formula.Range) string {
	covered := false
	for _, g := range s.grants {
		if !g.sole || !g.area.Overlaps(a) {
			continue
		}
		if g.who != who.String() {
			return "is entrusted to someone else"
		}
		covered = covered || g.area.Covers(a)
	}
	if who != s.owner && !covered {
		return "can only be locked by the owner"
	}
	return ""
}

// write checks everything and changes one cell.
func (s *sheet) write(who address, col, row int, src string) {
	cell := formula.CellName(col, row)
	if reason := s.mayWrite(who, col, row, src); reason != "" {
		panic("cellar: " + cell + " " + reason)
	}
	if err := validate(src); err != "" {
		panic("cellar: " + cell + ": " + err)
	}
	s.put(who, col, row, src)
}

// validate returns what is wrong with the content of a cell, or "".
func validate(src string) string {
	if len(src) > formula.MaxSource {
		return "content is longer than " + strconv.Itoa(formula.MaxSource) + " bytes"
	}
	if !printable(src) {
		return "content has characters that cannot be shown"
	}
	if formula.IsFormula(src) {
		if _, err := formula.Parse(src); err != nil {
			return err.Error()
		}
	}
	return ""
}

// printable rejects broken UTF-8 and control characters, line breaks included.
func printable(s string) bool {
	if !utf8.ValidString(s) {
		return false
	}
	for _, r := range s {
		if r < ' ' || r >= 0x7f && r < 0xa0 || r == 0x2028 || r == 0x2029 {
			return false
		}
	}
	return true
}

// validName accepts 2 to 24 lower case letters, digits and "_", starting with
// a letter. Formulas can then name the sheet without quoting.
func validName(name string) bool {
	if len(name) < 2 || len(name) > maxName {
		return false
	}
	for i := 0; i < len(name); i++ {
		c := name[i]
		letter := c >= 'a' && c <= 'z'
		if !letter && (i == 0 || (c < '0' || c > '9') && c != '_') {
			return false
		}
	}
	return !reserved(name)
}

// reserved names are pages of the realm.
func reserved(name string) bool {
	return name == "help" || name == "new" || name == "all"
}

func (s *sheet) assertOwner(who address) {
	if who != s.owner {
		panic("cellar: only the owner of " + s.name + " may do this")
	}
}
