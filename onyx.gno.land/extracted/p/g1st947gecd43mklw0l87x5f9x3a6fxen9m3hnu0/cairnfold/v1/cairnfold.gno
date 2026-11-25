package cairnfold

import (
	"crypto/merkle"
	"encoding/binary"
	"encoding/hex"
	"errors"
	"strconv"
	"strings"
)

// SchemaV1 identifies canonical leaf schema version 1.
const SchemaV1 uint32 = 1

// MaxLeafCount bounds supported epoch roster sizes across encoder, decoder, and CLI.
const MaxLeafCount = 1_000_000

// Verification result codes returned by DecodeProofToken and VerifyToken.
const (
	CodeOK                  = "OK"
	CodeErrDecode           = "ERR_DECODE"
	CodeErrEpochNotFound    = "ERR_EPOCH_NOT_FOUND"
	CodeErrCallerMismatch   = "ERR_CALLER_MISMATCH"
	CodeErrIndexOutOfRange  = "ERR_INDEX_OUT_OF_RANGE"
	CodeErrAlreadyClaimed   = "ERR_ALREADY_CLAIMED"
	CodeErrMerkleProofMatch = "ERR_MERKLE_PROOF_MISMATCH"
)

// Member represents a single canonical roster entry.
type Member struct {
	Addr   address
	Weight uint64
	Role   string
}

// EpochView is the narrow read-only anchor view shared across realms.
type EpochView struct {
	ID               uint64
	Root             []byte
	RootHex          string
	LeafCount        int
	Purpose          string
	SealedHeight     int64
	SnapshotURI      string
	SnapshotVerified bool
	Folded           bool
}

// ProofToken represents a decoded single-string cf1:... claim proof.
type ProofToken struct {
	EpochID  uint64
	Index    int
	Total    int
	Addr     address
	Weight   uint64
	Role     string
	Aunts    []byte
	AuntsHex string
}

// VerifyResult carries a deterministic diagnostic code and explanation.
type VerifyResult struct {
	Code    string
	Message string
}

// OK reports whether verification succeeded.
func (r VerifyResult) OK() bool { return r.Code == CodeOK }

// IsValidRole checks ^[a-z0-9_-]{1,32}$ so delimiters cannot appear in role fields.
func IsValidRole(role string) bool {
	if len(role) == 0 || len(role) > 32 {
		return false
	}
	for i := 0; i < len(role); i++ {
		c := role[i]
		ok := (c >= 'a' && c <= 'z') || (c >= '0' && c <= '9') || c == '_' || c == '-'
		if !ok {
			return false
		}
	}
	return true
}

// IsValidPurpose checks 1..64 printable ASCII bytes excluding '|' and leading/trailing spaces.
func IsValidPurpose(purpose string) bool {
	if len(purpose) == 0 || len(purpose) > 64 {
		return false
	}
	if purpose[0] == ' ' || purpose[len(purpose)-1] == ' ' {
		return false
	}
	for i := 0; i < len(purpose); i++ {
		c := purpose[i]
		if c < 0x20 || c > 0x7e || c == '|' {
			return false
		}
	}
	return true
}

// IsCanonicalAddress checks that addr is a valid lowercase Gno bech32 address ("g1...").
func IsCanonicalAddress(addr address) bool {
	if !addr.IsValid() {
		return false
	}
	s := string(addr)
	if !strings.HasPrefix(s, "g1") {
		return false
	}
	for i := 0; i < len(s); i++ {
		c := s[i]
		if !((c >= 'a' && c <= 'z') || (c >= '0' && c <= '9')) {
			return false
		}
	}
	return true
}

// EncodeLeaf returns canonical SchemaV1 leaf bytes:
// cairnfold:v1|<epochID>|<addr>|<weight>|<role>
func EncodeLeaf(epochID uint64, addr address, weight uint64, role string) ([]byte, error) {
	if epochID == 0 {
		return nil, errors.New("epochID must be >= 1")
	}
	if !IsCanonicalAddress(addr) {
		return nil, errors.New("invalid canonical lowercase gno address")
	}
	if weight == 0 {
		return nil, errors.New("weight must be >= 1")
	}
	if !IsValidRole(role) {
		return nil, errors.New("invalid role")
	}
	s := "cairnfold:v1|" +
		strconv.FormatUint(epochID, 10) + "|" +
		string(addr) + "|" +
		strconv.FormatUint(weight, 10) + "|" +
		role
	return []byte(s), nil
}

// EncodeByteSlices frames leaves as [4-byte BE count][4-byte BE len_i][leaf_i]...
// matching gnovm/stdlibs/crypto/merkle.HashFromByteSlices.
func EncodeByteSlices(items [][]byte) []byte {
	totalBytes := 4
	for _, it := range items {
		totalBytes += 4 + len(it)
	}
	out := make([]byte, 4, totalBytes)
	binary.BigEndian.PutUint32(out[0:4], uint32(len(items)))
	var lenBuf [4]byte
	for _, it := range items {
		binary.BigEndian.PutUint32(lenBuf[:], uint32(len(it)))
		out = append(out, lenBuf[:]...)
		out = append(out, it...)
	}
	return out
}

