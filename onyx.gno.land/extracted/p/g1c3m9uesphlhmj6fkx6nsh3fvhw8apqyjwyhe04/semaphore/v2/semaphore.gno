// Package semaphore implements reusable Veil Primitives for Semaphore v4
// zero-knowledge membership verification on Gno.land:
//   - Canonical message/scope hashing matching Semaphore v4 (keccak256 >> 8)
//   - Application-scoped domain separation
//   - Identity commitment validation
//   - Authorized group-root management (explicitly documented root-publisher model)
//   - Depth-checked Groth16 verification via Veil Core (groth16)
//   - Persistent scoped nullifier tracking
//
// This package contains no application-specific (e.g. voting) business logic.
package semaphore

import (
	"bytes"
	"crypto/keccak256"
	"encoding/hex"
	"errors"

	"gno.land/p/g1c3m9uesphlhmj6fkx6nsh3fvhw8apqyjwyhe04/groth16/v2"
)

const (
	// MinDepth and MaxDepth match Semaphore v4 LeanIMT bounds.
	MinDepth = 1
	MaxDepth = 32
)

var (
	ErrUnauthorized          = errors.New("semaphore: unauthorized caller")
	ErrUnsupportedDepth      = errors.New("semaphore: unsupported circuit depth")
	ErrVKAlreadyRegistered   = errors.New("semaphore: verifying key already registered for depth")
	ErrInvalidCommitment     = errors.New("semaphore: invalid identity commitment")
	ErrDuplicateCommitment   = errors.New("semaphore: commitment already registered")
	ErrInvalidRoot           = errors.New("semaphore: invalid or unauthorized merkle root")
	ErrGroupNotFound         = errors.New("semaphore: group not found")
	ErrGroupAlreadyExists    = errors.New("semaphore: group already exists")
	ErrNullifierAlreadyUsed  = errors.New("semaphore: nullifier already used in scope")
	ErrScopeMismatch         = errors.New("semaphore: scope mismatch")
	ErrInvalidScalar         = errors.New("semaphore: non-canonical scalar field element")
	ErrInvalidHashInput      = errors.New("semaphore: hash input must be 32 bytes")
)

// BN254 scalar field order r = 21888242871839275222246405745257275088548364400416034343698204186575808495617.
var bn254ScalarFieldR = [32]byte{
	0x30, 0x64, 0x4e, 0x72, 0xe1, 0x31, 0xa0, 0x29,
	0xb8, 0x50, 0x45, 0xb6, 0x81, 0x81, 0x58, 0x5d,
	0x28, 0x33, 0xe8, 0x48, 0x79, 0xb9, 0x70, 0x91,
	0x43, 0xe1, 0xf5, 0x93, 0xf0, 0x00, 0x00, 0x01,
}

// HashToField implements Semaphore v4's official hash function:
//
//	uint256(keccak256(toBeHex(val, 32))) >> 8
//
// Shifting right by 8 bits drops the least-significant byte of the 32-byte
// big-endian Keccak-256 digest and pads a leading 0x00 byte, guaranteeing the
// resulting 248-bit integer is strictly less than the BN254 scalar field order r.
func HashToField(be32 []byte) ([]byte, error) {
	if len(be32) != 32 {
		return nil, ErrInvalidHashInput
	}
	digest := keccak256.Sum256(be32)
	out := make([]byte, 32)
	out[0] = 0
	copy(out[1:32], digest[0:31])
	return out, nil
}

// Uint64ToBE32 encodes a uint64 as a 32-byte big-endian scalar.
func Uint64ToBE32(v uint64) []byte {
	out := make([]byte, 32)
	for i := 0; i < 8; i++ {
		out[31-i] = byte(v >> uint(i*8))
	}
	return out
}

// DomainScope derives a 32-byte application-separated scope scalar from an
// application domain identifier and a local scope ID, preventing cross-app
// proof replay even when two applications use identical numeric scope IDs.
func DomainScope(appDomain string, scopeID uint64) []byte {
	payload := make([]byte, 0, len(appDomain)+1+8)
	payload = append(payload, []byte(appDomain)...)
	payload = append(payload, ':')
	payload = append(payload, Uint64ToBE32(scopeID)[24:32]...)
	digest := keccak256.Sum256(payload)
	out := make([]byte, 32)
	out[0] = 0
	copy(out[1:32], digest[0:31])
	return out
}

