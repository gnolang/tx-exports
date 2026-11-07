// Package drand is a Sinopia randomness provider (core.RandomnessProvider)
// backed by the drand "evmnet" beacon, every round verified on chain.
//
// Verification is gno.land/p/drand/v0 from gnolang/gno#6268, imported from
// its unmodified copy in Sinopia's namespace (realms/p/drand/v0/README.md;
// pure Gno on the crypto/bn254, keccak256, modexp natives of gno v1.7.0):
// evmnet signs on BN254 (scheme bls-bn254-unchained-on-g1, one round every
// 3 s), and Verify checks e(sig, G2) == e(H(round), pk). The randomness of a
// round is sha256(signature), the same value drand's API serves.
//
// Trust: nobody. Submit is permissionless and only stores a round whose
// signature verifies against drand's group key, so a submitter can deliver
// a round or not, never choose or alter its value. Liveness needs at least
// one submitter (the Sinopia keeper, any relayer, the creator, a collector);
// if nobody submits, core falls back after ProviderWaitBlocks (CV-M1).
//
// How core uses it (realms/r/core/randomness.gno):
//
//  1. Target() is read in the transaction that binds a collection (the
//     creator's reveal, RequestRandomness in the grace period, or the first
//     Finalize after the deadline). It names the first evmnet round
//     published more than MarginSeconds after the current block time, so
//     its value is unknown to everyone, including the caller, when the bind
//     is committed. Nobody passes a round: the caller cannot choose one.
//  2. Anyone fetches that round from drand once it is published and calls
//     Submit(round, signature) here.
//  3. Anyone calls core.FulfillRandomness (or Finalize): core reads
//     Randomness(round) and finalizes.
//
// Clock assumptions (see README "drand provider"): time.Now() is the block
// header time, which tm2 sets to the median of the previous commit's vote
// times (BFT time), so a single proposer cannot move it. It lags wall clock by
// about one block (measured on Onyx: 4–7 s behind the newest block, blocks
// 3.3–5.4 s). MarginSeconds (30 s = 10 rounds) covers that lag, the 3 s
// propose timeout and ordinary validator clock skew. The one known case
// where block time is much older than wall clock is the first block after a
// chain halt (its time comes from the pre-halt commit); Target() then
// refuses (0) whenever a later round is already verified here, and core lets
// the bind happen later. An honest keeper submitting rounds as they are
// published makes that check effective.
package drand

import (
	"chain"
	"encoding/binary"
	"encoding/hex"
	"strconv"
	"strings"
	"time"

	evmnet "gno.land/p/g1jz6j9hj6rdf5ltl2kcrpa4jwtdh3w30z0yul06/sinopia/drand/v0"
	"gno.land/p/nt/avl/v0"

	"gno.land/r/g1jz6j9hj6rdf5ltl2kcrpa4jwtdh3w30z0yul06/sinopia3/core"
)

const (
	// MarginSeconds: Target() is the first round published more than this
	// many seconds after the block time (10 evmnet rounds).
	MarginSeconds = int64(30)
	// SigHexLen is an evmnet signature in hex (64 bytes, G1 point x|y).
	SigHexLen = 2 * evmnet.SigSize
	// maxList bounds Rounds() pages.
	maxList = 100
)

var (
	beacons avl.Tree // 8-byte big-endian round -> 64 hex chars (sha256 of the signature)
	latest  int64    // highest round verified here (0: none)
)

type provider struct{}

// Name implements core.RandomnessProvider.
func (provider) Name() string { return "drand evmnet (BN254, 3 s)" }

// Target implements core.RandomnessProvider: the round a bind made in the
// current block is tied to, or 0 when the block time is provably stale.
func (provider) Target() int64 { return target(time.Now().Unix()) }

// Randomness implements core.RandomnessProvider: the verified randomness of
// round as 64 lowercase hex characters, or "" while nobody submitted it.
func (provider) Randomness(round int64) string {
	if round <= 0 {
		return ""
	}
	if v := beacons.Get(key(round)); v != nil {
		return v.(string)
	}
	return ""
}

// target is the first round published strictly after now+MarginSeconds.
// It returns 0 (core: "cannot bind now, retry later") when that round is
// not newer than a round already verified here: the block time is then
// behind wall clock by more than the margin (e.g. the first block after a
// halt) and the round may already be public.
func target(now int64) int64 {
	r := TargetAt(now)
	if r <= latest {
		return 0
	}
	return r
}

// TargetAt is the round a bind at block time unix would get, without the
// staleness check. For keepers and UIs.
func TargetAt(unix int64) int64 {
	return int64(evmnet.RoundAt(unix+MarginSeconds)) + 1
}

