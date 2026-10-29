package zkgm

import u256 "gno.land/p/onbloc/math/uint256"

// BURN_ADDRESS is the canonical zero burn address: bech32 of 20 zero bytes with
// the gno `g` HRP, matching union's get_burn_address = addr_humanize([0;20]).
// A market-maker ack naming this address burns the escrow instead of releasing it.
//
// reference: https://github.com/unionlabs/union/blob/d91c5e94354e15801bd5f82dc658eae3b79f2dad/cosmwasm/app/ucs03-zkgm/src/contract.rs#L3211
const BURN_ADDRESS = "g1qqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqluuxe"

// ZkgmPacket is the outer ZKGM packet envelope.
//
// Mirrors `ZkgmPacket` at com.rs:33.
type ZkgmPacket struct {
	Salt        [32]byte
	Path        *u256.Uint
	Instruction Instruction
}

// Instruction identifies an operation and carries its ABI-encoded operand.
//
// Mirrors `Instruction` at com.rs:40.
type Instruction struct {
	Version uint8
	Opcode  uint8
	Operand []byte
}

// Forward wraps another instruction for forwarding across a channel path.
//
// Mirrors `Forward` at com.rs:46.
type Forward struct {
	Path             *u256.Uint
	TimeoutHeight    uint64
	TimeoutTimestamp uint64
	Instruction      Instruction
}

// Call describes an application call instruction.
//
// Mirrors `Call` at com.rs:54.
type Call struct {
	Sender           []byte
	Eureka           bool
	ContractAddress  []byte
	ContractCalldata []byte
}

// Batch groups multiple instructions.
//
// Mirrors `Batch` at com.rs:61.
type Batch struct {
	Instructions []Instruction
}

// TokenOrderV1 is the legacy token order shape with token metadata fields.
//
// Mirrors `TokenOrderV1` at com.rs:66.
type TokenOrderV1 struct {
	Sender            []byte
	Receiver          []byte
	BaseToken         []byte
	BaseAmount        *u256.Uint
	BaseTokenSymbol   string
	BaseTokenName     string
	BaseTokenDecimals uint8
	BaseTokenPath     *u256.Uint
	QuoteToken        []byte
	QuoteAmount       *u256.Uint
}

// TokenOrderV2 is the current token order shape.
//
// Mirrors `TokenOrderV2` at com.rs:80.
type TokenOrderV2 struct {
	Sender      []byte
	Receiver    []byte
	BaseToken   []byte
	BaseAmount  *u256.Uint
	QuoteToken  []byte
	QuoteAmount *u256.Uint
	Kind        uint8
	Metadata    []byte
}

// TokenMetadata carries wrapped token implementation initialization data.
//
// Mirrors `TokenMetadata` at com.rs:92.
type TokenMetadata struct {
	Implementation []byte
	Initializer    []byte
}

// TokenInitializer holds token display metadata; decimals are metadata only, never used for scaling.
// Authority and Minter are the ZkgmERC20 initialize(...) EVM addresses (20 bytes each): the admin
// authority, and the address granted the minter role (the EVM ZKGM contract, named `zkgm` in the
// Solidity signature — see docs/guides/zkgm-packet-send/initialize.md). Leave them nil to encode
// the zero address, the default for callers that don't care about a real EVM authority/minter.
type TokenInitializer struct {
	Authority []byte
	Minter    []byte
	Name      string
	Symbol    string
	Decimals  uint8
}

// SolverMetadata carries market maker solver data.
//
// Mirrors `SolverMetadata` at com.rs:98.
type SolverMetadata struct {
	SolverAddress []byte
	Metadata      []byte
}

// Ack wraps an acknowledgement tag and payload.
//
// Mirrors `Ack` at com.rs:104.
type Ack struct {
	Tag      *u256.Uint
	InnerAck []byte
}

// BatchAck groups acknowledgement payloads.
//
// Mirrors `BatchAck` at com.rs:109.
type BatchAck struct {
	Acknowledgements [][]byte
}

// TokenOrderAck describes token order settlement acknowledgement data.
//
// Mirrors `TokenOrderAck` at com.rs:114.
type TokenOrderAck struct {
	FillType    *u256.Uint
	MarketMaker []byte
}
