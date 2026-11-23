package nandloom

import (
	"errors"
	"strings"

	"gno.land/p/nt/ufmt/v0"
)

// IsValidIdent reports whether s is a valid wire identifier:
// lowercase ASCII letter followed by lowercase letters, digits, or underscores,
// bounded by MaxIdentLen. Leading underscores are reserved for internal flattening.
func IsValidIdent(s string) bool {
	if len(s) == 0 || len(s) > MaxIdentLen {
		return false
	}
	c0 := s[0]
	if c0 < 'a' || c0 > 'z' {
		return false
	}
	for i := 1; i < len(s); i++ {
		c := s[i]
		ok := (c >= 'a' && c <= 'z') || (c >= '0' && c <= '9') || c == '_'
		if !ok {
			return false
		}
	}
	return true
}

// IsValidSlug reports whether s is a valid chip or challenge slug:
// lowercase ASCII letter followed by lowercase letters, digits, underscores, or hyphens.
func IsValidSlug(s string) bool {
	if len(s) == 0 || len(s) > MaxSlugLen {
		return false
	}
	c0 := s[0]
	if c0 < 'a' || c0 > 'z' {
		return false
	}
	for i := 1; i < len(s); i++ {
		c := s[i]
		ok := (c >= 'a' && c <= 'z') || (c >= '0' && c <= '9') || c == '_' || c == '-'
		if !ok {
			return false
		}
	}
	return true
}

func isReservedName(s string) bool {
	switch s {
	case "in", "out", "nand", "buf", "const0", "const1", "chip":
		return true
	default:
		return false
	}
}

func splitIdentList(raw string, lineNum int, kind string) ([]string, error) {
	trimmed := strings.TrimSpace(raw)
	if trimmed == "" {
		return nil, errors.New(ufmt.Sprintf("line %d: empty %s list", lineNum, kind))
	}
	parts := strings.Split(trimmed, ",")
	out := make([]string, 0, len(parts))
	for i := 0; i < len(parts); i++ {
		tok := strings.TrimSpace(parts[i])
		if !IsValidIdent(tok) || isReservedName(tok) {
			return nil, errors.New(ufmt.Sprintf("line %d: invalid %s identifier %q", lineNum, kind, tok))
		}
		out = append(out, tok)
	}
	return out, nil
}