// TimeOf is the unix time at which evmnet publishes round.
func TimeOf(round int64) int64 {
	if round <= 0 {
		return evmnet.GenesisTime
	}
	return evmnet.TimeOf(uint64(round))
}

// Submit verifies round's drand evmnet signature (hex, the "signature" field
// of https://api.drand.sh/<ChainHash>/public/<round>) and stores its
// randomness. Permissionless; the caller is never trusted. A round already
// stored is a no-op (returns the stored value), so concurrent submitters
// never fail each other. Returns the randomness (64 hex characters).
func Submit(cur realm, round int64, signature string) string {
	if round <= 0 {
		panic("round must be positive")
	}
	if v := beacons.Get(key(round)); v != nil {
		return v.(string)
	}
	if len(signature) != SigHexLen {
		panic("signature must be " + strconv.Itoa(SigHexLen) + " hex characters (drand evmnet)")
	}
	sig, err := hex.DecodeString(signature)
	if err != nil {
		panic("signature is not hex")
	}
	if !evmnet.Verify(uint64(round), sig) {
		panic("invalid drand evmnet signature for round " + itoa(round))
	}
	r := evmnet.Randomness(sig)
	v := hex.EncodeToString(r[:])
	beacons.Set(key(round), v)
	if round > latest {
		latest = round
	}
	chain.Emit("DrandBeacon", "round", itoa(round), "randomness", v)
	return v
}

// Register registers this provider with Sinopia core (once; anyone may send
// it). It stays inert until the admin approves it (timelocked
// randomness.add).
func Register(cur realm) string {
	return core.RegisterRandomnessProvider(cross(cur), provider{})
}

// Has reports whether round's randomness is stored here.
func Has(round int64) bool { return round > 0 && beacons.Has(key(round)) }

// Latest is the highest round verified here (0 if none).
func Latest() int64 { return latest }

// Info returns the provider's parameters and state as JSON.
func Info() string {
	return `{"chainHash":"` + evmnet.ChainHash +
		`","scheme":"` + evmnet.SchemeID +
		`","genesis":` + itoa(evmnet.GenesisTime) +
		`,"period":` + itoa(evmnet.Period) +
		`,"marginSeconds":` + itoa(MarginSeconds) +
		`,"latest":` + itoa(latest) +
		`,"stored":` + itoa(int64(beacons.Size())) +
		`,"target":` + itoa(target(time.Now().Unix())) + `}`
}

// Rounds lists stored rounds, newest first, as "round:randomness" lines.
func Rounds(offset, limit int64) string {
	if limit <= 0 || limit > maxList {
		limit = maxList
	}
	if offset < 0 {
		offset = 0
	}
	var b strings.Builder
	n := int64(0)
	beacons.ReverseIterate("", "", func(k string, v any) bool {
		if n >= offset {
			b.WriteString(itoa(keyRound(k)) + ":" + v.(string) + "\n")
		}
		n++
		return n >= offset+limit
	})
	return b.String()
}

// Render shows the provider on gnoweb.
func Render(path string) string {
	var b strings.Builder
	b.WriteString("# Sinopia randomness: drand evmnet\n\n")
	b.WriteString("Public randomness from [drand](https://drand.love) evmnet, every round's BLS (BN254) signature verified on chain " +
		"with `gno.land/p/drand/v0`. Anyone can `Submit(round, signature)`; nobody can choose or alter a value.\n\n")
	b.WriteString("- chain hash: `" + evmnet.ChainHash + "`\n")
	b.WriteString("- next bind target: round " + itoa(target(time.Now().Unix())) + " (margin " + itoa(MarginSeconds) + " s)\n")
	b.WriteString("- latest verified round: " + itoa(latest) + "\n")
	b.WriteString("- stored rounds: " + itoa(int64(beacons.Size())) + "\n\n")
	if beacons.Size() > 0 {
		b.WriteString("| round | randomness |\n|---|---|\n")
		for _, line := range strings.Split(strings.TrimSpace(Rounds(0, 10)), "\n") {
			i := strings.Index(line, ":")
			b.WriteString("| " + line[:i] + " | `" + line[i+1:] + "` |\n")
		}
	}
	return b.String()
}

// key encodes round as 8 big-endian bytes so avl order is numeric order.
func key(round int64) string {
	var k [8]byte
	binary.BigEndian.PutUint64(k[:], uint64(round))
	return string(k[:])
}

func keyRound(k string) int64 { return int64(binary.BigEndian.Uint64([]byte(k))) }

func itoa(n int64) string { return strconv.FormatInt(n, 10) }
