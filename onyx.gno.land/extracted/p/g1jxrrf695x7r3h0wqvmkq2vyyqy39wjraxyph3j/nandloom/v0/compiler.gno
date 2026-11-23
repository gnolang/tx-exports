package nandloom

import (
	"errors"
	"sort"
	"strconv"

	"gno.land/p/nt/ufmt/v0"
)

// Compile validates wire references, rejects combinational cycles with Kahn's
// topological sort, recursively flattens imported sub-chips through resolve,
// enforces resource caps, and computes exact flattened NAND count & depth.
func Compile(c *Circuit, resolve ChipResolver) (*CompiledCircuit, error) {
	if c == nil {
		return nil, errors.New("nil circuit")
	}

	// 1. Top-level topological sort + column depth for schematic rendering.
	topOrder, stmtCol, maxCol, err := topoSort(c)
	if err != nil {
		return nil, err
	}

	// 2. Recursively flatten into primitive gates.
	flat := make([]FlatGate, 0, len(c.Statements)*2)
	stmtNANDs := make([]int, len(c.Statements))
	directChips := make(map[string]bool)
	visiting := make(map[string]bool)
	wireDepth := make(map[string]int)
	for i := 0; i < len(c.Inputs); i++ {
		wireDepth[c.Inputs[i]] = 0
	}

	instanceCounter := 0
	totalNANDs := 0

	var flattenCircuit func(cur *Circuit, prefix string, inputMap map[string]string, depth int) error
	flattenCircuit = func(cur *Circuit, prefix string, inputMap map[string]string, depth int) error {
		if depth > MaxChipDepth {
			return errors.New(ufmt.Sprintf("chip composition exceeds max nesting depth %d", MaxChipDepth))
		}
		order, _, _, terr := topoSort(cur)
		if terr != nil {
			return terr
		}
		mapWire := func(w string) string {
			if mapped, ok := inputMap[w]; ok {
				return mapped
			}
			if prefix == "" {
				return w
			}
			return prefix + w
		}

		for oi := 0; oi < len(order); oi++ {
			si := order[oi]
			st := cur.Statements[si]
			nandBefore := totalNANDs

			switch st.Op {
			case OpConst0, OpConst1:
				outName := mapWire(st.Outputs[0])
				wireDepth[outName] = 0
				flat = append(flat, FlatGate{
					Out:   outName,
					Op:    st.Op,
					Depth: 0,
				})
			case OpBuf:
				aName := mapWire(st.Args[0])
				outName := mapWire(st.Outputs[0])
				d := wireDepth[aName]
				wireDepth[outName] = d
				flat = append(flat, FlatGate{
					Out:   outName,
					Op:    OpBuf,
					A:     aName,
					Depth: d,
				})
			case OpNAND:
				if totalNANDs+1 > MaxFlatGates {
					return errors.New(ufmt.Sprintf("flattened circuit exceeds max %d NAND gates", MaxFlatGates))
				}
				aName := mapWire(st.Args[0])
				bName := mapWire(st.Args[1])
				outName := mapWire(st.Outputs[0])
				da := wireDepth[aName]
				db := wireDepth[bName]
				d := da
				if db > d {
					d = db
				}
				d++
				wireDepth[outName] = d
				totalNANDs++
				flat = append(flat, FlatGate{
					Out:   outName,
					Op:    OpNAND,
					A:     aName,
					B:     bName,
					Depth: d,
				})
			case OpChip:
				if resolve == nil {
					return errors.New(ufmt.Sprintf("line %d: chip:%s cannot be resolved (no resolver)", st.Line, st.ChipSlug))
				}
				if visiting[st.ChipSlug] {
					return errors.New(ufmt.Sprintf("line %d: recursive chip cycle involving chip:%s", st.Line, st.ChipSlug))
				}
				sub, ok := resolve(st.ChipSlug)
				if !ok || sub == nil {
					return errors.New(ufmt.Sprintf("line %d: unknown verified chip %q", st.Line, st.ChipSlug))
				}
				if len(st.Args) != len(sub.Inputs) {
					return errors.New(ufmt.Sprintf("line %d: chip:%s expects %d input(s), got %d", st.Line, st.ChipSlug, len(sub.Inputs), len(st.Args)))
				}
				if len(st.Outputs) != len(sub.Outputs) {
					return errors.New(ufmt.Sprintf("line %d: chip:%s produces %d output(s), got %d", st.Line, st.ChipSlug, len(sub.Outputs), len(st.Outputs)))
				}
				if depth == 0 {
					directChips[st.ChipSlug] = true
				}
				instanceCounter++
				subPrefix := "__c" + strconv.Itoa(instanceCounter) + "_"
				subInMap := make(map[string]string, len(sub.Inputs))
				for k := 0; k < len(sub.Inputs); k++ {
					subInMap[sub.Inputs[k]] = mapWire(st.Args[k])
				}
				visiting[st.ChipSlug] = true
				ferr := flattenCircuit(sub, subPrefix, subInMap, depth+1)
				delete(visiting, st.ChipSlug)
				if ferr != nil {
					return ferr
				}
				// Wire sub-chip outputs into caller's output wire names via zero-cost buffers.
				for k := 0; k < len(sub.Outputs); k++ {
					subOutWire := subPrefix + sub.Outputs[k]
					if mapped, exists := subInMap[sub.Outputs[k]]; exists {
						subOutWire = mapped
					}
					dstWire := mapWire(st.Outputs[k])
					d := wireDepth[subOutWire]
					wireDepth[dstWire] = d
					flat = append(flat, FlatGate{
						Out:   dstWire,
						Op:    OpBuf,
						A:     subOutWire,
						Depth: d,
					})
				}
			default:
				return errors.New(ufmt.Sprintf("line %d: unknown operation", st.Line))
			}

			if depth == 0 {
				stmtNANDs[si] = totalNANDs - nandBefore
			}
		}
		return nil
	}

	if err := flattenCircuit(c, "", map[string]string{}, 0); err != nil {
		return nil, err
	}

	// True critical-path propagation depth = max NAND depth across declared primary outputs.
	maxDepth := 0
	for i := 0; i < len(c.Outputs); i++ {
		if d := wireDepth[c.Outputs[i]]; d > maxDepth {
			maxDepth = d
		}
	}

	imported := make([]string, 0, len(directChips))
	for slug := range directChips {
		imported = append(imported, slug)
	}
	sort.Strings(imported)

	return &CompiledCircuit{
		AST:           c,
		TopOrder:      topOrder,
		StmtDepth:     stmtCol,
		StmtNANDs:     stmtNANDs,
		MaxCol:        maxCol,
		FlatGates:     flat,
		NANDCount:     totalNANDs,
		MaxDepth:      maxDepth,
		ImportedChips: imported,
		ModuleCount:   len(c.Statements),
	}, nil
}

