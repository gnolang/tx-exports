package assurance

import (
	"crypto/sha256"
	"encoding/binary"
	"errors"
)

const (
	DomainCheckpoint  = "arobi-checkpoint-v1"
	DomainExecReceipt = "arobi-exec-receipt-v1"
)

// ErrNonCanonicalOrder is returned when execution receipts in a batch are out of
// strictly increasing (Height, TxIndex) order or contain a duplicate pair.
var ErrNonCanonicalOrder = errors.New("execution receipts must be in strictly increasing (height, tx_index) order")

// CanonicalCheckpoint commits to a finalized BFT/execution-chain block header so an
// independent verifier or Gno.land realm can anchor external chain state deterministically.
// Validated in Experiment E14.
type CanonicalCheckpoint struct {
	ChainID            string
	Height             uint64
	HeaderHash         [32]byte
	AppHash            [32]byte
	ValidatorsHash     [32]byte
	NextValidatorsHash [32]byte
}

// Encode serializes CanonicalCheckpoint into canonical domain-separated big-endian bytes.
func (c CanonicalCheckpoint) Encode() ([]byte, error) {
	if c.ChainID == "" {
		return nil, errors.New("checkpoint chainID required")
	}
	if c.Height == 0 {
		return nil, errors.New("checkpoint height must be > 0")
	}
	out := make([]byte, 0, 192)
	out = appendString(out, DomainCheckpoint)
	out = append(out, EncodingVersion)
	out = appendString(out, c.ChainID)
	out = binary.BigEndian.AppendUint64(out, c.Height)
	out = append(out, c.HeaderHash[:]...)
	out = append(out, c.AppHash[:]...)
	out = append(out, c.ValidatorsHash[:]...)
	out = append(out, c.NextValidatorsHash[:]...)
	return out, nil
}

// Digest returns the SHA-256 commitment over CanonicalCheckpoint's canonical bytes.
func (c CanonicalCheckpoint) Digest() ([32]byte, error) {
	raw, err := c.Encode()
	if err != nil {
		return [32]byte{}, err
	}
	return sha256.Sum256(raw), nil
}

// ExecutionReceipt represents one deterministic contract/WASM/agent execution outcome
// recorded at a finalized block height and transaction index on an external chain.
type ExecutionReceipt struct {
	ChainID    string
	Height     uint64
	TxIndex    uint32
	TxHash     [32]byte
	Caller     string
	Contract   string
	GasUsed    uint64
	ExitCode   uint32
	ResultHash [32]byte
}

// Encode serializes ExecutionReceipt into canonical domain-separated big-endian bytes.
func (r ExecutionReceipt) Encode() ([]byte, error) {
	if r.ChainID == "" {
		return nil, errors.New("receipt chainID required")
	}
	if r.Height == 0 {
		return nil, errors.New("receipt height must be > 0")
	}
	if r.Caller == "" || r.Contract == "" {
		return nil, errors.New("receipt caller and contract required")
	}
	out := make([]byte, 0, 192)
	out = appendString(out, DomainExecReceipt)
	out = append(out, EncodingVersion)
	out = appendString(out, r.ChainID)
	out = binary.BigEndian.AppendUint64(out, r.Height)
	out = binary.BigEndian.AppendUint32(out, r.TxIndex)
	out = append(out, r.TxHash[:]...)
	out = appendString(out, r.Caller)
	out = appendString(out, r.Contract)
	out = binary.BigEndian.AppendUint64(out, r.GasUsed)
	out = binary.BigEndian.AppendUint32(out, r.ExitCode)
	out = append(out, r.ResultHash[:]...)
	return out, nil
}

// LeafHash returns the RFC 6962 leaf hash (SHA-256(0x00 || Encode())).
func (r ExecutionReceipt) LeafHash() ([32]byte, error) {
	raw, err := r.Encode()
	if err != nil {
		return [32]byte{}, err
	}
	return LeafHash(raw), nil
}

// BuildOrderedReceiptTree enforces strictly increasing lexicographic (Height, TxIndex)
// ordering and single-chain membership across a receipt batch, returning its RFC 6962
// Accumulator and Merkle root. Any out-of-order or duplicate pair fails closed with
// ErrNonCanonicalOrder so relayers cannot substitute non-reproducible roots.
func BuildOrderedReceiptTree(receipts []ExecutionReceipt) (*Accumulator, [32]byte, error) {
	if len(receipts) == 0 {
		return nil, [32]byte{}, errors.New("receipt batch cannot be empty")
	}
	acc := &Accumulator{}
	var prevHeight uint64
	var prevTx uint32
	chainID := receipts[0].ChainID
	for i, rec := range receipts {
		if rec.ChainID != chainID {
			return nil, [32]byte{}, errors.New("mixed chainID inside receipt batch")
		}
		if i > 0 {
			if rec.Height < prevHeight || (rec.Height == prevHeight && rec.TxIndex <= prevTx) {
				return nil, [32]byte{}, ErrNonCanonicalOrder
			}
		}
		leaf, err := rec.LeafHash()
		if err != nil {
			return nil, [32]byte{}, err
		}
		acc.Append(leaf)
		prevHeight = rec.Height
		prevTx = rec.TxIndex
	}
	return acc, acc.Root(), nil
}
