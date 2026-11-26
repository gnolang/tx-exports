// Package veil_vote implements a reference anonymous voting realm on Gno.land
// powered by Veil Primitives (semaphore) and Veil Core (groth16).
//
// Privacy model (V1):
//   - Group membership is anonymous (zero-knowledge proof of LeanIMT inclusion).
//   - Vote options are public in V1 (not secret-ballot).
//   - Group membership & Merkle roots use an authorized root-publisher model.
package veil_vote

import (
	"chain/runtime"
	"encoding/hex"
	"strings"

	"gno.land/p/g1c3m9uesphlhmj6fkx6nsh3fvhw8apqyjwyhe04/groth16/v2"
	"gno.land/p/g1c3m9uesphlhmj6fkx6nsh3fvhw8apqyjwyhe04/semaphore/v2"
)

// Poll represents an anonymous voting poll bound to a frozen Semaphore group snapshot.
type Poll struct {
	ID              uint64
	GroupID         uint64
	Title           string
	Options         []string
	Tallies         []uint64
	SnapshotRoot    []byte
	SnapshotVersion uint64
	OpenHeight      int64
	CloseHeight     int64
	Closed          bool
	Creator         address
}

var (
	admin      = address("g1c3m9uesphlhmj6fkx6nsh3fvhw8apqyjwyhe04")
	vks        *semaphore.VKRegistry
	groups     *semaphore.GroupRegistry
	nullifiers *semaphore.NullifierSet
	polls      map[uint64]*Poll
)

func init() {
	vks = semaphore.NewVKRegistry()
	groups = semaphore.NewGroupRegistry()
	nullifiers = semaphore.NewNullifierSet()
	polls = make(map[uint64]*Poll)

	// Register ceremony-backed Semaphore v4 depth-10 verification key.
	vk10, err := groth16.ParseVerifyingKeyHex(
		"245229d9b076b3c0e8a4d70bde8c1cccffa08a9fae7557b165b3b0dbd653e2c7253ec85988dbb84e46e94b5efa3373b47a000b4ac6c86b2d4b798d274a182302",
		"07090a82e8fabbd39299be24705b92cf208ee8b3487f6f2b39ff27978a29a1db2424bcc1f60a5472685fd50705b2809626e170120acaf441e133a2bd5e61d2440ae1135cffdaf227c5dc266740607aa930bc3bd92ddc2b135086d9da2dfd3e2a2b86859fd3d55c9d150fb3f0aeba798826493dd73d357ab0f9fdaced9fc81829",
		"198e9393920d483a7260bfb731fb5d25f1aa493335a9e71297e485b7aef312c21800deef121f1e76426a00665e5c4479674322d4f75edadd46debd5cd992f6ed090689d0585ff075ec9e99ad690c3395bc4b313370b38ef355acdadcd122975b12c85ea5db8c6deb4aab71808dcb408fe3d1e7690c43d37b4ce6cc0166fa7daa",
		"300192ff2b9358b371328362eab85f10b3b256562986b0222f90fde6285b20312b9b6d2f72c215474b76c58be1bc8113aed21efc4bfeb76d432fadd1a143ae551afc92793b1e3c7bc0fff4d51b34c751d6fd4f0b684fd36a5eb31f2e7d59bd0827a4788df73ad8b0a3db6dd0366131faff0cf443fdbe689b1811275524fe4f5b",
		[]string{
			"26e306f7f4400a8b466a46f73b1bb30628e8f53ae183179a89ea09bcab1abe8c1903a292e81db108e9af23cd1c7249087803195ef86af9d7aef43f671bbe28d5",
			"05c92b5167e06202018a4b1c482dde448604793a2b6d734c3a59f599b457794f109890a7f2fcb50131c7e510faf117da23344b6e50403670b103e8b1b0fea27f",
			"1fb6977c76473f7a1d148b69a5526768ac7032ce91f0e138973b3e4d30745fdf22846c8fc4704252020b4a141726ef713f5eda605ded818ee69d101490d5a8b6",
			"079b1bc515838f1ad835d87623adef3b1673ca9735ab72d8fc938e206a524e5820d47a675b313cd4b857527f3e6ddd2b5646e5fd9f206aad5bcfaae6cb0958e6",
			"064e79c61f6d53a00688e7f217a0c8579ba3daf9d4df5dec16f013a124413f152383c6f75c1a392e6e1375277f1130c2274d8668773addb783207cf58cf4c0b6",
		},
	)
	if err != nil {
		panic(err.Error())
	}
	if err := vks.Register(10, vk10); err != nil {
		panic(err.Error())
	}
}

// CreateGroup registers a new Semaphore group under admin control.
func CreateGroup(cur realm, groupID uint64, depth int, rootPublisher address) {
	caller := cur.Previous().Address()
	if caller != admin {
		panic("veil_vote: only admin can create groups")
	}
	if err := groups.CreateGroup(groupID, depth, admin, rootPublisher, vks); err != nil {
		panic(err.Error())
	}
}

// AddMember registers an eligible Semaphore identity commitment in groupID.
func AddMember(cur realm, groupID uint64, commitmentHex string) {
	caller := cur.Previous().Address()
	commitment, err := decodeHex32(commitmentHex)
	if err != nil {
		panic(err.Error())
	}
	if err := groups.AddMember(caller, groupID, commitment); err != nil {
		panic(err.Error())
	}
}

// PublishRoot updates the authorized LeanIMT root for groupID.
func PublishRoot(cur realm, groupID uint64, rootHex string) {
	caller := cur.Previous().Address()
	root, err := decodeHex32(rootHex)
	if err != nil {
		panic(err.Error())
	}
	if err := groups.PublishRoot(caller, groupID, root); err != nil {
		panic(err.Error())
	}
}

