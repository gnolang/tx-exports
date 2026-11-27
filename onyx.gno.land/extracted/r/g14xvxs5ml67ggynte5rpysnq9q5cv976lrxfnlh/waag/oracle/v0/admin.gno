package oracle

import (
	"strconv"

	"chain"
	"chain/runtime"

	"gno.land/p/g14xvxs5ml67ggynte5rpysnq9q5cv976lrxfnlh/waag/feedmath/v0"
)

// admin is the only address allowed to register sources, change configuration,
// or pause the feed.
//
// It is a literal rather than something captured at initialization, and that is
// a deliberate choice forced by how this testnet works. Onyx runs the "inert"
// code-submission policy: MsgAddPackage stores a package inert - in the words of
// contribs/gpao/README.md, "not typechecked, not executed, not importable" - and
// it only becomes active when an address in the chain's PkgApprovers sends
// MsgEnablePackage. Package-level initialization therefore runs inside the
// APPROVER's transaction, not the deployer's, so the usual
// `var admin = unsafe.OriginCaller()` trick would hand control of this feed to
// the testnet's approval daemon.
//
// The address is alice, the deployer key (master doc §5). On a mainnet or
// multi-operator deployment this should become a governance realm or a
// multisig; for a single-operator testnet feed, a literal is honest and
// auditable, and §1.3's caveats already say the deployment is single-operator.
var admin = address("g14xvxs5ml67ggynte5rpysnq9q5cv976lrxfnlh")

// assertAdmin panics unless the caller is the admin signing directly.
//
// IsUserCall() is required, not optional: without it another realm could call
// an admin function and pass its own user's identity along, which is the
// confused-deputy hole. Checking it makes admin actions wallet-only.
func assertAdmin(cur realm) {
	caller := cur.Previous()
	if !caller.IsUserCall() {
		panic("oracle: admin functions require a direct user call")
	}
	if caller.Address() != admin {
		panic("oracle: caller is not the admin")
	}
}

// Admin exposes the current admin address so anyone can check who controls the
// feed without reading source. Read-only, so it takes no caller context.
func Admin() address {
	return admin
}

// RegisterSource adds a source and binds it to the one key allowed to submit
// for it (ledger O2). The binding is the real authentication: submitting is
// only possible with that key's signature, so a compromised source cannot be
// impersonated by anyone holding a different key.
//
// Registering the same source id twice panics - silently overwriting the key
// would let an admin mistake (or a stolen admin key) redirect a source without
// a visible removal.
func RegisterSource(cur realm, sourceID, asset string, keyAddr address) {
	assertAdmin(cur)

	if sourceID == "" {
		panic("oracle: source id cannot be empty")
	}
	if asset == "" {
		panic("oracle: asset cannot be empty")
	}
	if keyAddr == address("") {
		panic("oracle: source key cannot be empty")
	}

	f := getFeed(asset)
	if f == nil {
		f = &feed{asset: asset}
		feeds.Set(asset, f)
	}
	if f.getSource(sourceID) != nil {
		panic("oracle: source already registered")
	}

	f.sources.Set(sourceID, &source{
		id:      sourceID,
		asset:   asset,
		keyAddr: keyAddr,
	})

	chain.Emit(
		SourceRegisteredEvent,
		"asset", asset,
		"source", sourceID,
		"key", keyAddr.String(),
	)
}

// RemoveSource unregisters a source. Its price history goes with it.
//
// Removal can drop the feed below quorum, which makes GetPrice revert. That is
// the intended failure direction: losing a source should freeze the feed, never
// quietly let the remaining ones publish an under-supported number.
func RemoveSource(cur realm, sourceID, asset string) {
	assertAdmin(cur)

	f := mustFeed(asset)
	if f.getSource(sourceID) == nil {
		panic("oracle: unknown source")
	}
	f.sources.Remove(sourceID)

	// Republish from whatever is left; recompute() declines unless a quorum of
	// sources is still fresh.
	f.recompute(runtime.ChainHeight())

	chain.Emit(
		SourceRemovedEvent,
		"asset", asset,
		"source", sourceID,
	)
}

// SetConfig retunes the rules without a redeploy (ledger O5/O6 both call for
// admin-tunable thresholds, and M5's burn-in depends on it).
//
// Validation rejects values that would make the math unsafe or the feed
// meaningless: a negative staleness window, a deviation threshold outside
// feedmath's basis-point range, or a quorum below 1.
//
// Setting minFreshSources ABOVE the number of registered sources is allowed and
// simply freezes the feed - GetPrice reverts until enough sources exist. That is
// fail-safe rather than fail-open, so it is the admin's call, not a panic.
func SetConfig(cur realm, stalenessBlocks, deviationBps int64, minFreshSources int) {
	assertAdmin(cur)

	if stalenessBlocks < 0 {
		panic("oracle: staleness window cannot be negative")
	}
	if deviationBps < 0 || deviationBps > feedmath.MaxThresholdBps {
		panic("oracle: deviation threshold must be within [0, 10000] bps")
	}
	if minFreshSources < 1 {
		panic("oracle: quorum must be at least 1 source")
	}

	cfg.stalenessBlocks = stalenessBlocks
	cfg.deviationBps = deviationBps
	cfg.minFreshSources = minFreshSources

	chain.Emit(
		ConfigChangedEvent,
		"staleness_blocks", strconv.FormatInt(stalenessBlocks, 10),
		"deviation_bps", strconv.FormatInt(deviationBps, 10),
		"min_fresh_sources", strconv.Itoa(minFreshSources),
	)
}

// Pause is the emergency stop. While paused every mutator and every read
// reverts, which is the point: if a source is compromised or the bot misbehaves,
// the admin can make the feed refuse to speak at all until it is fixed.
func Pause(cur realm, paused bool) {
	assertAdmin(cur)
	cfg.paused = paused
	chain.Emit(PausedEvent, "paused", strconv.FormatBool(paused))
}

// Config exposes the live settings for dashboards and consumers.
func Config() (stalenessBlocks int64, deviationBps int64, minFreshSources int, paused bool) {
	return cfg.stalenessBlocks, cfg.deviationBps, cfg.minFreshSources, cfg.paused
}