// Parse validates and parses a Nandloom netlist into an immutable Circuit AST.
func Parse(src string) (*Circuit, error) {
	if len(src) == 0 {
		return nil, errors.New("netlist is empty")
	}
	if len(src) > MaxNetlistBytes {
		return nil, errors.New(ufmt.Sprintf("netlist exceeds %d bytes", MaxNetlistBytes))
	}

	// Reject non-printable ASCII control bytes other than tab, LF, CR.
	for i := 0; i < len(src); i++ {
		b := src[i]
		if b < 0x20 && b != '\n' && b != '\r' && b != '\t' {
			return nil, errors.New("netlist contains disallowed control characters")
		}
		if b >= 0x7f {
			return nil, errors.New("netlist must be plain ASCII")
		}
	}

	norm := strings.ReplaceAll(src, "\r\n", "\n")
	norm = strings.ReplaceAll(norm, "\r", "\n")
	lines := strings.Split(norm, "\n")
	if len(lines) > MaxLines {
		return nil, errors.New(ufmt.Sprintf("netlist exceeds %d lines", MaxLines))
	}

	c := &Circuit{Raw: strings.TrimSpace(norm)}
	hasIn := false
	hasOut := false
	inputSet := make(map[string]bool)
	outputSet := make(map[string]bool)
	assigned := make(map[string]int) // wire -> line number

	for idx := 0; idx < len(lines); idx++ {
		lineNum := idx + 1
		line := lines[idx]
		if hash := strings.Index(line, "#"); hash >= 0 {
			line = line[:hash]
		}
		line = strings.TrimSpace(line)
		if line == "" {
			continue
		}

		// Header: "in a, b"
		if strings.HasPrefix(line, "in ") || strings.HasPrefix(line, "in\t") {
			if hasIn {
				return nil, errors.New(ufmt.Sprintf("line %d: duplicate 'in' declaration", lineNum))
			}
			if len(c.Statements) > 0 {
				return nil, errors.New(ufmt.Sprintf("line %d: 'in' must appear before statements", lineNum))
			}
			names, err := splitIdentList(line[2:], lineNum, "input")
			if err != nil {
				return nil, err
			}
			if len(names) > MaxInputs {
				return nil, errors.New(ufmt.Sprintf("line %d: too many inputs (%d > %d)", lineNum, len(names), MaxInputs))
			}
			for i := 0; i < len(names); i++ {
				if inputSet[names[i]] {
					return nil, errors.New(ufmt.Sprintf("line %d: duplicate input %q", lineNum, names[i]))
				}
				inputSet[names[i]] = true
			}
			c.Inputs = names
			hasIn = true
			continue
		}

		// Header: "out sum, carry"
		if strings.HasPrefix(line, "out ") || strings.HasPrefix(line, "out\t") {
			if hasOut {
				return nil, errors.New(ufmt.Sprintf("line %d: duplicate 'out' declaration", lineNum))
			}
			if len(c.Statements) > 0 {
				return nil, errors.New(ufmt.Sprintf("line %d: 'out' must appear before statements", lineNum))
			}
			names, err := splitIdentList(line[3:], lineNum, "output")
			if err != nil {
				return nil, err
			}
			if len(names) > MaxOutputs {
				return nil, errors.New(ufmt.Sprintf("line %d: too many outputs (%d > %d)", lineNum, len(names), MaxOutputs))
			}
			for i := 0; i < len(names); i++ {
				if outputSet[names[i]] {
					return nil, errors.New(ufmt.Sprintf("line %d: duplicate output %q", lineNum, names[i]))
				}
				if inputSet[names[i]] {
					return nil, errors.New(ufmt.Sprintf("line %d: output %q cannot share name with an input", lineNum, names[i]))
				}
				outputSet[names[i]] = true
			}
			c.Outputs = names
			hasOut = true
			continue
		}

		if !hasIn || !hasOut {
			return nil, errors.New(ufmt.Sprintf("line %d: declare 'in' and 'out' before statements", lineNum))
		}
		if len(c.Statements) >= MaxStatements {
			return nil, errors.New(ufmt.Sprintf("line %d: exceeds maximum %d statements", lineNum, MaxStatements))
		}

		// Statement: lhs = op(args)
		eq := strings.Index(line, "=")
		if eq <= 0 || eq == len(line)-1 {
			return nil, errors.New(ufmt.Sprintf("line %d: expected 'wire = op(args)'", lineNum))
		}
		lhsRaw := strings.TrimSpace(line[:eq])
		rhsRaw := strings.TrimSpace(line[eq+1:])

		lhs, err := splitIdentList(lhsRaw, lineNum, "wire")
		if err != nil {
			return nil, err
		}
		for i := 0; i < len(lhs); i++ {
			w := lhs[i]
			if inputSet[w] {
				return nil, errors.New(ufmt.Sprintf("line %d: cannot assign to input wire %q", lineNum, w))
			}
			if prev, exists := assigned[w]; exists {
				return nil, errors.New(ufmt.Sprintf("line %d: wire %q already assigned on line %d", lineNum, w, prev))
			}
			assigned[w] = lineNum
		}

		lp := strings.Index(rhsRaw, "(")
		rp := strings.LastIndex(rhsRaw, ")")
		if lp <= 0 || rp != len(rhsRaw)-1 || rp < lp+1 {
			return nil, errors.New(ufmt.Sprintf("line %d: malformed call %q", lineNum, rhsRaw))
		}
		opName := strings.TrimSpace(rhsRaw[:lp])
		argsRaw := strings.TrimSpace(rhsRaw[lp+1 : rp])

		var args []string
		if argsRaw != "" {
			args, err = splitIdentList(argsRaw, lineNum, "argument")
			if err != nil {
				return nil, err
			}
		}

		stmt := Statement{
			Line:    lineNum,
			Outputs: lhs,
			Args:    args,
		}

		if opName == "nand" {
			if len(lhs) != 1 {
				return nil, errors.New(ufmt.Sprintf("line %d: nand produces exactly 1 output", lineNum))
			}
			if len(args) != 2 {
				return nil, errors.New(ufmt.Sprintf("line %d: nand requires exactly 2 arguments", lineNum))
			}
			stmt.Op = OpNAND
		} else if opName == "buf" {
			if len(lhs) != 1 {
				return nil, errors.New(ufmt.Sprintf("line %d: buf produces exactly 1 output", lineNum))
			}
			if len(args) != 1 {
				return nil, errors.New(ufmt.Sprintf("line %d: buf requires exactly 1 argument", lineNum))
			}
			stmt.Op = OpBuf
		} else if opName == "const0" {
			if len(lhs) != 1 || len(args) != 0 {
				return nil, errors.New(ufmt.Sprintf("line %d: const0 takes 0 arguments and produces 1 output", lineNum))
			}
			stmt.Op = OpConst0
		} else if opName == "const1" {
			if len(lhs) != 1 || len(args) != 0 {
				return nil, errors.New(ufmt.Sprintf("line %d: const1 takes 0 arguments and produces 1 output", lineNum))
			}
			stmt.Op = OpConst1
		} else if strings.HasPrefix(opName, "chip:") {
			slug := strings.TrimSpace(opName[5:])
			if !IsValidSlug(slug) {
				return nil, errors.New(ufmt.Sprintf("line %d: invalid chip slug %q", lineNum, slug))
			}
			if len(args) == 0 {
				return nil, errors.New(ufmt.Sprintf("line %d: chip:%s requires at least 1 input argument", lineNum, slug))
			}
			stmt.Op = OpChip
			stmt.ChipSlug = slug
		} else {
			return nil, errors.New(ufmt.Sprintf("line %d: unsupported operation %q (allowed: nand, buf, const0, const1, chip:<slug>)", lineNum, opName))
		}

		c.Statements = append(c.Statements, stmt)
	}

	if !hasIn {
		return nil, errors.New("missing 'in' declaration")
	}
	if !hasOut {
		return nil, errors.New("missing 'out' declaration")
	}
	if len(c.Statements) == 0 {
		return nil, errors.New("netlist has no gate or chip statements")
	}

	// Ensure every declared output is produced by a statement.
	for i := 0; i < len(c.Outputs); i++ {
		outW := c.Outputs[i]
		if _, ok := assigned[outW]; !ok {
			return nil, errors.New(ufmt.Sprintf("declared output %q is never assigned", outW))
		}
	}

	return c, nil
}