// CreatePoll creates a new poll bound to groupID's current published root snapshot.
func CreatePoll(cur realm, pollID, groupID uint64, title, optionsCSV string, openHeight, closeHeight int64) {
	caller := cur.Previous().Address()
	if caller != admin {
		panic("veil_vote: only admin can create polls")
	}
	if _, exists := polls[pollID]; exists {
		panic("veil_vote: poll already exists")
	}
	grp, ok := groups.GetGroup(groupID)
	if !ok {
		panic("veil_vote: group not found")
	}
	if len(grp.CurrentRoot) != 32 {
		panic("veil_vote: group has no published root snapshot")
	}
	snap := make([]byte, 32)
	copy(snap, grp.CurrentRoot)
	opts := splitCSV(optionsCSV)
	if len(opts) < 2 {
		panic("veil_vote: poll must have at least 2 options")
	}
	if closeHeight > 0 && closeHeight <= openHeight {
		panic("veil_vote: invalid open/close height range")
	}
	polls[pollID] = &Poll{
		ID:              pollID,
		GroupID:         groupID,
		Title:           title,
		Options:         opts,
		Tallies:         make([]uint64, len(opts)),
		SnapshotRoot:    snap,
		SnapshotVersion: grp.RootVersion,
		OpenHeight:      openHeight,
		CloseHeight:     closeHeight,
		Creator:         caller,
	}
}

// ClosePoll closes a poll immediately.
func ClosePoll(cur realm, pollID uint64) {
	caller := cur.Previous().Address()
	p, ok := polls[pollID]
	if !ok {
		panic("veil_vote: poll not found")
	}
	if caller != admin && caller != p.Creator {
		panic("veil_vote: unauthorized close")
	}
	p.Closed = true
}

// Vote verifies a Semaphore v4 membership proof bound to pollID, group, and
// optionIndex, records the scoped nullifier, and increments the tally atomically.
func Vote(
	cur realm,
	pollID uint64,
	depth int,
	rootHex string,
	nullifierHex string,
	optionIndex int,
	aHex string,
	bHex string,
	cHex string,
) string {
	p, ok := polls[pollID]
	if !ok {
		panic("veil_vote: poll not found")
	}
	h := runtime.ChainHeight()
	if p.Closed || h < p.OpenHeight || (p.CloseHeight > 0 && h >= p.CloseHeight) {
		panic("veil_vote: poll is closed")
	}
	if optionIndex < 0 || optionIndex >= len(p.Options) {
		panic("veil_vote: invalid vote option")
	}

	root, err := decodeHex32(rootHex)
	if err != nil {
		panic(err.Error())
	}
	nullifier, err := decodeHex32(nullifierHex)
	if err != nil {
		panic(err.Error())
	}
	proof, err := groth16.ParseProofHex(aHex, bHex, cHex)
	if err != nil {
		panic(err.Error())
	}

	rawMsg := semaphore.Uint64ToBE32(uint64(optionIndex))
	rawScope := semaphore.DomainScopeFull(
		runtime.ChainID(),
		cur.PkgPath(),
		p.GroupID,
		pollID,
	)

	if err := semaphore.VerifyAndConsumeSnapshot(
		vks,
		groups,
		nullifiers,
		p.GroupID,
		depth,
		p.SnapshotRoot,
		root,
		nullifier,
		rawMsg,
		rawScope,
		proof,
	); err != nil {
		panic(err.Error())
	}

	p.Tallies[optionIndex]++
	return "RECORDED"
}

// GetGroupCommitments returns newline-separated hex identity commitments so
// clients can independently reconstruct the group's LeanIMT root.
func GetGroupCommitments(groupID uint64) string {
	g, ok := groups.GetGroup(groupID)
	if !ok {
		return ""
	}
	var out strings.Builder
	for i := 0; i < len(g.Members); i++ {
		if i > 0 {
			out.WriteByte('\n')
		}
		out.WriteString(hex.EncodeToString(g.Members[i]))
	}
	return out.String()
}

// GetPollSnapshotRoot returns the frozen 64-char hex root for pollID.
func GetPollSnapshotRoot(pollID uint64) string {
	p, ok := polls[pollID]
	if !ok {
		return ""
	}
	return hex.EncodeToString(p.SnapshotRoot)
}

// GetPollTally returns the vote count for optionIndex in pollID.
func GetPollTally(pollID uint64, optionIndex int) uint64 {
	p, ok := polls[pollID]
	if !ok || optionIndex < 0 || optionIndex >= len(p.Tallies) {
		return 0
	}
	return p.Tallies[optionIndex]
}

// Render renders a human-readable summary of all polls.
func Render(path string) string {
	return "Veil Vote — Anonymous Semaphore v4 Governance Realm (V1)\n"
}

func decodeHex32(s string) ([]byte, error) {
	if len(s) >= 2 && s[0] == '0' && (s[1] == 'x' || s[1] == 'X') {
		s = s[2:]
	}
	if len(s) != 64 {
		return nil, groth16.ErrInvalidEncoding
	}
	b, err := hex.DecodeString(s)
	if err != nil {
		return nil, groth16.ErrInvalidEncoding
	}
	return b, nil
}

func splitCSV(s string) []string {
	s = strings.TrimSpace(s)
	if s == "" {
		return nil
	}
	parts := strings.Split(s, ",")
	out := make([]string, 0, len(parts))
	for i := 0; i < len(parts); i++ {
		trimmed := strings.TrimSpace(parts[i])
		if trimmed != "" {
			out = append(out, trimmed)
		}
	}
	return out
}
