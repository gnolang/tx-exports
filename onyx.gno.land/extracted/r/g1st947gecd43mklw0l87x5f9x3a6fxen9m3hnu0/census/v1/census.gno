package census

import (
	"chain"
	"chain/runtime"
	"encoding/hex"
	"strconv"
	"strings"

	"gno.land/p/g1st947gecd43mklw0l87x5f9x3a6fxen9m3hnu0/cairnfold/v1"
	"gno.land/p/nt/avl/v0"
)

const (
	StageOpen           = "OPEN"
	StageFrozenSnapshot = "FROZEN_SNAPSHOT"
)

// DefaultOwner is the Onyx testnet operator address that deploys and funds roster storage deposits.
const DefaultOwner = address("g1st947gecd43mklw0l87x5f9x3a6fxen9m3hnu0")

const (
	maxBatchSize      = 200
	maxSnapshotURILen = 256
)

type epochRecord struct {
	id               uint64
	root             []byte
	leafCount        int
	purpose          string
	sealedHeight     int64
	snapshotURI      string
	snapshotVerified bool
	folded           bool
}

var (
	owner        = DefaultOwner
	activeRoster = avl.NewTree()
	epochs       []*epochRecord
)

func frozenEpoch() *epochRecord {
	if len(epochs) == 0 {
		return nil
	}
	last := epochs[len(epochs)-1]
	if last.folded {
		return nil
	}
	return last
}

func assertOwner(cur realm) {
	prev := cur.Previous()
	if prev.PkgPath() != "" || prev.Address() != owner {
		panic("ERR_UNAUTHORIZED: caller is not census owner")
	}
}

func assertOpen() {
	if frozenEpoch() != nil {
		panic("ERR_STAGE_FROZEN: roster is frozen awaiting verified fold")
	}
}

func isValidSnapshotURI(uri string) bool {
	if !strings.HasPrefix(uri, "https://") || len(uri) <= len("https://") || len(uri) > maxSnapshotURILen {
		return false
	}
	for i := 0; i < len(uri); i++ {
		c := uri[i]
		if c <= 0x20 || c > 0x7e || c == ')' || c == ']' || c == '<' || c == '>' {
			return false
		}
	}
	return true
}

func epochToView(ep *epochRecord) cairnfold.EpochView {
	rootCopy := make([]byte, len(ep.root))
	copy(rootCopy, ep.root)
	return cairnfold.EpochView{
		ID:               ep.id,
		Root:             rootCopy,
		RootHex:          hex.EncodeToString(ep.root),
		LeafCount:        ep.leafCount,
		Purpose:          ep.purpose,
		SealedHeight:     ep.sealedHeight,
		SnapshotURI:      ep.snapshotURI,
		SnapshotVerified: ep.snapshotVerified,
		Folded:           ep.folded,
	}
}

func Owner() address { return owner }

func Stage() string {
	if frozenEpoch() != nil {
		return StageFrozenSnapshot
	}
	return StageOpen
}

func ActiveRosterSize() int { return activeRoster.Size() }

func EpochCount() uint64 { return uint64(len(epochs)) }

// UpsertMember inserts or updates a single member in the draft AVL roster while OPEN.
func UpsertMember(cur realm, addr address, weight uint64, role string) {
	assertOwner(cur)
	assertOpen()
	if !cairnfold.IsCanonicalAddress(addr) {
		panic("ERR_INVALID_MEMBER: invalid canonical lowercase gno address")
	}
	if weight == 0 {
		panic("ERR_INVALID_MEMBER: weight must be >= 1")
	}
	if !cairnfold.IsValidRole(role) {
		panic("ERR_INVALID_MEMBER: invalid role")
	}
	activeRoster.Set(string(addr), cairnfold.Member{
		Addr:   addr,
		Weight: weight,
		Role:   role,
	})
}

