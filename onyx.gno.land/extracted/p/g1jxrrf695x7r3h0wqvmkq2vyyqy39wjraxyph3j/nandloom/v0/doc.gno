// Package nandloom implements a deterministic, pure-Gno digital logic circuit
// parser, composable sub-chip compiler, levelized simulator, challenge verifier,
// Gno code exporter, and SVG schematic/waveform renderer.
//
// Circuits are written in a strict line-oriented netlist DSL using universal
// NAND gates and previously verified on-chain sub-chips:
//
//	in a, b
//	out sum, carry
//	w1 = nand(a, b)
//	w2 = nand(a, w1)
//	w3 = nand(b, w1)
//	sum = nand(w2, w3)
//	carry = nand(w1, w1)
//
// Composite chips import other verified circuits by slug via a ChipResolver:
//
//	in a, b, cin
//	out sum, cout
//	s1, c1 = chip:half_adder_ref(a, b)
//	sum, c2 = chip:half_adder_ref(s1, cin)
//	cout = chip:or2_ref(c1, c2)
//
// Every circuit is cycle-checked with Kahn's topological sort, flattened to
// primitive NAND gates for uncheatable gate-count and critical-path depth
// scoring, bounded by strict resource caps, and rendered directly to gnoweb-safe
// SVG data URIs via gno.land/p/nt/svg/v0.
package nandloom
