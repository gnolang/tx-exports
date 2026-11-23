package nandloom

// Resource caps enforced during parsing, compilation, and simulation to keep
// execution gas bounded inside GnoVM.
const (
	MaxNetlistBytes = 4096
	MaxLines        = 128
	MaxStatements   = 64
	MaxInputs       = 12
	MaxOutputs      = 8
	MaxFlatGates    = 128
	MaxChipDepth    = 6
	MaxTestVectors  = 64
	MaxIdentLen     = 24
	MaxSlugLen      = 32
)

// OpKind identifies the operation executed by a netlist statement.
type OpKind int

const (
	OpNAND OpKind = iota
	OpConst0
	OpConst1
	OpBuf
	OpChip
)

// String returns the canonical DSL name of an operation.
func (op OpKind) String() string {
	switch op {
	case OpNAND:
		return "nand"
	case OpConst0:
		return "const0"
	case OpConst1:
		return "const1"
	case OpBuf:
		return "buf"
	case OpChip:
		return "chip"
	default:
		return "unknown"
	}
}

// Statement is one parsed assignment in a netlist:
//
//	out0[, out1...] = op(arg0[, arg1...])
type Statement struct {
	Line     int
	Outputs  []string
	Op       OpKind
	ChipSlug string // populated only when Op == OpChip
	Args     []string
}

// Circuit is a parsed, syntactically valid netlist AST.
type Circuit struct {
	Inputs     []string
	Outputs    []string
	Statements []Statement
	Raw        string
}

// ChipResolver looks up a verified sub-chip circuit by slug.
// Returning (nil, false) marks the slug as unknown.
type ChipResolver func(slug string) (*Circuit, bool)

// FlatGate is a single primitive operation in the flattened, topologically
// ordered evaluation graph.
type FlatGate struct {
	Out   string
	Op    OpKind // OpNAND, OpConst0, OpConst1, or OpBuf
	A     string
	B     string
	Depth int // propagation depth in NAND layers from primary inputs
}

// CompiledCircuit holds a cycle-checked, flattened circuit with exact
// uncheatable metrics (true flattened NAND count and critical-path depth).
type CompiledCircuit struct {
	AST           *Circuit
	TopOrder      []int // topological order of AST.Statements indices
	StmtDepth     []int // column depth (1..MaxCol) per AST.Statements index
	StmtNANDs     []int // flattened NAND cost contributed by each AST statement
	MaxCol        int   // max visual column among statements
	FlatGates     []FlatGate
	NANDCount     int      // total flattened NAND primitive gates
	MaxDepth      int      // longest NAND gate chain from input to output
	ImportedChips []string // sorted unique direct sub-chip slugs
	ModuleCount   int      // number of top-level statements
}

// Trace records every wire value produced by a single evaluation run.
type Trace struct {
	InputBits   string
	OutputBits  string
	WireValues  map[string]bool // primary inputs + all top-level statement outputs
	OutputVals  []bool
	InputVals   []bool
}

// TestVector defines one input-to-expected-output check for a challenge.
type TestVector struct {
	In    []bool
	Out   []bool
	Label string
}

// ChallengeSpec describes a verifiable digital logic challenge.
type ChallengeSpec struct {
	ID             string
	Title          string
	Summary        string
	Difficulty     string
	Inputs         []string
	Outputs        []string
	ParNANDs       int
	ParDepth       int
	Vectors        []TestVector
	StarterNetlist string
}

// VerifyResult summarizes exhaustive test-vector verification for a compiled circuit.
type VerifyResult struct {
	Passed        bool
	TotalVectors  int
	PassedVectors int
	FailedIndex   int // -1 when Passed == true
	FailLabel     string
	FailInput     string
	FailExpected  string
	FailActual    string
	NANDCount     int
	Depth         int
	ErrorMessage  string
}

// ReferenceChip pairs a challenge with a seeded reference netlist.
type ReferenceChip struct {
	ChallengeID string
	Slug        string
	Title       string
	Notes       string
	Netlist     string
}