// DomainScopeFull derives a 32-byte scope scalar separated across network,
// application domain, groupID, and pollID.
func DomainScopeFull(network, appDomain string, groupID, pollID uint64) []byte {
	payload := make([]byte, 0, len(network)+len(appDomain)+24)
	payload = append(payload, []byte(network)...)
	payload = append(payload, ':')
	payload = append(payload, []byte(appDomain)...)
	payload = append(payload, ':')
	payload = append(payload, Uint64ToBE32(groupID)[24:32]...)
	payload = append(payload, ':')
	payload = append(payload, Uint64ToBE32(pollID)[24:32]...)
	digest := keccak256.Sum256(payload)
	out := make([]byte, 32)
	out[0] = 0
	copy(out[1:32], digest[0:31])
	return out
}

// ValidateCommitment checks that an identity commitment is a non-zero
// 32-byte canonical BN254 scalar (< r).
func ValidateCommitment(c []byte) error {
	if len(c) != 32 || isZero32(c) {
		return ErrInvalidCommitment
	}
	if compareBE32(c, bn254ScalarFieldR[:]) >= 0 {
		return ErrInvalidCommitment
	}
	return nil
}

// VKRegistry maps supported Semaphore Merkle tree depths to ceremony-backed
// Groth16 verifying keys.
type VKRegistry struct {
	keys map[int]groth16.VerifyingKey
}

// NewVKRegistry creates an empty verifying key registry.
func NewVKRegistry() *VKRegistry {
	return &VKRegistry{
		keys: make(map[int]groth16.VerifyingKey),
	}
}

// Register binds a depth (1..32) to a Groth16 VerifyingKey with 4 public inputs (len(IC)==5).
// Registrations are immutable once set to prevent silent key replacement.
func (r *VKRegistry) Register(depth int, vk groth16.VerifyingKey) error {
	if depth < MinDepth || depth > MaxDepth {
		return ErrUnsupportedDepth
	}
	if _, exists := r.keys[depth]; exists {
		return ErrVKAlreadyRegistered
	}
	if len(vk.IC) != 5 {
		return groth16.ErrInvalidVerifyingKey
	}
	r.keys[depth] = vk
	return nil
}

// Get returns the VerifyingKey for depth, if registered.
func (r *VKRegistry) Get(depth int) (groth16.VerifyingKey, bool) {
	vk, ok := r.keys[depth]
	return vk, ok
}

// Group represents a Semaphore membership group with an authorized admin and
// root publisher. Because native Poseidon is not in Gno's stdlib, roots are
// published by the authorized RootPublisher rather than computed on-chain.
type Group struct {
	ID            uint64
	Depth         int
	Admin         address
	RootPublisher address
	CurrentRoot   []byte
	RootVersion   uint64
	Members       [][]byte
	memberSet     map[string]bool
	validRoots    map[string]bool
}

// GroupRegistry manages Semaphore groups and their authorized roots.
type GroupRegistry struct {
	groups map[uint64]*Group
}

// NewGroupRegistry creates an empty GroupRegistry.
func NewGroupRegistry() *GroupRegistry {
	return &GroupRegistry{
		groups: make(map[uint64]*Group),
	}
}

// CreateGroup creates a new group with explicit admin and rootPublisher addresses.
func (gr *GroupRegistry) CreateGroup(id uint64, depth int, admin, rootPublisher address, vks *VKRegistry) error {
	if _, exists := gr.groups[id]; exists {
		return ErrGroupAlreadyExists
	}
	if _, ok := vks.Get(depth); !ok {
		return ErrUnsupportedDepth
	}
	if admin == "" || rootPublisher == "" {
		return ErrUnauthorized
	}
	gr.groups[id] = &Group{
		ID:            id,
		Depth:         depth,
		Admin:         admin,
		RootPublisher: rootPublisher,
		memberSet:     make(map[string]bool),
		validRoots:    make(map[string]bool),
	}
	return nil
}

// AddMember registers a validated identity commitment in the group.
func (gr *GroupRegistry) AddMember(caller address, groupID uint64, commitment []byte) error {
	g, ok := gr.groups[groupID]
	if !ok {
		return ErrGroupNotFound
	}
	if caller != g.Admin {
		return ErrUnauthorized
	}
	if err := ValidateCommitment(commitment); err != nil {
		return err
	}
	key := hex.EncodeToString(commitment)
	if g.memberSet[key] {
		return ErrDuplicateCommitment
	}
	cp := make([]byte, 32)
	copy(cp, commitment)
	g.memberSet[key] = true
	g.Members = append(g.Members, cp)
	return nil
}

// PublishRoot updates the group's authorized Merkle root.
func (gr *GroupRegistry) PublishRoot(caller address, groupID uint64, root []byte) error {
	g, ok := gr.groups[groupID]
	if !ok {
		return ErrGroupNotFound
	}
	if caller != g.RootPublisher && caller != g.Admin {
		return ErrUnauthorized
	}
	if len(root) != 32 || isZero32(root) || compareBE32(root, bn254ScalarFieldR[:]) >= 0 {
		return ErrInvalidRoot
	}
	cp := make([]byte, 32)
	copy(cp, root)
	g.CurrentRoot = cp
	g.RootVersion++
	g.validRoots[hex.EncodeToString(cp)] = true
	return nil
}