// RemoveMember removes a member from the draft AVL roster while OPEN.
func RemoveMember(cur realm, addr address) bool {
	assertOwner(cur)
	assertOpen()
	if !cairnfold.IsCanonicalAddress(addr) {
		panic("ERR_INVALID_MEMBER: invalid canonical lowercase gno address")
	}
	_, removed := activeRoster.Remove(string(addr))
	return removed
}

// SeedRosterBatch atomically validates and upserts up to 200 "addr,weight,role" lines while OPEN.
func SeedRosterBatch(cur realm, csvLines string) int {
	assertOwner(cur)
	assertOpen()
	rawLines := strings.Split(strings.ReplaceAll(csvLines, "\r\n", "\n"), "\n")
	parsed := make([]cairnfold.Member, 0, len(rawLines))
	for _, ln := range rawLines {
		ln = strings.TrimSpace(ln)
		if ln == "" {
			continue
		}
		parts := strings.Split(ln, ",")
		if len(parts) != 3 {
			panic("ERR_INVALID_BATCH: each line must be addr,weight,role")
		}
		addr := address(strings.TrimSpace(parts[0]))
		w, err := strconv.ParseUint(strings.TrimSpace(parts[1]), 10, 64)
		if err != nil || w == 0 {
			panic("ERR_INVALID_BATCH: invalid weight")
		}
		role := strings.TrimSpace(parts[2])
		if !cairnfold.IsCanonicalAddress(addr) || !cairnfold.IsValidRole(role) {
			panic("ERR_INVALID_BATCH: invalid address or role")
		}
		parsed = append(parsed, cairnfold.Member{Addr: addr, Weight: w, Role: role})
		if len(parsed) > maxBatchSize {
			panic("ERR_INVALID_BATCH: batch exceeds 200 entries")
		}
	}
	if len(parsed) == 0 {
		panic("ERR_INVALID_BATCH: empty batch")
	}
	for _, m := range parsed {
		activeRoster.Set(string(m.Addr), m)
	}
	return len(parsed)
}

// SealEpoch computes the Tendermint Merkle root over the sorted AVL roster, appends an immutable
// epoch anchor, and locks edits in FROZEN_SNAPSHOT until verified and folded.
func SealEpoch(cur realm, purpose string) uint64 {
	assertOwner(cur)
	assertOpen()
	if activeRoster.Size() == 0 {
		panic("ERR_EMPTY_ROSTER: cannot seal an empty roster")
	}
	if activeRoster.Size() > cairnfold.MaxLeafCount {
		panic("ERR_ROSTER_TOO_LARGE: roster exceeds MaxLeafCount")
	}
	if !cairnfold.IsValidPurpose(purpose) {
		panic("ERR_INVALID_PURPOSE: purpose must be 1..64 printable ASCII chars without '|' or outer spaces")
	}
	nextID := uint64(len(epochs)) + 1
	members := make([]cairnfold.Member, 0, activeRoster.Size())
	var sumWeight uint64
	activeRoster.Iterate("", "", func(_ string, v interface{}) bool {
		m := v.(cairnfold.Member)
		if sumWeight > ^uint64(0)-m.Weight {
			panic("ERR_WEIGHT_OVERFLOW: sum of epoch weights exceeds uint64")
		}
		sumWeight += m.Weight
		members = append(members, m)
		return false
	})
	root, err := cairnfold.ComputeRoot(nextID, members)
	if err != nil {
		panic("ERR_SEAL_FAILED: " + err.Error())
	}
	rootHex := hex.EncodeToString(root)
	height := runtime.ChainHeight()
	ep := &epochRecord{
		id:           nextID,
		root:         root,
		leafCount:    len(members),
		purpose:      purpose,
		sealedHeight: height,
	}
	epochs = append(epochs, ep)
	chain.Emit(
		"EpochSealed",
		"epoch_id", strconv.FormatUint(nextID, 10),
		"root_hex", rootHex,
		"leaf_count", strconv.Itoa(len(members)),
		"sealed_height", strconv.FormatInt(height, 10),
	)
	return nextID
}

