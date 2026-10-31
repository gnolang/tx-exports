// Package registry is spike (a) of tasarim-v6 §5.5: can a realm store an
// interface value handed over by ANOTHER realm and call it later, and what
// can that foreign code do to the registry while it runs?
//
// It is deliberately tiny and is never part of the product. Two exports are
// intentionally unsafe probes and are marked as such: SharedBoard (returns a
// pointer into registry state) and UnsafeBump (a non-crossing exported
// mutator). Production core has neither; this spike measures why.
package registry

import (
	"chain"
	"chain/runtime"
	"crypto/sha256"
	"encoding/hex"
	"strconv"
	"strings"

	"gno.land/p/nt/avl/v0"
)

// Engine is the contract a registered engine satisfies. Methods take and
// return plain values only, so the engine never receives a reference into
// registry state (tasarim-v6 §5.4 defence (a)).
type Engine interface {
	Name() string
	Render(seed string) string
}

// SampleSeed is rendered once at registration; its hash is the fingerprint.
const SampleSeed = "spike-sample"

type record struct {
	impl        Engine
	fingerprint string
	height      int64
}

// Board is registry-owned state that a foreign engine can get a pointer to.
type Board struct {
	Count int
}

var (
	engines avl.Tree // engine pkgpath -> *record
	board   = &Board{}
	bumps   int
)

// Register stores the caller realm's engine. The id is the caller's pkgpath,
// so a realm can only ever register itself.
func Register(cur realm, e Engine) string {
	id := cur.Previous().PkgPath()
	if id == "" || strings.Contains(id, "#") {
		panic("only a code realm can register an engine")
	}
	if e == nil {
		panic("nil engine")
	}
	if engines.Has(id) {
		panic("engine already registered: " + id)
	}
	sample := e.Render(SampleSeed)
	engines.Set(id, &record{impl: e, fingerprint: sha256Hex(sample), height: runtime.ChainHeight()})
	chain.Emit("SpikeEngineRegistered", "id", id, "name", e.Name())
	return id
}

// RenderWith runs a registered engine. Read-only: reached through qeval.
func RenderWith(id, seed string) string {
	return mustRecord(id).impl.Render(seed)
}

// RenderInTx runs an engine inside a transaction. UNSAFE PROBE: a qeval
// discards writes, so this is how the spike observes on chain what engine
// code can do from a write path — the thing core never does (I-12).
func RenderInTx(cur realm, id, seed string) string {
	return mustRecord(id).impl.Render(seed)
}

// VerifyFingerprint re-renders the sample and compares it with the hash
// stored at registration; false means the engine's output changed.
func VerifyFingerprint(id string) bool {
	r := mustRecord(id)
	return sha256Hex(r.impl.Render(SampleSeed)) == r.fingerprint
}

func Fingerprint(id string) string { return mustRecord(id).fingerprint }

func IsRegistered(id string) bool { return engines.Has(id) }

// SharedBoard returns a pointer into registry state. UNSAFE PROBE: the spike
// checks that a foreign engine writing through it is refused by the VM
// (interrealm v2 §3.2 readonly check).
func SharedBoard() *Board { return board }

// BoardCount reads the probe target.
func BoardCount() int { return board.Count }

// UnsafeBump is a non-crossing exported function that mutates registry
// state. UNSAFE PROBE: interrealm v2 §4.1 says a non-crossing call into
// /r/registry borrows /r/registry's storage, so a foreign engine calling it
// SHOULD succeed. That is exactly why production core exports no
// state-changing non-crossing function (invariant I-12).
func UnsafeBump() { bumps++ }

// Bumps reads the UnsafeBump counter.
func Bumps() int { return bumps }

func Render(path string) string {
	out := "# spike/registry\n\n"
	engines.Iterate("", "", func(key string, value any) bool {
		r := value.(*record)
		out += "- `" + key + "` fingerprint `" + r.fingerprint + "` (h=" + strconv.FormatInt(r.height, 10) + ")\n"
		return false
	})
	out += "\nboard.Count=" + strconv.Itoa(board.Count) + " bumps=" + strconv.Itoa(bumps) + "\n"
	return out
}

func mustRecord(id string) *record {
	v := engines.Get(id)
	if v == nil {
		panic("unknown engine: " + id)
	}
	return v.(*record)
}

func sha256Hex(s string) string {
	sum := sha256.Sum256([]byte(s))
	return hex.EncodeToString(sum[:])
}
