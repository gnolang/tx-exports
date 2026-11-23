package nandloom

import (
	"errors"
	"strings"

	"gno.land/p/nt/ufmt/v0"
)

// ParseBits parses a '0'/'1' bitstring of exact expectedLen.
func ParseBits(bits string, expectedLen int) ([]bool, error) {
	if len(bits) != expectedLen {
		return nil, errors.New(ufmt.Sprintf("expected %d input bits, got %d", expectedLen, len(bits)))
	}
	out := make([]bool, expectedLen)
	for i := 0; i < expectedLen; i++ {
		if bits[i] == '1' {
			out[i] = true
		} else if bits[i] == '0' {
			out[i] = false
		} else {
			return nil, errors.New(ufmt.Sprintf("invalid bit character %q at index %d (use 0 or 1)", string(bits[i]), i))
		}
	}
	return out, nil
}

// FormatBits converts a boolean slice into a '0'/'1' bitstring.
func FormatBits(vals []bool) string {
	var b strings.Builder
	for i := 0; i < len(vals); i++ {
		if vals[i] {
			b.WriteByte('1')
		} else {
			b.WriteByte('0')
		}
	}
	return b.String()
}

// Eval runs a single deterministic levelized pass over a CompiledCircuit.
func Eval(cc *CompiledCircuit, inputs []bool) (*Trace, error) {
	if cc == nil || cc.AST == nil {
		return nil, errors.New("nil compiled circuit")
	}
	if len(inputs) != len(cc.AST.Inputs) {
		return nil, errors.New(ufmt.Sprintf("expected %d inputs, got %d", len(cc.AST.Inputs), len(inputs)))
	}

	wires := make(map[string]bool, len(cc.AST.Inputs)+len(cc.FlatGates))
	inCopy := make([]bool, len(inputs))
	for i := 0; i < len(cc.AST.Inputs); i++ {
		wires[cc.AST.Inputs[i]] = inputs[i]
		inCopy[i] = inputs[i]
	}

	for i := 0; i < len(cc.FlatGates); i++ {
		g := cc.FlatGates[i]
		switch g.Op {
		case OpConst0:
			wires[g.Out] = false
		case OpConst1:
			wires[g.Out] = true
		case OpBuf:
			wires[g.Out] = wires[g.A]
		case OpNAND:
			wires[g.Out] = !(wires[g.A] && wires[g.B])
		}
	}

	outVals := make([]bool, len(cc.AST.Outputs))
	for i := 0; i < len(cc.AST.Outputs); i++ {
		outVals[i] = wires[cc.AST.Outputs[i]]
	}

	// Keep only top-level visible wires in Trace.WireValues so callers/renderers
	// stay clean and small.
	visible := make(map[string]bool, len(cc.AST.Inputs)+len(cc.AST.Statements)*2)
	for i := 0; i < len(cc.AST.Inputs); i++ {
		name := cc.AST.Inputs[i]
		visible[name] = wires[name]
	}
	for i := 0; i < len(cc.AST.Statements); i++ {
		st := cc.AST.Statements[i]
		for j := 0; j < len(st.Outputs); j++ {
			name := st.Outputs[j]
			visible[name] = wires[name]
		}
	}

	return &Trace{
		InputBits:  FormatBits(inCopy),
		OutputBits: FormatBits(outVals),
		WireValues: visible,
		OutputVals: outVals,
		InputVals:  inCopy,
	}, nil
}

// EvalBits evaluates a compiled circuit using a '0'/'1' bitstring.
func EvalBits(cc *CompiledCircuit, bits string) (*Trace, error) {
	if cc == nil || cc.AST == nil {
		return nil, errors.New("nil compiled circuit")
	}
	vals, err := ParseBits(bits, len(cc.AST.Inputs))
	if err != nil {
		return nil, err
	}
	return Eval(cc, vals)
}

// Verify checks pin signatures and runs all test vectors in spec against cc.
func Verify(cc *CompiledCircuit, spec ChallengeSpec) VerifyResult {
	res := VerifyResult{
		TotalVectors: len(spec.Vectors),
		FailedIndex:  -1,
	}
	if cc == nil || cc.AST == nil {
		res.ErrorMessage = "nil compiled circuit"
		return res
	}
	res.NANDCount = cc.NANDCount
	res.Depth = cc.MaxDepth

	if len(cc.AST.Inputs) != len(spec.Inputs) {
		res.ErrorMessage = ufmt.Sprintf("input pin count mismatch: challenge requires [%s], got [%s]",
			strings.Join(spec.Inputs, ", "), strings.Join(cc.AST.Inputs, ", "))
		return res
	}
	for i := 0; i < len(spec.Inputs); i++ {
		if cc.AST.Inputs[i] != spec.Inputs[i] {
			res.ErrorMessage = ufmt.Sprintf("input pin %d mismatch: expected %q, got %q", i, spec.Inputs[i], cc.AST.Inputs[i])
			return res
		}
	}
	if len(cc.AST.Outputs) != len(spec.Outputs) {
		res.ErrorMessage = ufmt.Sprintf("output pin count mismatch: challenge requires [%s], got [%s]",
			strings.Join(spec.Outputs, ", "), strings.Join(cc.AST.Outputs, ", "))
		return res
	}
	for i := 0; i < len(spec.Outputs); i++ {
		if cc.AST.Outputs[i] != spec.Outputs[i] {
			res.ErrorMessage = ufmt.Sprintf("output pin %d mismatch: expected %q, got %q", i, spec.Outputs[i], cc.AST.Outputs[i])
			return res
		}
	}

	limit := len(spec.Vectors)
	if limit > MaxTestVectors {
		limit = MaxTestVectors
	}
	res.TotalVectors = limit

	for i := 0; i < limit; i++ {
		vec := spec.Vectors[i]
		tr, err := Eval(cc, vec.In)
		if err != nil {
			res.FailedIndex = i
			res.ErrorMessage = err.Error()
			return res
		}
		expStr := FormatBits(vec.Out)
		if tr.OutputBits != expStr {
			res.FailedIndex = i
			res.FailLabel = vec.Label
			res.FailInput = FormatBits(vec.In)
			res.FailExpected = expStr
			res.FailActual = tr.OutputBits
			res.ErrorMessage = ufmt.Sprintf("vector #%d (%s) failed: in=%s expected=%s actual=%s",
				i+1, vec.Label, res.FailInput, expStr, tr.OutputBits)
			return res
		}
		res.PassedVectors++
	}

	res.Passed = true
	return res
}