// ExportCanonicalSnapshot outputs canonical CSV rows while FROZEN_SNAPSHOT, or SnapshotURI guidance afterward.
func ExportCanonicalSnapshot(epochID uint64) string {
	if epochID == 0 || epochID > uint64(len(epochs)) {
		return "ERR_EPOCH_NOT_FOUND"
	}
	ep := epochs[epochID-1]
	rootHex := hex.EncodeToString(ep.root)
	if frozen := frozenEpoch(); frozen != nil && frozen.id == epochID {
		var sb strings.Builder
		sb.WriteString("# epoch_id=" + strconv.FormatUint(ep.id, 10) +
			",schema_id=1,leaf_count=" + strconv.Itoa(ep.leafCount) +
			",root_hex=" + rootHex +
			",purpose=" + ep.purpose + "\n")
		sb.WriteString("index,addr,weight,role\n")
		idx := 0
		activeRoster.Iterate("", "", func(_ string, v interface{}) bool {
			m := v.(cairnfold.Member)
			sb.WriteString(strconv.Itoa(idx) + "," +
				string(m.Addr) + "," +
				strconv.FormatUint(m.Weight, 10) + "," +
				m.Role + "\n")
			idx++
			return false
		})
		return sb.String()
	}
	return "FOLDED: canonical snapshot archived at " + ep.snapshotURI + " (root_hex=" + rootHex + ")"
}

// ConfirmSnapshotVerified verifies an off-chain-rebuilt canary cf1:... proof on-chain against the
// sealed epoch anchor before unlocking FoldRoster.
func ConfirmSnapshotVerified(cur realm, epochID uint64, snapshotURI string, canaryToken string) {
	assertOwner(cur)
	ep := frozenEpoch()
	if ep == nil || ep.id != epochID {
		panic("ERR_NOT_FROZEN: epoch is not currently frozen awaiting fold")
	}
	if !isValidSnapshotURI(snapshotURI) {
		panic("ERR_INVALID_URI: snapshotURI must be a valid https:// URL")
	}
	tok, decRes := cairnfold.DecodeProofToken(canaryToken)
	if !decRes.OK() {
		panic("ERR_CANARY_INVALID: " + decRes.Code + ": " + decRes.Message)
	}
	view := epochToView(ep)
	if _, res := cairnfold.VerifyToken(canaryToken, tok.Addr, &view, nil); !res.OK() {
		panic("ERR_CANARY_INVALID: " + res.Code + ": " + res.Message)
	}
	ep.snapshotURI = snapshotURI
	ep.snapshotVerified = true
	chain.Emit(
		"SnapshotVerified",
		"epoch_id", strconv.FormatUint(epochID, 10),
		"snapshot_uri", snapshotURI,
		"canary_index", strconv.Itoa(tok.Index),
	)
}

// FoldRoster deletes every entry from activeRoster after snapshot verification to release GnoVM
// storage deposits (100 ugnot/byte) and returns the realm to OPEN for the next epoch.
func FoldRoster(cur realm, epochID uint64) int {
	assertOwner(cur)
	ep := frozenEpoch()
	if ep == nil || ep.id != epochID {
		panic("ERR_NOT_FROZEN: epoch is not currently frozen awaiting fold")
	}
	if !ep.snapshotVerified || ep.snapshotURI == "" {
		panic("ERR_SNAPSHOT_UNVERIFIED: call ConfirmSnapshotVerified before FoldRoster")
	}
	keys := make([]string, 0, activeRoster.Size())
	activeRoster.Iterate("", "", func(k string, _ interface{}) bool {
		keys = append(keys, k)
		return false
	})
	for _, k := range keys {
		activeRoster.Remove(k)
	}
	activeRoster = avl.NewTree()
	ep.folded = true
	chain.Emit(
		"RosterFolded",
		"epoch_id", strconv.FormatUint(epochID, 10),
		"removed", strconv.Itoa(len(keys)),
		"remaining", "0",
	)
	return len(keys)
}

