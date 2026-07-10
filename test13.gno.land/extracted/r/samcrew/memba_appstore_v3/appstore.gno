// Package memba_appstore_v3 is a curated App Store for gno.land dApps: publishers
// pay a flat listing fee to register an app; a curator flips it live (or rejects it).
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
//   4. CEI: state is written before the banker moves funds. All attacker-controlled
//      input (screenshots, appURL scheme) is validated BEFORE OriginSend is read.
//   5. NewBanker(RealmSend, cur) sends the fee from the realm's own address to the
//      treasury — no custody, no escrow (which is why no escrow is needed to be safe).
//
// v3 over v2: a `rejected` state + RejectApp/EditListing lifecycle, ≤6 screenshots,
// an on-chain appURL scheme allowlist, FlagApp extended to pending listings (the
// public Unverified tab's safety valve), composite-key status/publisher indexes with
// O(1) per-status counters (so status/publisher reads are bounded, not full scans),
// and a sealed SeedListing migration primitive (FinalizeSeed closes the backdoor).
//
// TREASURY: stored LOCALLY (admin-settable, 2-step handoff, defaults to the samcrew
// multisig) rather than read from memba_market_config — keeps the money path locally
// unit-testable. Keep it in sync with memba_market_config.GetTreasury().
package memba_appstore_v3

import (
	"strings"

	"chain"
	"chain/banker"
	"chain/runtime"
	"chain/runtime/unsafe"

	"gno.land/p/nt/avl/v0"
	"gno.land/p/nt/ufmt/v0"
)

// AdminAddress is the samcrew-core 2-of-2 multisig (same as the fee spine's admin/
// treasury). It is the initial owner AND the initial treasury.
const AdminAddress = "g1x7k4628w93a7wzdhqc06atzx0v50rnshweuxu0"

const (
	// DefaultRegistrationFee is the launch listing fee: 1 GNOT (1_000_000 ugnot).
	DefaultRegistrationFee = int64(1_000_000)
	// MaxRegistrationFee caps a fat-finger / compromised-proposal fee at 100 GNOT.
	MaxRegistrationFee = int64(100_000_000)

	MaxNameLen     = 80
	MaxTaglineLen  = 140
	MaxDescrLen    = 2000
	MaxCategoryLen = 40
	MaxURLLen      = 400
	MaxPkgPathLen  = 200
	MaxCIDLen      = 100
	MaxReasonLen   = 500
	// MaxScreenshots bounds the per-listing screenshot gallery.
	MaxScreenshots = 6
	// MaxResubmits bounds how many times a publisher can edit/resubmit a listing, so a
	// reject→edit→pending loop can't grief the curator queue indefinitely.
	MaxResubmits = 5
	// FlagHideThreshold auto-hides a listing (live OR pending) from the public lists once
	// this many distinct addresses have flagged it.
	FlagHideThreshold = 5
)

// Listing lifecycle states.
const (
	StatusPending  = "pending"
	StatusLive     = "live"
	StatusRejected = "rejected"
	StatusDelisted = "delisted"
)

// Listing is one app. PkgPath (the realm/package path) is the unique key.
type Listing struct {
	Id                 uint64
	PkgPath            string
	Name               string
	Tagline            string
	Descr              string
	Category           string
	IconCID            string
	ScreenshotCIDs     []string
	AppURL             string
	Publisher          address
	Status             string
	RejectReason       string
	PaidResubmitCredit bool
	ResubmitCount      int
	FlagCount          int
	CreatedAt          int64
}