// IsValidRoot returns true iff root is the current (or a previously published)
// authorized root of the group.
func (gr *GroupRegistry) IsValidRoot(groupID uint64, root []byte) bool {
	g, ok := gr.groups[groupID]
	if !ok || len(root) != 32 {
		return false
	}
	return g.validRoots[hex.EncodeToString(root)]
}

// GetGroup returns the group metadata.
func (gr *GroupRegistry) GetGroup(groupID uint64) (*Group, bool) {
	g, ok := gr.groups[groupID]
	return g, ok
}

// NullifierSet tracks spent nullifiers per (scope) to prevent replay.
type NullifierSet struct {
	spent map[string]bool
}

// NewNullifierSet creates an empty NullifierSet.
func NewNullifierSet() *NullifierSet {
	return &NullifierSet{
		spent: make(map[string]bool),
	}
}

func nullifierKey(scopeHash, nullifier []byte) string {
	return hex.EncodeToString(scopeHash) + ":" + hex.EncodeToString(nullifier)
}

// IsSpent reports whether nullifier has already been used under scopeHash.
func (ns *NullifierSet) IsSpent(scopeHash, nullifier []byte) bool {
	return ns.spent[nullifierKey(scopeHash, nullifier)]
}

// MarkSpent records nullifier as spent under scopeHash.
func (ns *NullifierSet) MarkSpent(scopeHash, nullifier []byte) {
	ns.spent[nullifierKey(scopeHash, nullifier)] = true
}

// VerifyAndConsume verifies a Semaphore v4 Groth16 proof against any valid
// authorized root of groupID.
func VerifyAndConsume(
	vks *VKRegistry,
	gr *GroupRegistry,
	ns *NullifierSet,
	groupID uint64,
	depth int,
	root []byte,
	nullifier []byte,
	rawMessage32 []byte,
	rawScope32 []byte,
	proof groth16.Proof,
) error {
	return VerifyAndConsumeSnapshot(
		vks, gr, ns, groupID, depth, nil, root, nullifier, rawMessage32, rawScope32, proof,
	)
}

// VerifyAndConsumeSnapshot verifies a Semaphore v4 Groth16 proof. If
// expectedSnapshotRoot is non-empty, root must match that exact frozen
// snapshot root (preventing post-poll-creation membership mutations from
// altering an active poll's electorate).
func VerifyAndConsumeSnapshot(
	vks *VKRegistry,
	gr *GroupRegistry,
	ns *NullifierSet,
	groupID uint64,
	depth int,
	expectedSnapshotRoot []byte,
	root []byte,
	nullifier []byte,
	rawMessage32 []byte,
	rawScope32 []byte,
	proof groth16.Proof,
) error {
	g, ok := gr.GetGroup(groupID)
	if !ok {
		return ErrGroupNotFound
	}
	if depth != g.Depth {
		return ErrUnsupportedDepth
	}
	vk, ok := vks.Get(depth)
	if !ok {
		return ErrUnsupportedDepth
	}
	if len(expectedSnapshotRoot) > 0 {
		if !bytes.Equal(root, expectedSnapshotRoot) {
			return ErrInvalidRoot
		}
	} else if !gr.IsValidRoot(groupID, root) {
		return ErrInvalidRoot
	}
	if len(nullifier) != 32 || compareBE32(nullifier, bn254ScalarFieldR[:]) >= 0 {
		return ErrInvalidScalar
	}

	msgHash, err := HashToField(rawMessage32)
	if err != nil {
		return err
	}
	scopeHash, err := HashToField(rawScope32)
	if err != nil {
		return err
	}

	if ns.IsSpent(scopeHash, nullifier) {
		return ErrNullifierAlreadyUsed
	}

	// Semaphore v4 public signal order: [merkleTreeRoot, nullifier, hash(message), hash(scope)].
	publicInputs := [][]byte{root, nullifier, msgHash, scopeHash}
	if err := groth16.Verify(vk, proof, publicInputs); err != nil {
		return err
	}

	ns.MarkSpent(scopeHash, nullifier)
	return nil
}

func compareBE32(a, b []byte) int {
	for i := 0; i < 32; i++ {
		if a[i] < b[i] {
			return -1
		}
		if a[i] > b[i] {
			return 1
		}
	}
	return 0
}

func isZero32(a []byte) bool {
	for i := 0; i < 32; i++ {
		if a[i] != 0 {
			return false
		}
	}
	return true
}