// GetEpoch returns a defensive read-only EpochView for downstream consumer realms.
func GetEpoch(epochID uint64) (cairnfold.EpochView, bool) {
	if epochID == 0 || epochID > uint64(len(epochs)) {
		return cairnfold.EpochView{}, false
	}
	return epochToView(epochs[epochID-1]), true
}

func modeBanner() string {
	cid := runtime.ChainID()
	if cid == "" || cid == "dev" {
		return "MODE: DETERMINISTIC_REPLAY (`chain_id=" + cid + "`, local dev/test)"
	}
	return "MODE: LIVE (`chain_id=" + cid + "`, `height=" + strconv.FormatInt(runtime.ChainHeight(), 10) + "`)"
}

func escapeMDCell(s string) string {
	s = strings.ReplaceAll(s, "|", "/")
	s = strings.ReplaceAll(s, "\n", " ")
	return s
}

func Render(_ string) string {
	var sb strings.Builder
	sb.WriteString("# CairnFold — Epoch Census Producer (`census/v1`)\n\n")
	sb.WriteString("> " + modeBanner() + " | Stage: `" + Stage() + "` | Active AVL Entries: `" + strconv.Itoa(activeRoster.Size()) + "` | Sealed Epochs: `" + strconv.Itoa(len(epochs)) + "`\n\n")
	sb.WriteString("Seal on-chain AVL rosters into immutable Tendermint Merkle roots (`crypto/merkle`), verify an off-chain canonical snapshot canary, and call `FoldRoster` to release `100 ugnot/byte` GnoVM storage deposits while downstream `gate/v1` keeps historical epochs claimable.\n\n")
	sb.WriteString("<gno-button href=\"/r/" + string(owner) + "/gate/v1\" label=\"Open Claim Gate (gate/v1)\" variant=\"success\" />\n\n")

	sb.WriteString("## Sealed Epochs\n\n")
	if len(epochs) == 0 {
		sb.WriteString("_No epochs sealed yet._\n\n")
	} else {
		sb.WriteString("| Epoch | Purpose | Leaves | Root (16 hex) | Height | Snapshot | Roster Folded |\n")
		sb.WriteString("| --- | --- | ---: | --- | ---: | --- | --- |\n")
		for _, ep := range epochs {
			shortRoot := hex.EncodeToString(ep.root)
			if len(shortRoot) > 16 {
				shortRoot = shortRoot[:16] + "..."
			}
			snapCell := "pending"
			if ep.snapshotURI != "" {
				snapCell = "[snapshot](" + ep.snapshotURI + ")"
			}
			foldedCell := "no (AVL live)"
			if ep.folded {
				foldedCell = "YES (AVL cleared)"
			}
			sb.WriteString("| " + strconv.FormatUint(ep.id, 10) +
				" | " + escapeMDCell(ep.purpose) +
				" | " + strconv.Itoa(ep.leafCount) +
				" | `" + shortRoot + "`" +
				" | " + strconv.FormatInt(ep.sealedHeight, 10) +
				" | " + snapCell +
				" | " + foldedCell + " |\n")
		}
		sb.WriteString("\n")
	}

	sb.WriteString("## Storage Audit Commands (`onyx-1`)\n\n")
	sb.WriteString("```sh\n")
	sb.WriteString("gnokey query vm/qstorage -data \"gno.land/r/" + string(owner) + "/census/v1\" -remote https://rpc.onyx.testnets.gno.land:443\n")
	sb.WriteString("gnokey query vm/qeval -data \"gno.land/r/" + string(owner) + "/census/v1.ExportCanonicalSnapshot(1)\" -remote https://rpc.onyx.testnets.gno.land:443\n")
	sb.WriteString("```\n")
	return sb.String()
}