// ComputeRoot computes the Tendermint Simple Merkle root over strictly ascending unique members.
func ComputeRoot(epochID uint64, sortedMembers []Member) ([]byte, error) {
	if len(sortedMembers) == 0 {
		return nil, errors.New("empty member list")
	}
	leaves := make([][]byte, len(sortedMembers))
	for i, m := range sortedMembers {
		if i > 0 && string(m.Addr) <= string(sortedMembers[i-1].Addr) {
			return nil, errors.New("members must be strictly sorted by unique address")
		}
		leaf, err := EncodeLeaf(epochID, m.Addr, m.Weight, m.Role)
		if err != nil {
			return nil, err
		}
		leaves[i] = leaf
	}
	root := merkle.HashFromByteSlices(EncodeByteSlices(leaves))
	if len(root) != 32 {
		return nil, errors.New("unexpected merkle root length")
	}
	return root, nil
}

func maxProofDepth(total int) int {
	if total <= 1 {
		return 0
	}
	depth := 0
	for v := total - 1; v > 0; v >>= 1 {
		depth++
	}
	return depth
}

func isCanonicalLowerHex(s string) bool {
	if len(s)%2 != 0 {
		return false
	}
	for i := 0; i < len(s); i++ {
		c := s[i]
		if !((c >= '0' && c <= '9') || (c >= 'a' && c <= 'f')) {
			return false
		}
	}
	return true
}

func validateAunts(total int, aunts []byte) error {
	if total <= 0 {
		return errors.New("total must be >= 1")
	}
	if total == 1 {
		if len(aunts) != 0 {
			return errors.New("single-leaf epoch must have empty aunts")
		}
		return nil
	}
	if len(aunts) == 0 || len(aunts)%32 != 0 {
		return errors.New("aunts byte length must be a positive multiple of 32")
	}
	if len(aunts) > 32*maxProofDepth(total) {
		return errors.New("aunts exceeds maximum tree depth")
	}
	return nil
}

// EncodeProofToken serializes a ProofToken into canonical cf1:... form.
func EncodeProofToken(p ProofToken) (string, error) {
	if p.EpochID == 0 {
		return "", errors.New("epochID must be >= 1")
	}
	if p.Total <= 0 || p.Total > MaxLeafCount || p.Index < 0 || p.Index >= p.Total {
		return "", errors.New("index or total out of allowed range")
	}
	if !IsCanonicalAddress(p.Addr) {
		return "", errors.New("invalid canonical lowercase address")
	}
	if p.Weight == 0 {
		return "", errors.New("weight must be >= 1")
	}
	if !IsValidRole(p.Role) {
		return "", errors.New("invalid role")
	}
	aunts := p.Aunts
	if len(aunts) == 0 && p.AuntsHex != "" {
		if !isCanonicalLowerHex(p.AuntsHex) {
			return "", errors.New("invalid lowercase hex in auntsHex")
		}
		dec, err := hex.DecodeString(p.AuntsHex)
		if err != nil {
			return "", err
		}
		aunts = dec
	}
	if err := validateAunts(p.Total, aunts); err != nil {
		return "", err
	}
	auntsHex := hex.EncodeToString(aunts)
	return "cf1:" +
		strconv.FormatUint(p.EpochID, 10) + ":" +
		strconv.Itoa(p.Index) + ":" +
		strconv.Itoa(p.Total) + ":" +
		string(p.Addr) + ":" +
		strconv.FormatUint(p.Weight, 10) + ":" +
		p.Role + ":" +
		auntsHex, nil
}

func parseCanonicalUint64(raw string) (uint64, bool) {
	if len(raw) == 0 {
		return 0, false
	}
	if len(raw) > 1 && raw[0] == '0' {
		return 0, false
	}
	for i := 0; i < len(raw); i++ {
		if raw[i] < '0' || raw[i] > '9' {
			return 0, false
		}
	}
	v, err := strconv.ParseUint(raw, 10, 64)
	if err != nil {
		return 0, false
	}
	return v, true
}

func parseCanonicalNonNegInt(raw string) (int, bool) {
	v, ok := parseCanonicalUint64(raw)
	if !ok || v > MaxLeafCount {
		return 0, false
	}
	return int(v), true
}