// topoSort validates wire definitions and runs deterministic Kahn's topological sort
// over c.Statements, rejecting combinational cycles and computing visual column depths.
func topoSort(c *Circuit) ([]int, []int, int, error) {
	n := len(c.Statements)
	inputSet := make(map[string]bool, len(c.Inputs))
	for i := 0; i < len(c.Inputs); i++ {
		inputSet[c.Inputs[i]] = true
	}

	producer := make(map[string]int, n*2)
	for i := 0; i < n; i++ {
		st := c.Statements[i]
		for j := 0; j < len(st.Outputs); j++ {
			producer[st.Outputs[j]] = i
		}
	}

	inDeg := make([]int, n)
	adj := make([][]int, n)
	for i := 0; i < n; i++ {
		st := c.Statements[i]
		seenDep := make(map[int]bool)
		for j := 0; j < len(st.Args); j++ {
			arg := st.Args[j]
			if inputSet[arg] {
				continue
			}
			pIdx, ok := producer[arg]
			if !ok {
				return nil, nil, 0, errors.New(ufmt.Sprintf("line %d: undefined wire %q", st.Line, arg))
			}
			if pIdx == i {
				return nil, nil, 0, errors.New(ufmt.Sprintf("line %d: self-cycle on wire %q", st.Line, arg))
			}
			if !seenDep[pIdx] {
				seenDep[pIdx] = true
				adj[pIdx] = append(adj[pIdx], i)
				inDeg[i]++
			}
		}
	}

	// Deterministic queue: process ready indices in ascending source order.
	queue := make([]int, 0, n)
	colDepth := make([]int, n)
	for i := 0; i < n; i++ {
		if inDeg[i] == 0 {
			queue = append(queue, i)
			colDepth[i] = 1
		}
	}

	order := make([]int, 0, n)
	maxCol := 1
	for head := 0; head < len(queue); head++ {
		u := queue[head]
		order = append(order, u)
		if colDepth[u] > maxCol {
			maxCol = colDepth[u]
		}
		for k := 0; k < len(adj[u]); k++ {
			v := adj[u][k]
			if colDepth[u]+1 > colDepth[v] {
				colDepth[v] = colDepth[u] + 1
			}
			inDeg[v]--
			if inDeg[v] == 0 {
				queue = append(queue, v)
			}
		}
	}

	if len(order) != n {
		// Find first statement stuck in cycle for actionable diagnostics.
		for i := 0; i < n; i++ {
			if inDeg[i] > 0 {
				return nil, nil, 0, errors.New(ufmt.Sprintf("line %d: combinational cycle detected involving wire %q", c.Statements[i].Line, c.Statements[i].Outputs[0]))
			}
		}
		return nil, nil, 0, errors.New("combinational cycle detected")
	}

	return order, colDepth, maxCol, nil
}