var (
	owner          address
	pendingOwner   address
	treasury       address
	registrationFee int64
	paused         bool
	seedingSealed  bool
	curators       = avl.NewTree() // address string -> bool
	listings       = avl.NewTree() // pkgPath -> *Listing
	flaggedBy      = avl.NewTree() // pkgPath + "\x00" + addr -> bool (one flag per addr)
	// statusIndex/publisherIndex: composite-key indexes for bounded status/publisher reads.
	// key = status|pub + "\x00" + zeroPad(id) -> pkgPath, so a prefix range-iterate yields a
	// true O(offset+limit) window ordered by submission id, never a full-catalog scan.
	statusIndex    = avl.NewTree()
	publisherIndex = avl.NewTree()
	// O(1) per-status counters, maintained on every status transition.
	liveCount     int
	pendingCount  int
	rejectedCount int
	delistedCount int
	nextId uint64 = 1
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

// RegisterApp lists a new app. The caller pays EXACTLY registrationFee ugnot with the call;
// the whole fee is forwarded to the treasury (no custody). The listing starts `pending`.
func RegisterApp(
	cur realm,
	pkgPath, name, tagline, descr, category, iconCID, screenshotsCSV, appURL string,
) uint64 {
	assertNotPaused()

	// O-13 guard: a payable entrypoint MUST be a direct user call.
	if !unsafe.PreviousRealm().IsUserCall() {
		panic("RegisterApp must be a direct user call")
	}

	// Validate ALL attacker-controlled input BEFORE reading the attached coins.
	pkgPath = validatePkgPath(pkgPath)
	if _, dup := listings.Get(pkgPath); dup {
		panic("app already registered for this package path")
	}
	validateListingFields(name, tagline, descr, category, iconCID, appURL)
	shots := parseScreenshots(screenshotsCSV)

	// Exact-coin: read the coins attached to THIS call (not the wallet balance).
	sent := unsafe.OriginSend()
	if sent.AmountOf("ugnot") != registrationFee {
		panic(ufmt.Sprintf("must send exactly %d ugnot (sent %d)", registrationFee, sent.AmountOf("ugnot")))
	}
	// Fail-closed on a misconfigured treasury — reverting refunds the coins.
	if treasury == "" {
		panic("treasury unset — registration disabled")
	}

	// CEI: write state before moving funds.
	id := nextId
	nextId++
	l := &Listing{
		Id:             id,
		PkgPath:        pkgPath,
		Name:           name,
		Tagline:        tagline,
		Descr:          descr,
		Category:       category,
		IconCID:        iconCID,
		ScreenshotCIDs: shots,
		AppURL:         appURL,
		Publisher:      caller(),
		Status:         StatusPending,
		CreatedAt:      runtime.ChainHeight(),
	}
	listings.Set(pkgPath, l)
	indexInsert(l)

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

// ApproveApp flips a pending (or previously-live) listing live. Curator-only.
func ApproveApp(cur realm, pkgPath string) {
	if !isCurator(caller()) {
		panic("unauthorized: curator only")
	}
	l := mustGet(pkgPath)
	if l.Status == StatusDelisted {
		panic("cannot approve a delisted app")
	}
	if l.Status != StatusLive {
		changeStatus(l, StatusLive)
	}
	chain.Emit("AppApproved", "pkgPath", pkgPath)
}

// RejectApp declines a pending submission, recording a reason and granting a one-time free
// resubmit credit. Curator-only; only a pending app can be rejected.
func RejectApp(cur realm, pkgPath, reason string) {
	if !isCurator(caller()) {
		panic("unauthorized: curator only")
	}
	if len(reason) > MaxReasonLen {
		panic("reason too long")
	}
	l := mustGet(pkgPath)
	if l.Status != StatusPending {
		panic("only a pending app can be rejected")
	}
	changeStatus(l, StatusRejected)
	l.RejectReason = reason
	l.PaidResubmitCredit = true
	listings.Set(pkgPath, l)
	chain.Emit("AppRejected", "pkgPath", pkgPath)
}

// EditListing lets the publisher update a listing that is NOT live/delisted — i.e. a pending
// or rejected one — and resets it to `pending` for (re-)review. Editing a live listing is
// structurally forbidden so a Verified badge can never be bait-and-switched. Bounded by
// MaxResubmits so a reject→edit loop can't grief the queue.
func EditListing(
	cur realm,
	pkgPath, name, tagline, descr, category, iconCID, screenshotsCSV, appURL string,
) {
	l := mustGet(pkgPath)
	if caller() != l.Publisher {
		panic("unauthorized: publisher only")
	}
	if l.Status != StatusPending && l.Status != StatusRejected {
		panic("cannot edit a live or delisted listing")
	}
	if l.ResubmitCount >= MaxResubmits {
		panic("resubmit limit reached")
	}
	validateListingFields(name, tagline, descr, category, iconCID, appURL)
	shots := parseScreenshots(screenshotsCSV)

	l.Name = name
	l.Tagline = tagline
	l.Descr = descr
	l.Category = category
	l.IconCID = iconCID
	l.ScreenshotCIDs = shots
	l.AppURL = appURL
	l.RejectReason = ""
	l.ResubmitCount++
	if l.Status != StatusPending {
		changeStatus(l, StatusPending) // rejected → pending (re-review); persists via Set
	} else {
		listings.Set(pkgPath, l)
	}
	chain.Emit("AppEdited", "pkgPath", pkgPath)
}

// DelistApp removes a listing from public view. The publisher or a curator may do it.
func DelistApp(cur realm, pkgPath string) {
	l := mustGet(pkgPath)
	if caller() != l.Publisher && !isCurator(caller()) {
		panic("unauthorized: publisher or curator only")
	}
	if l.Status != StatusDelisted {
		changeStatus(l, StatusDelisted)
	}
	chain.Emit("AppDelisted", "pkgPath", pkgPath)
}

// RestoreApp brings a delisted app back to `pending` (re-curation required). Curator-only.
func RestoreApp(cur realm, pkgPath string) {
	if !isCurator(caller()) {
		panic("unauthorized: curator only")
	}
	l := mustGet(pkgPath)
	if l.Status != StatusDelisted {
		panic("only a delisted app can be restored")
	}
	changeStatus(l, StatusPending)
	chain.Emit("AppRestored", "pkgPath", pkgPath)
}

// FlagApp lets any user flag a publicly-listed (live OR pending) listing once. At
// FlagHideThreshold distinct flags the listing drops from the public lists (isVisible), giving
// the public Unverified/pending tab a community safety valve; a curator can then Delist/Reject.
func FlagApp(cur realm, pkgPath string) {
	l := mustGet(pkgPath)
	if l.Status != StatusLive && l.Status != StatusPending {
		panic("can only flag a live or pending app")
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

// MaxClearBatch bounds how many per-address flag marks one ClearFlags call removes,
// so a mega-brigade (thousands of sybil flags) cannot gas-lock the reset — the
// curator just calls ClearFlags repeatedly until the count reaches zero.
const MaxClearBatch = 200

// ClearFlags resets a listing's community-flag state after curator review. Curator-only.
// Without it a flag-hidden listing stays hidden FOREVER: FlagCount never decrements and
// survives every status transition, so FlagHideThreshold (5) sybil addresses could
// permanently disappear any live app. Clearing also deletes the per-address dedupe marks —
// the community can re-flag if the concern is real, and every clear is an emitted event,
// so a curator whitewashing a bad listing is publicly visible on-chain.
func ClearFlags(cur realm, pkgPath string) {
	if !isCurator(caller()) {
		panic("unauthorized: curator only")
	}
	l := mustGet(pkgPath)
	if l.FlagCount == 0 {
		panic("no flags to clear")
	}
	// Collect up to MaxClearBatch marks over the listing's prefix range (the same
	// [prefix+"\x00", prefix+"\x01") window idiom as reads.gno), then remove them.
	// Keys are collected BEFORE removal — never mutate a tree mid-Iterate.
	var keys []string
	flaggedBy.Iterate(pkgPath+"\x00", pkgPath+"\x01", func(k string, _ any) bool {
		keys = append(keys, k)
		return len(keys) >= MaxClearBatch
	})
	for _, k := range keys {
		flaggedBy.Remove(k)
	}
	l.FlagCount -= len(keys)
	if l.FlagCount < 0 {
		l.FlagCount = 0
	}
	listings.Set(pkgPath, l)
	chain.Emit("AppFlagsCleared", "pkgPath", pkgPath,
		"cleared", itoa(len(keys)), "remaining", itoa(l.FlagCount))
}

// ── Migration (owner-only, sealable) ──────────────────────────────────────────

// SeedListing imports a listing verbatim (Id, CreatedAt, FlagCount, Status, Publisher) during a
// v2→v3 migration. Owner-only, NON-payable (never reads OriginSend / moves funds), dedupe-guarded.
// After the migration the owner calls FinalizeSeed, permanently sealing this entrypoint — without
// that latch it would be a standing backdoor to forge fee-free listings with arbitrary publisher.
func SeedListing(
	cur realm,
	id uint64,
	pkgPath, name, tagline, descr, category, iconCID, screenshotsCSV, appURL, publisherStr, status string,
	flagCount int,
	createdAt int64,
) {
	assertOwner()
	if seedingSealed {
		panic("seeding sealed — migration is finalized")
	}
	pkgPath = validatePkgPath(pkgPath)
	if _, dup := listings.Get(pkgPath); dup {
		panic("app already registered for this package path")
	}
	if !validStatus(status) {
		panic("invalid status")
	}
	// A duplicate id would collide on the composite index key (statusKey/pubKey), silently
	// overwriting one entry while double-counting — so reject an id already present in ANY status
	// (covers both a repeat seed and a seeded id that a prior RegisterApp already used).
	if idInUse(id) {
		panic("id already in use")
	}
	// Seeded data is historical user input — validate it against the SAME field + appURL-scheme
	// rules as a fresh registration, so an unsafe v2 appURL can't be imported past the allowlist.
	validateListingFields(name, tagline, descr, category, iconCID, appURL)
	shots := parseScreenshots(screenshotsCSV)
	l := &Listing{
		Id:             id,
		PkgPath:        pkgPath,
		Name:           name,
		Tagline:        tagline,
		Descr:          descr,
		Category:       category,
		IconCID:        iconCID,
		ScreenshotCIDs: shots,
		AppURL:         appURL,
		Publisher:      address(publisherStr),
		Status:         status,
		FlagCount:      flagCount,
		CreatedAt:      createdAt,
	}
	listings.Set(pkgPath, l)
	indexInsert(l)
	if id >= nextId {
		nextId = id + 1
	}
	chain.Emit("AppSeeded", "pkgPath", pkgPath, "id", itoa64(id))
}

// FinalizeSeed permanently seals SeedListing (one-way latch). Owner-only.
func FinalizeSeed(cur realm) {
	assertOwner()
	seedingSealed = true
	chain.Emit("SeedingFinalized")
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

// IsCurator reports whether an address may approve/reject listings (the curator-dashboard gate).
func IsCurator(a string) bool {
	_, ok := curators.Get(a)
	return ok
}

// GetCuratorsJSON returns a JSON array of curator addresses (small, bounded).
func GetCuratorsJSON() string {
	var sb strings.Builder
	sb.WriteString("[")
	first := true
	curators.Iterate("", "", func(k string, _ any) bool {
		if !first {
			sb.WriteString(",")
		}
		first = false
		sb.WriteString(`"`)
		sb.WriteString(k) // a bech32 address — no JSON metachars
		sb.WriteString(`"`)
		return false
	})
	sb.WriteString("]")
	return sb.String()
}

// GetStatsJSON returns per-status counts (served from O(1) counters) for the store header.
func GetStatsJSON() string {
	return ufmt.Sprintf(
		`{"total":%d,"live":%d,"pending":%d,"rejected":%d,"delisted":%d,"registrationFee":%d,"paused":%t}`,
		listings.Size(), liveCount, pendingCount, rejectedCount, delistedCount, registrationFee, paused)
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

func validStatus(s string) bool {
	return s == StatusPending || s == StatusLive || s == StatusRejected || s == StatusDelisted
}

// validateListingFields checks the length + appURL-scheme invariants shared by RegisterApp and
// EditListing. The appURL scheme allowlist (http/https/leading-slash/empty) is the on-chain
// defense behind the frontend AppLink — it blocks javascript:/data:/other-scheme phishing URLs.
func validateListingFields(name, tagline, descr, category, iconCID, appURL string) {
	if len(name) == 0 || len(name) > MaxNameLen {
		panic("name must be 1.." + itoa(MaxNameLen) + " chars")
	}
	if len(tagline) > MaxTaglineLen {
		panic("tagline too long")
	}
	if len(descr) > MaxDescrLen {
		panic("description too long")
	}
	if len(category) > MaxCategoryLen {
		panic("category too long")
	}
	if len(iconCID) > MaxCIDLen {
		panic("iconCID too long")
	}
	if len(appURL) > MaxURLLen {
		panic("appURL too long")
	}
	validateAppURL(appURL)
}

// validateAppURL enforces the scheme allowlist: empty, http://, https://, or a leading-slash
// in-app path. Anything else (javascript:, data:, ftp:, mailto:, …) aborts. A leading-slash path
// must NOT be protocol-relative (`//host` or `/\host`) — browsers navigate those off-site, which
// would defeat the allowlist.
func validateAppURL(u string) {
	if u == "" {
		return
	}
	if hasPrefix(u, "http://") || hasPrefix(u, "https://") {
		return
	}
	if u[0] == '/' {
		if len(u) > 1 && (u[1] == '/' || u[1] == '\\') {
			panic("appURL scheme: protocol-relative //host is not an in-app path")
		}
		return
	}
	panic("appURL scheme must be http(s):// or a leading-slash path")
}

// parseScreenshots splits a comma-separated CID list, enforcing ≤MaxScreenshots and per-CID
// length. Blank entries are dropped. Empty input → nil.
func parseScreenshots(csv string) []string {
	if csv == "" {
		return nil
	}
	parts := strings.Split(csv, ",")
	if len(parts) > MaxScreenshots {
		panic("too many screenshots (max " + itoa(MaxScreenshots) + ")")
	}
	out := make([]string, 0, len(parts))
	for _, p := range parts {
		p = strings.TrimSpace(p)
		if p == "" {
			continue
		}
		if len(p) > MaxCIDLen {
			panic("screenshot CID too long")
		}
		out = append(out, p)
	}
	return out
}

// ── index + counter maintenance ───────────────────────────────────────────────

func statusKey(status string, id uint64) string { return status + "\x00" + zeroPad(id) }

func pubKey(pub address, id uint64) string { return pub.String() + "\x00" + zeroPad(id) }

// idInUse reports whether `id` is already present in the status index under ANY status (every
// listing — registered or seeded — is in exactly one statusIndex entry). Used to reject a
// duplicate SeedListing id before it silently collides on the composite key.
func idInUse(id uint64) bool {
	for _, s := range []string{StatusPending, StatusLive, StatusRejected, StatusDelisted} {
		if _, ok := statusIndex.Get(statusKey(s, id)); ok {
			return true
		}
	}
	return false
}

// zeroPad renders id as a fixed-width 20-digit string so lexical avl order == numeric order.
func zeroPad(id uint64) string {
	s := itoa64(id)
	for len(s) < 20 {
		s = "0" + s
	}
	return s
}

func adjustCounter(status string, d int) {
	switch status {
	case StatusLive:
		liveCount += d
	case StatusPending:
		pendingCount += d
	case StatusRejected:
		rejectedCount += d
	case StatusDelisted:
		delistedCount += d
	}
}

// indexInsert adds a brand-new listing to the status + publisher indexes and bumps its status
// counter. (publisherIndex never changes afterward — Publisher + Id are immutable.)
func indexInsert(l *Listing) {
	statusIndex.Set(statusKey(l.Status, l.Id), l.PkgPath)
	publisherIndex.Set(pubKey(l.Publisher, l.Id), l.PkgPath)
	adjustCounter(l.Status, 1)
}

// changeStatus moves a listing between statuses, keeping statusIndex + counters exact, and
// persists the listing. Every status transition MUST go through here.
func changeStatus(l *Listing, newStatus string) {
	statusIndex.Remove(statusKey(l.Status, l.Id))
	adjustCounter(l.Status, -1)
	l.Status = newStatus
	statusIndex.Set(statusKey(newStatus, l.Id), l.PkgPath)
	adjustCounter(newStatus, 1)
	listings.Set(l.PkgPath, l)
}

// validatePkgPath normalizes + sanity-checks a realm/package path.
func validatePkgPath(p string) string {
	if len(p) == 0 || len(p) > MaxPkgPathLen {
		panic("pkgPath must be 1.." + itoa(MaxPkgPathLen) + " chars")
	}
	// Reject control and space bytes: composite avl keys separate on "\x00" and
	// ClearFlags range-iterates the pkgPath prefix ([p+"\x00", p+"\x01")), so an
	// embedded control byte could bleed one listing's key range into another's.
	// Applies to RegisterApp, EditListing (via mustGet key use) AND SeedListing —
	// a migration must not import such a path either.
	for i := 0; i < len(p); i++ {
		if p[i] <= 0x20 || p[i] == 0x7f {
			panic("pkgPath contains control or space characters")
		}
	}
	if !hasPrefix(p, "gno.land/r/") && !hasPrefix(p, "gno.land/p/") {
		panic("pkgPath must be a gno.land/r/... or gno.land/p/... path")
	}
	return p
}

func hasPrefix(s, pre string) bool {
	return len(s) >= len(pre) && s[:len(pre)] == pre
}

func itoa(n int) string      { return ufmt.Sprintf("%d", n) }
func itoa64(n uint64) string { return ufmt.Sprintf("%d", n) }
