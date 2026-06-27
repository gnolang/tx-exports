// Package memba_market_config is the DAO-owned fee spine for the Memba marketplace.
// It is the single source of truth for the per-lane protocol fee (basis points) and
// the treasury that receives it. Every trade engine (NFT, services, token-OTC, agents)
// reads GetFeeBPS(lane) + GetTreasury() at settlement, so the DAO sets the rate ONCE
// and it applies everywhere — that shared read is what makes the lanes one marketplace.
//
// SAFETY (panel finding C1): the read getters are PURE and NON-FAILING — they never
// panic, and there is intentionally NO Pause(). A per-trade cross-realm read that
// could fail or halt would be a single point of failure able to brick every engine at
// once; instead an engine always gets a usable, bounded value here and clamps locally,
// while each engine keeps its OWN Pause() as the real kill switch. The fee is bounded
// to [0, MaxFeeBPS] on write, so a reader can trust the bound without re-checking.
package memba_market_config

import (
	"chain/runtime/unsafe"

	"gno.land/p/nt/avl/v0"
)

// AdminAddress is the samcrew-core 2-of-2 multisig (samcrew-core-test1) — the DAO
// treasury + admin until the memba_dao executor handoff (via TransferAdmin/AcceptAdmin).
// CONFIRMED 2026-06-27. Note: this is INTENTIONALLY the real 2-of-2 multisig, which
// differs from the single-key `g1x7k4628…` hardcoded as admin in the legacy realms
// (memba_collections/v3.1/escrow_v2) — that single-key admin is a pre-existing
// governance gap; the fee spine is owned by the actual multisig from day one.
const AdminAddress = "g10kw7e55e9wc8j8v6904ck29dqwr9fm9u280juh"

const (
	// MaxFeeBPS is the 5% hard ceiling. SetFeeBPS rejects anything above it, so a
	// fat-finger or a compromised proposal can never make a lane overcharge.
	MaxFeeBPS = int64(500)
	// DefaultFeeBPS is returned for an unset/unknown lane so engines always get a
	// usable value (2.0%).
	DefaultFeeBPS = int64(200)
)

var (
	admin        address
	pendingAdmin address
	treasury     address
	feeByLane    = avl.NewTree() // lane string -> int64 bps
)

func init() {
	admin = address(AdminAddress)
	treasury = address(AdminAddress) // treasury = the multisig now (plan decision #1)
	// Seed the launch lanes. "agent" is intentionally unset (TBD) and resolves to
	// DefaultFeeBPS until the DAO sets it when that lane is built.
	feeByLane.Set("nft", int64(200))     // 2.0%
	feeByLane.Set("service", int64(200)) // 2.0% release fee (the 5% cancel fee is escrow-internal → freelancer)
	feeByLane.Set("token", int64(50))    // 0.5% OTC — competitive vs DEX ~0.3%
}

func caller() address { return unsafe.PreviousRealm().Address() }

// ── Read getters — PURE, NON-FAILING (never panic, no Pause) ──────────────────

// GetFeeBPS returns the protocol fee in basis points for a lane. An unset or unknown
// lane returns DefaultFeeBPS. The result is always within [0, MaxFeeBPS] (enforced on
// write). Never panics — an engine must always be able to settle.
func GetFeeBPS(lane string) int {
	v, ok := feeByLane.Get(lane)
	if !ok {
		return int(DefaultFeeBPS)
	}
	return int(v.(int64))
}

// GetTreasury returns the address that receives the protocol fee on every lane.
func GetTreasury() address { return treasury }

// GetLaneConfig returns (feeBPS, treasury) in one read for an engine's settlement path.
func GetLaneConfig(lane string) (int, address) {
	return GetFeeBPS(lane), treasury
}

// GetAdmin returns the current admin (the multisig, or the memba_dao executor after
// the 2-step handoff).
func GetAdmin() address { return admin }