// DecodeProofToken parses and validates a canonical cf1:... proof token.
func DecodeProofToken(raw string) (ProofToken, VerifyResult) {
	parts := strings.Split(raw, ":")
	if len(parts) != 8 || parts[0] != "cf1" {
		return ProofToken{}, VerifyResult{Code: CodeErrDecode, Message: "token must have 8 ':'-separated parts starting with cf1"}
	}
	epochID, ok := parseCanonicalUint64(parts[1])
	if !ok || epochID == 0 {
		return ProofToken{}, VerifyResult{Code: CodeErrDecode, Message: "invalid epochID"}
	}
	index, ok := parseCanonicalNonNegInt(parts[2])
	if !ok {
		return ProofToken{}, VerifyResult{Code: CodeErrDecode, Message: "invalid index"}
	}
	total, ok := parseCanonicalNonNegInt(parts[3])
	if !ok || total <= 0 || index >= total {
		return ProofToken{}, VerifyResult{Code: CodeErrDecode, Message: "invalid total or index out of bounds"}
	}
	addr := address(parts[4])
	if !IsCanonicalAddress(addr) {
		return ProofToken{}, VerifyResult{Code: CodeErrDecode, Message: "invalid canonical lowercase gno address"}
	}
	weight, ok := parseCanonicalUint64(parts[5])
	if !ok || weight == 0 {
		return ProofToken{}, VerifyResult{Code: CodeErrDecode, Message: "invalid weight"}
	}
	role := parts[6]
	if !IsValidRole(role) {
		return ProofToken{}, VerifyResult{Code: CodeErrDecode, Message: "invalid role"}
	}
	auntsHex := parts[7]
	if !isCanonicalLowerHex(auntsHex) {
		return ProofToken{}, VerifyResult{Code: CodeErrDecode, Message: "auntsHex must be lowercase hex"}
	}
	aunts, err := hex.DecodeString(auntsHex)
	if err != nil {
		return ProofToken{}, VerifyResult{Code: CodeErrDecode, Message: "failed to decode auntsHex"}
	}
	if err := validateAunts(total, aunts); err != nil {
		return ProofToken{}, VerifyResult{Code: CodeErrDecode, Message: err.Error()}
	}
	return ProofToken{
		EpochID:  epochID,
		Index:    index,
		Total:    total,
		Addr:     addr,
		Weight:   weight,
		Role:     role,
		Aunts:    aunts,
		AuntsHex: auntsHex,
	}, VerifyResult{Code: CodeOK, Message: "decoded"}
}

// VerifyToken executes the ordered 6-code verification pipeline shared by gate/v1 and census/v1.
func VerifyToken(raw string, caller address, epoch *EpochView, bitmap []byte) (ProofToken, VerifyResult) {
	tok, decRes := DecodeProofToken(raw)
	if !decRes.OK() {
		return ProofToken{}, decRes
	}
	if epoch == nil || epoch.ID != tok.EpochID || len(epoch.Root) != 32 {
		return tok, VerifyResult{Code: CodeErrEpochNotFound, Message: "epoch anchor not found"}
	}
	if !IsCanonicalAddress(caller) || caller != tok.Addr {
		return tok, VerifyResult{Code: CodeErrCallerMismatch, Message: "caller does not match proof address"}
	}
	if tok.Total != epoch.LeafCount || tok.Index < 0 || tok.Index >= tok.Total {
		return tok, VerifyResult{Code: CodeErrIndexOutOfRange, Message: "proof total/index does not match sealed epoch leaf count"}
	}
	if IsBitSet(bitmap, tok.Index) {
		return tok, VerifyResult{Code: CodeErrAlreadyClaimed, Message: "leaf index already claimed for this epoch"}
	}
	leaf, err := EncodeLeaf(tok.EpochID, tok.Addr, tok.Weight, tok.Role)
	if err != nil {
		return tok, VerifyResult{Code: CodeErrDecode, Message: err.Error()}
	}
	if !merkle.VerifySimpleProof(epoch.Root, leaf, tok.Index, tok.Total, tok.Aunts) {
		return tok, VerifyResult{Code: CodeErrMerkleProofMatch, Message: "tendermint merkle proof verification failed"}
	}
	return tok, VerifyResult{Code: CodeOK, Message: "verified"}
}

// BitmapSize returns ceil(leafCount/8) bytes for compact 1-bit-per-leaf nullifiers
// without signed-integer addition overflow near math.MaxInt.
func BitmapSize(leafCount int) int {
	if leafCount <= 0 {
		return 0
	}
	return (leafCount-1)/8 + 1
}

// IsBitSet reports whether bit index is set in bitmap.
func IsBitSet(bitmap []byte, index int) bool {
	if index < 0 {
		return false
	}
	byteIdx := index / 8
	if byteIdx >= len(bitmap) {
		return false
	}
	return (bitmap[byteIdx] & (1 << uint(index%8))) != 0
}

// SetBit sets bit index in bitmap, returning true if it transitioned 0 -> 1.
func SetBit(bitmap []byte, index int) bool {
	if index < 0 {
		return false
	}
	byteIdx := index / 8
	if byteIdx >= len(bitmap) {
		return false
	}
	mask := byte(1 << uint(index%8))
	if (bitmap[byteIdx] & mask) != 0 {
		return false
	}
	bitmap[byteIdx] |= mask
	return true
}

// Popcount counts total set bits across bitmap.
func Popcount(bitmap []byte) int {
	total := 0
	for _, b := range bitmap {
		for x := b; x != 0; x &= x - 1 {
			total++
		}
	}
	return total
}
