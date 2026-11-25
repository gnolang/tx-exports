package gate

import (
	"chain"
	"chain/runtime"
	"strconv"
	"strings"

	"gno.land/p/g1st947gecd43mklw0l87x5f9x3a6fxen9m3hnu0/cairnfold/v1"
	"gno.land/p/nt/avl/v0"
	"gno.land/r/g1st947gecd43mklw0l87x5f9x3a6fxen9m3hnu0/census/v1"
)

// ClaimStats summarizes compact bitmap redemption accounting for an epoch.
type ClaimStats struct {
	EpochID            uint64
	LeafCount          int
	BitmapBytes        int
	ClaimedCount       int
	TotalWeightClaimed uint64
}

const censusOwnerStr = "g1st947gecd43mklw0l87x5f9x3a6fxen9m3hnu0"

type epochClaimState struct {
	bitmap             []byte
	claimedCount       int
	totalWeightClaimed uint64
}

var claimsByEpoch = avl.NewTree()

func epochKey(epochID uint64) string {
	s := strconv.FormatUint(epochID, 10)
	// Fixed-width 20-char decimal key keeps AVL iteration in numeric epoch order.
	for len(s) < 20 {
		s = "0" + s
	}
	return s
}

func getEpochState(epochID uint64) *epochClaimState {
	st, ok := claimsByEpoch.Get(epochKey(epochID)).(*epochClaimState)
	if !ok {
		return nil
	}
	return st
}

func verifyShared(token string, caller address) (cairnfold.ProofToken, cairnfold.EpochView, cairnfold.VerifyResult) {
	tok, decRes := cairnfold.DecodeProofToken(token)
	if !decRes.OK() {
		return cairnfold.ProofToken{}, cairnfold.EpochView{}, decRes
	}
	ep, ok := census.GetEpoch(tok.EpochID)
	if !ok {
		return tok, cairnfold.EpochView{}, cairnfold.VerifyResult{
			Code:    cairnfold.CodeErrEpochNotFound,
			Message: "epoch anchor not found in census/v1",
		}
	}
	var bm []byte
	if st := getEpochState(tok.EpochID); st != nil {
		bm = st.bitmap
	}
	verifiedTok, res := cairnfold.VerifyToken(token, caller, &ep, bm)
	return verifiedTok, ep, res
}

// CheckProof runs the exact Claim verification pipeline read-only with zero gas/state mutation.
func CheckProof(token string, caller address) string {
	tok, ep, res := verifyShared(token, caller)
	bmBytes := cairnfold.BitmapSize(ep.LeafCount)
	return res.Code + " | " + res.Message +
		" | epoch=" + strconv.FormatUint(tok.EpochID, 10) +
		" | index=" + strconv.Itoa(tok.Index) +
		" | bitmap_bytes=" + strconv.Itoa(bmBytes)
}

// Claim verifies a single-string cf1:... token against census/v1.GetEpoch, binds direct user caller,
// and marks the 1-bit epoch bitmap nullifier.
func Claim(cur realm, token string) string {
	prev := cur.Previous()
	if prev.PkgPath() != "" {
		panic(cairnfold.CodeErrCallerMismatch + ": direct user call required")
	}
	caller := prev.Address()
	tok, ep, res := verifyShared(token, caller)
	if !res.OK() {
		panic(res.Code + ": " + res.Message)
	}
	key := epochKey(tok.EpochID)
	st := getEpochState(tok.EpochID)
	if st == nil {
		st = &epochClaimState{
			bitmap: make([]byte, cairnfold.BitmapSize(ep.LeafCount)),
		}
		claimsByEpoch.Set(key, st)
	}
	if !cairnfold.SetBit(st.bitmap, tok.Index) {
		panic(cairnfold.CodeErrAlreadyClaimed + ": leaf index already claimed for this epoch")
	}
	st.claimedCount++
	st.totalWeightClaimed += tok.Weight
	chain.Emit(
		"Claimed",
		"epoch_id", strconv.FormatUint(tok.EpochID, 10),
		"index", strconv.Itoa(tok.Index),
		"addr", string(tok.Addr),
		"weight", strconv.FormatUint(tok.Weight, 10),
		"role", tok.Role,
	)
	return cairnfold.CodeOK
}

// GetClaimStats returns compact bitmap storage and claim totals for epochID.
func GetClaimStats(epochID uint64) ClaimStats {
	ep, ok := census.GetEpoch(epochID)
	if !ok {
		return ClaimStats{EpochID: epochID}
	}
	stats := ClaimStats{
		EpochID:     epochID,
		LeafCount:   ep.LeafCount,
		BitmapBytes: cairnfold.BitmapSize(ep.LeafCount),
	}
	if st := getEpochState(epochID); st != nil {
		stats.ClaimedCount = st.claimedCount
		stats.TotalWeightClaimed = st.totalWeightClaimed
	}
	return stats
}

