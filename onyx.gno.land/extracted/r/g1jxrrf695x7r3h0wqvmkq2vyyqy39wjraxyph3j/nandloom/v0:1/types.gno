package nandloom

import (
	nl "gno.land/p/g1jxrrf695x7r3h0wqvmkq2vyyqy39wjraxyph3j/nandloom/v0"
)

const (
	MaxTitleLen                = 64
	MaxNotesLen                = 200
	MaxImportersCap            = 64
	MaxSubmissionsPerBuilder   = 64
	MaxSubmissionsPerChallenge = 512
	MaxDisplayRows             = 100
	MaxSnapshotChips           = 200
)

// ChipEntry stores an immutable verified circuit published on-chain.
// Immutability guarantees that higher-level chips importing chip:<slug> never
// break retroactively.
type ChipEntry struct {
	Slug          string
	ChallengeID   string
	Title         string
	Notes         string
	Author        address
	BlockHeight   int64
	Netlist       string
	AST           *nl.Circuit
	Compiled      *nl.CompiledCircuit
	NANDCount     int
	Depth         int
	ModuleCount   int
	ImportedChips []string
	ReuseCount    int
	Importers     []string
}

// ChallengeState tracks the specification, current record holder, and all
// verified chips solving a challenge.
type ChallengeState struct {
	Spec            nl.ChallengeSpec
	BestSlug        string
	BestNANDs       int
	BestDepth       int
	BestAuthor      address
	SubmissionSlugs []string
}

// BuilderProfile tracks objective, deterministic builder achievements.
type BuilderProfile struct {
	Address          address
	ChipsSubmitted   int
	RecordsHeld      int
	TotalReuses      int
	SolvedChallenges map[string]bool
}
