// Package memba_appstore_v2 is a curated App Store for gno.land dApps: publishers
// pay a flat listing fee to register an app; a curator flips it live.
//
// MONEY PATH (the only one): RegisterApp collects a flat `registrationFee` in ugnot
// and forwards 100% to the treasury in the SAME call — nothing is ever custodied.
// The safety contract mirrors memba_token_otc_v1 + the O-13 lesson:
//   1. IsUserCall() guard BEFORE reading OriginSend — an ephemeral `maketx run`
//      realm can never attach unrecoverable coins (the guard agent_registry missed).
//   2. exact-coin via unsafe.OriginSend() (the coins on THIS call, not the wallet
//      balance) — closes the overpay-trap and the wallet-balance bypass.
//   3. treasury-misconfig is fail-closed: an unset treasury panics (→ tx reverts →
//      coins refunded), never silent custody.
//   4. CEI: state is written before the banker moves funds.
//   5. NewBanker(RealmSend, cur) sends the fee from the realm's own address to the
//      treasury — no custody, no escrow (which is why no escrow is needed to be safe).
//
// TREASURY: stored LOCALLY (admin-settable, 2-step handoff, defaults to the samcrew
// multisig) rather than read from memba_market_config — this keeps the realm
// self-contained so the whole money path is unit-tested locally. Keep it in sync with
// memba_market_config.GetTreasury(); a future version may read the fee spine directly
// (which makes the realm non-locally-testable — a deliberate later trade-off).
package memba_appstore_v2

import (
	"chain"
	"chain/banker"
	"chain/runtime"
	"chain/runtime/unsafe"

	"gno.land/p/samcrew/avl"
	"gno.land/p/nt/ufmt/v0"
)

// AdminAddress is the samcrew-core 2-of-2 multisig (same as the fee spine's admin/
// treasury). It is the initial owner AND the initial treasury.
const AdminAddress = "g1x7k4628w93a7wzdhqc06atzx0v50rnshweuxu0"

const (
	// DefaultRegistrationFee is the launch listing fee: 1 GNOT (1_000_000 ugnot).
	// The DAO/admin can change it via SetRegistrationFee (bounded by MaxRegistrationFee).
	DefaultRegistrationFee = int64(1_000_000)
	// MaxRegistrationFee caps a fat-finger / compromised-proposal fee at 100 GNOT.
	MaxRegistrationFee = int64(100_000_000)

	MaxNameLen    = 80
	MaxTaglineLen = 140
	MaxDescrLen   = 2000
	MaxURLLen     = 400
	MaxPkgPathLen = 200
	MaxCIDLen     = 100
	// FlagHideThreshold auto-hides a listing from the live list once this many
	// distinct addresses have flagged it (a curator can DelistApp / restore).
	FlagHideThreshold = 5
)

// StatusPending / StatusLive / StatusDelisted are the listing lifecycle states.
const (
	StatusPending  = "pending"
	StatusLive     = "live"
	StatusDelisted = "delisted"
)

// Listing is one app. PkgPath (the realm/package path) is the unique key.
type Listing struct {
	Id        uint64
	PkgPath   string
	Name      string
	Tagline   string
	Descr     string
	Category  string
	IconCID   string
	AppURL    string
	Publisher address
	Status    string
	FlagCount int
	CreatedAt int64
}

var (
	owner            address
	pendingOwner     address
	treasury         address
	registrationFee  int64
	paused           bool
	curators         = avl.NewTree() // address string -> bool
	listings         = avl.NewTree() // pkgPath -> *Listing
	flaggedBy        = avl.NewTree() // pkgPath + "\x00" + addr -> bool (one flag per addr)
	nextId    uint64 = 1
)

func init() {
	owner = address(AdminAddress)
	treasury = address(AdminAddress)
	registrationFee = DefaultRegistrationFee
	curators.Set(AdminAddress, true) // the admin is a curator by default
}

func caller() address { return unsafe.PreviousRealm().Address() }

func assertOwner() {
	if caller() != owner {
		panic("unauthorized: owner only")
	}
}

func assertNotPaused() {
	if paused {
		panic("appstore is paused")
	}
}

// ── Money path ────────────────────────────────────────────────────────────────

// RegisterApp lists a new app. The caller pays EXACTLY registrationFee ugnot with
// the call; the whole fee is forwarded to the treasury (no custody). The listing
// starts `pending` and is not shown live until a curator approves it.
func RegisterApp(
	cur realm,
	pkgPath, name, tagline, descr, category, iconCID, appURL string,
) uint64 {
	assertNotPaused()

	// O-13 guard: a payable entrypoint MUST be a direct user call, so an ephemeral
	// `maketx run` realm can never attach coins that become unrecoverable.
	if !unsafe.PreviousRealm().IsUserCall() {
		panic("RegisterApp must be a direct user call")
	}

	pkgPath = validatePkgPath(pkgPath)
	if _, dup := listings.Get(pkgPath); dup {
		panic("app already registered for this package path")
	}
	if len(name) == 0 || len(name) > MaxNameLen {
		panic("name must be 1.." + itoa(MaxNameLen) + " chars")
	}
	if len(tagline) > MaxTaglineLen {
		panic("tagline too long")
	}
	if len(descr) > MaxDescrLen {
		panic("description too long")
	}
	if len(appURL) > MaxURLLen {
		panic("appURL too long")
	}
	if len(iconCID) > MaxCIDLen {
		panic("iconCID too long")
	}

	// Exact-coin: read the coins attached to THIS call (not the wallet balance).
	sent := unsafe.OriginSend()
	if sent.AmountOf("ugnot") != registrationFee {
		panic(ufmt.Sprintf("must send exactly %d ugnot (sent %d)", registrationFee, sent.AmountOf("ugnot")))
	}
	// Fail-closed on a misconfigured treasury — reverting refunds the coins; we never
	// keep custody of a fee we can't route.
	if treasury == "" {
		panic("treasury unset — registration disabled")
	}

	// CEI: write state before moving funds.
	id := nextId
	nextId++
	l := &Listing{
		Id:        id,
		PkgPath:   pkgPath,
		Name:      name,
		Tagline:   tagline,
		Descr:     descr,
		Category:  category,
		IconCID:   iconCID,
		AppURL:    appURL,
		Publisher: caller(),
		Status:    StatusPending,
		CreatedAt: runtime.ChainHeight(),
	}
	listings.Set(pkgPath, l)

	// Forward the whole fee to the treasury from the realm's own account.
	if registrationFee > 0 {
		bnk := banker.NewBanker(banker.BankerTypeRealmSend, cur)
		bnk.SendCoins(
			unsafe.CurrentRealm().Address(),
			treasury,
			chain.Coins{chain.NewCoin("ugnot", registrationFee)},
		)
	}

	chain.Emit("AppRegistered", "pkgPath", pkgPath, "id", itoa64(id), "publisher", caller().String())
	return id
}