func modeBanner() string {
	cid := runtime.ChainID()
	if cid == "" || cid == "dev" {
		return "MODE: DETERMINISTIC_REPLAY (`chain_id=" + cid + "`, local dev/test)"
	}
	return "MODE: LIVE (`chain_id=" + cid + "`, `height=" + strconv.FormatInt(runtime.ChainHeight(), 10) + "`)"
}

func Render(_ string) string {
	var sb strings.Builder
	sb.WriteString("# CairnFold — Cross-Realm Claim Gate (`gate/v1`)\n\n")
	sb.WriteString("> " + modeBanner() + " | Authoritative Producer: `gno.land/r/" + censusOwnerStr + "/census/v1` (imports only `GetEpoch`)\n\n")
	sb.WriteString("Verifies `cf1:...` Tendermint Merkle proofs against sealed epochs in `census/v1` — even after `FoldRoster` clears the producer AVL tree — using a 1-bit-per-leaf **Epoch Bitmap** (`ceil(N/8)` bytes) instead of 32-byte per-claim nullifier maps.\n\n")
	sb.WriteString("<gno-button href=\"/r/" + censusOwnerStr + "/census/v1\" label=\"Back to Census Producer (census/v1)\" variant=\"outline\" />\n\n")

	sb.WriteString("## Epoch Claim & Bitmap Ledger\n\n")
	var sealed []cairnfold.EpochView
	for id := uint64(1); ; id++ {
		ep, ok := census.GetEpoch(id)
		if !ok {
			break
		}
		sealed = append(sealed, ep)
	}
	if len(sealed) == 0 {
		sb.WriteString("_No sealed epochs available in `census/v1` yet._\n\n")
	} else {
		sb.WriteString("| Epoch | Leaves | Snapshot | Roster Folded | Claimed | Weight Claimed | Bitmap Bytes | Naive 32B Map |\n")
		sb.WriteString("| --- | ---: | --- | --- | ---: | ---: | ---: | ---: |\n")
		for _, ep := range sealed {
			st := GetClaimStats(ep.ID)
			snapCell := "pending"
			if ep.SnapshotURI != "" {
				snapCell = "[snapshot](" + ep.SnapshotURI + ")"
			}
			folded := "no"
			if ep.Folded {
				folded = "YES"
			}
			sb.WriteString("| " + strconv.FormatUint(ep.ID, 10) +
				" | " + strconv.Itoa(ep.LeafCount) +
				" | " + snapCell +
				" | " + folded +
				" | " + strconv.Itoa(st.ClaimedCount) +
				" | " + strconv.FormatUint(st.TotalWeightClaimed, 10) +
				" | `" + strconv.Itoa(st.BitmapBytes) + " B`" +
				" | `" + strconv.Itoa(ep.LeafCount*32) + " B` |\n")
		}
		sb.WriteString("\n")
	}

	sb.WriteString("## Submit Proof Token (`Claim`)\n\n")
	sb.WriteString("<gno-form exec=\"Claim\">\n")
	sb.WriteString("  <gno-input name=\"token\" placeholder=\"cf1:1:0:32:g1...:100:builder:...\" />\n")
	sb.WriteString("</gno-form>\n\n")

	sb.WriteString("## CLI Claim & Storage Audit (`onyx-1`)\n\n")
	sb.WriteString("_GnoVM realms cannot query `vm/qstorage` internally; verify live deposit reclamation across both realms via `gnokey` or the published E2E receipts._\n\n")
	sb.WriteString("```sh\n")
	sb.WriteString("gnokey query vm/qeval -data \"gno.land/r/" + censusOwnerStr + "/gate/v1.CheckProof(\\\"<CF1_TOKEN>\\\", \\\"<YOUR_G1_ADDR>\\\")\" -remote https://rpc.onyx.testnets.gno.land:443\n")
	sb.WriteString("gnokey query vm/qstorage -data \"gno.land/r/" + censusOwnerStr + "/gate/v1\" -remote https://rpc.onyx.testnets.gno.land:443\n")
	sb.WriteString("gnokey maketx call -pkgpath \"gno.land/r/" + censusOwnerStr + "/gate/v1\" -func \"Claim\" -args \"<CF1_TOKEN>\" -gas-fee 5000ugnot -gas-wanted 5000000 -chainid onyx-1 -remote https://rpc.onyx.testnets.gno.land:443 <YOUR_KEY>\n")
	sb.WriteString("```\n")
	return sb.String()
}