// ExportGno emits a standalone, zero-dependency pure-Gno function equivalent to
// the verified compiled circuit so any realm can copy or embed it directly.
func ExportGno(slug string, cc *CompiledCircuit) string {
	if cc == nil || cc.AST == nil {
		return ""
	}
	fnName := toExportedGoName(slug)
	// Map every wire name to a Go-safe identifier so Go keywords (if, map, func,
	// return, etc.) never emit uncompilable exported code.
	safeMap := make(map[string]string)
	usedSafe := make(map[string]bool)
	mapIdent := func(raw string) string {
		if v, ok := safeMap[raw]; ok {
			return v
		}
		cand := raw
		if isGoKeywordOrPredeclared(cand) {
			cand = "w_" + cand
		}
		for usedSafe[cand] {
			cand = cand + "_"
		}
		safeMap[raw] = cand
		usedSafe[cand] = true
		return cand
	}

	safeInputs := make([]string, len(cc.AST.Inputs))
	for i := 0; i < len(cc.AST.Inputs); i++ {
		safeInputs[i] = mapIdent(cc.AST.Inputs[i])
	}
	safeOutputs := make([]string, len(cc.AST.Outputs))
	for i := 0; i < len(cc.AST.Outputs); i++ {
		safeOutputs[i] = mapIdent(cc.AST.Outputs[i])
	}

	var b strings.Builder
	b.WriteString(ufmt.Sprintf("// Generated by Nandloom (%d NANDs, depth %d)\n", cc.NANDCount, cc.MaxDepth))
	b.WriteString("func " + fnName + "(")
	b.WriteString(strings.Join(safeInputs, ", "))
	b.WriteString(" bool) (")
	b.WriteString(strings.Join(safeOutputs, ", "))
	b.WriteString(" bool) {\n")

	declared := make(map[string]bool)
	for i := 0; i < len(safeInputs); i++ {
		declared[safeInputs[i]] = true
	}
	for i := 0; i < len(safeOutputs); i++ {
		declared[safeOutputs[i]] = true
	}

	for i := 0; i < len(cc.FlatGates); i++ {
		g := cc.FlatGates[i]
		outID := mapIdent(g.Out)
		opAssign := ":="
		if declared[outID] {
			opAssign = "="
		} else {
			declared[outID] = true
		}
		switch g.Op {
		case OpConst0:
			b.WriteString(ufmt.Sprintf("\t%s %s false\n", outID, opAssign))
		case OpConst1:
			b.WriteString(ufmt.Sprintf("\t%s %s true\n", outID, opAssign))
		case OpBuf:
			b.WriteString(ufmt.Sprintf("\t%s %s %s\n", outID, opAssign, mapIdent(g.A)))
		case OpNAND:
			b.WriteString(ufmt.Sprintf("\t%s %s !(%s && %s)\n", outID, opAssign, mapIdent(g.A), mapIdent(g.B)))
		}
	}
	b.WriteString("\treturn\n}\n")
	return b.String()
}

func isGoKeywordOrPredeclared(s string) bool {
	switch s {
	case "break", "default", "func", "interface", "select",
		"case", "defer", "go", "map", "struct",
		"chan", "else", "goto", "package", "switch",
		"const", "fallthrough", "if", "range", "type",
		"continue", "for", "import", "return", "var",
		"bool", "true", "false", "nil", "iota":
		return true
	default:
		return false
	}
}

func toExportedGoName(slug string) string {
	parts := strings.FieldsFunc(slug, func(r rune) bool {
		return r == '_' || r == '-'
	})
	var b strings.Builder
	b.WriteString("Chip")
	for i := 0; i < len(parts); i++ {
		p := parts[i]
		if len(p) == 0 {
			continue
		}
		first := p[0]
		if first >= 'a' && first <= 'z' {
			first = first - 'a' + 'A'
		}
		b.WriteByte(first)
		b.WriteString(p[1:])
	}
	return b.String()
}