// ── Curation & moderation ───────────────────────────────────────────────────

// ApproveApp flips a pending listing live. Curator-only.
func ApproveApp(cur realm, pkgPath string) {
	if !isCurator(caller()) {
		panic("unauthorized: curator only")
	}
	l := mustGet(pkgPath)
	if l.Status == StatusDelisted {
		panic("cannot approve a delisted app")
	}
	l.Status = StatusLive
	listings.Set(pkgPath, l)
	chain.Emit("AppApproved", "pkgPath", pkgPath)
}

// DelistApp removes a listing from public view. The publisher or a curator may do it.
func DelistApp(cur realm, pkgPath string) {
	l := mustGet(pkgPath)
	if caller() != l.Publisher && !isCurator(caller()) {
		panic("unauthorized: publisher or curator only")
	}
	l.Status = StatusDelisted
	listings.Set(pkgPath, l)
	chain.Emit("AppDelisted", "pkgPath", pkgPath)
}

// RestoreApp brings a delisted app back to `pending` (re-curation required before it
// shows live again). Curator-only — this is the reverse of DelistApp, so a mistaken
// or contested delist is recoverable.
func RestoreApp(cur realm, pkgPath string) {
	if !isCurator(caller()) {
		panic("unauthorized: curator only")
	}
	l := mustGet(pkgPath)
	if l.Status != StatusDelisted {
		panic("only a delisted app can be restored")
	}
	l.Status = StatusPending
	listings.Set(pkgPath, l)
	chain.Emit("AppRestored", "pkgPath", pkgPath)
}

// FlagApp lets any user flag a LIVE listing once. At FlagHideThreshold distinct flags
// the listing stops appearing live; a curator then DelistApp's it or leaves it for
// review (a delisted app can be brought back with RestoreApp).
func FlagApp(cur realm, pkgPath string) {
	l := mustGet(pkgPath)
	if l.Status != StatusLive {
		panic("can only flag a live app")
	}
	key := pkgPath + "\x00" + caller().String()
	if _, done := flaggedBy.Get(key); done {
		panic("already flagged")
	}
	flaggedBy.Set(key, true)
	l.FlagCount++
	listings.Set(pkgPath, l)
	chain.Emit("AppFlagged", "pkgPath", pkgPath, "count", itoa(l.FlagCount))
}

// isVisible reports whether a listing shows in the live list.
func isVisible(l *Listing) bool {
	return l.Status == StatusLive && l.FlagCount < FlagHideThreshold
}

// ── Read getters (pure, non-failing) ─────────────────────────────────────────

// GetRegistrationFee returns the current flat listing fee in ugnot.
func GetRegistrationFee() int64 { return registrationFee }

// GetTreasury returns the address that receives listing fees.
func GetTreasury() address { return treasury }

// GetOwner returns the current owner (multisig, or a DAO executor after handoff).
func GetOwner() address { return owner }

// AppCount returns the total number of registered listings (any status).
func AppCount() int { return listings.Size() }

// GetStatsJSON returns a small stats object for a status header.
func GetStatsJSON() string {
	live := 0
	listings.Iterate("", "", func(_ string, v any) bool {
		if isVisible(v.(*Listing)) {
			live++
		}
		return false
	})
	return ufmt.Sprintf(`{"total":%d,"live":%d,"registrationFee":%d,"paused":%t}`,
		listings.Size(), live, registrationFee, paused)
}

// ── internal helpers ─────────────────────────────────────────────────────────

func isCurator(a address) bool {
	_, ok := curators.Get(a.String())
	return ok
}

func mustGet(pkgPath string) *Listing {
	v, ok := listings.Get(pkgPath)
	if !ok {
		panic("app not found: " + pkgPath)
	}
	return v.(*Listing)
}

// validatePkgPath normalizes + sanity-checks a realm/package path.
func validatePkgPath(p string) string {
	if len(p) == 0 || len(p) > MaxPkgPathLen {
		panic("pkgPath must be 1.." + itoa(MaxPkgPathLen) + " chars")
	}
	// Must be a gno.land realm ("/r/") or package ("/p/") path.
	if !hasPrefix(p, "gno.land/r/") && !hasPrefix(p, "gno.land/p/") {
		panic("pkgPath must be a gno.land/r/... or gno.land/p/... path")
	}
	return p
}

func hasPrefix(s, pre string) bool {
	return len(s) >= len(pre) && s[:len(pre)] == pre
}

func itoa(n int) string    { return ufmt.Sprintf("%d", n) }
func itoa64(n uint64) string { return ufmt.Sprintf("%d", n) }
