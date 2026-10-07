// Package config is the versioned, governed configuration for Memba Launchpad.
// Its admin is the account that published it until a two-step handoff moves
// the role. Every lane starts paused and without terms.
package config

import (
	"strconv"
	"strings"

	"chain"
	"chain/runtime/unsafe"
	"gno.land/p/samcrew/launchpad/meta/v1"
	sm "gno.land/p/samcrew/launchpad/safemath/v1"
	"gno.land/r/nt/grc20reg/v0"
)

const (
	LaneDirect     = "direct"
	LaneFairSale   = "fairsale"
	LaneAirdrop    = "airdrop"
	LaneCollection = "collection"
	LaneNFTDrops   = "nft_drops"
	LaneNFTMarket  = "nft_market"
	NativeCurrency = "ugnot"
	LedgerTokens   = "tokens"
	LedgerNFT      = "nft"
	maxCurrencies  = 16
	maxIssuers     = 32
	issuerPrefix   = "gno.land/r/samcrew/"
	maxCreationFee = sm.MaxInt64 / 12
)

// CurrencyParams holds the terms of one quote currency. A fee of -1 closes
// the lane that charges it.
type CurrencyParams struct {
	Key                 string
	DirectCreationFee   int64
	FairSaleCreationFee int64 // never below DirectCreationFee: cancelling a sale returns its allocation
	FairSaleRaiseCap    int64 // most quote one fair sale may hold in escrow; 0 closes fair sales
	CollectionFee       int64
}

// Params is one immutable snapshot of launch terms. A rate of -1 closes the
// lane that charges it.
type Params struct {
	PrimaryFeeBPS      int64 // share of settled fair-sale proceeds
	NFTPrimaryFeeBPS   int64
	NFTSecondaryFeeBPS int64
	Treasury           address
	Currencies         []CurrencyParams
}

var (
	lanes = []string{LaneDirect, LaneFairSale, LaneAirdrop, LaneCollection, LaneNFTDrops, LaneNFTMarket}
	// No function of these realms can pay out a balance sent to their address.
	unspendable = []string{
		"gno.land/r/samcrew/launchpad/config/v1",
		"gno.land/r/samcrew/launchpad/tokens/v1",
		"gno.land/r/samcrew/launchpad/sales/v1",
		"gno.land/r/samcrew/launchpad/nft/v1",
		"gno.land/r/samcrew/launchpad/drops/v1",
		"gno.land/r/samcrew/launchpad/market/v1",
		"gno.land/r/samcrew/launchpad/curation/v1",
		"gno.land/r/samcrew/memba_dao",
		// The governance core and its bridge to the legacy apps hold no
		// treasury and no generic call: nothing there could pay a fee out.
		"gno.land/r/samcrew/memba_gov",
		"gno.land/r/samcrew/memba_bridge_v1",
	}

	admin        address
	pendingAdmin address
	pauser       address
	issuers      = map[string]bool{} // "<ledger>:<realm address>"
	versions     []Params
	allowed      = map[string]bool{}
	paused       = map[string]bool{}
	verified     = map[string]bool{}
	reserved     = map[string]bool{}
	owedCeilings = map[string]int64{} // absent: no ceiling
)

func init() {
	admin = unsafe.OriginCaller()
	versions = []Params{{PrimaryFeeBPS: -1, NFTPrimaryFeeBPS: -1, NFTSecondaryFeeBPS: -1}}
	for _, lane := range lanes {
		paused[lane] = true
	}
	for _, ticker := range []string{"MEMBA", "GNOT", "UGNOT", "WUGNOT", "GNS", "USDC", "USDT", "ATOM", "BTC", "ETH", "SAMCREW"} {
		reserved[ticker] = true
	}
}

// caller is the immediate user or realm. Coins attached to a direct call
// would land in this realm, which has no way to return them.
func caller(cur realm) address {
	// The pinned VM already refuses a realm context that is not the live one
	// before this line runs. Published code outlives a VM release, so the
	// check stays.
	if !cur.IsCurrent() {
		panic("launchpad/config: stale realm context")
	}
	if cur.Previous().IsUserCall() && len(unsafe.OriginSend()) != 0 {
		panic("launchpad/config: this call does not accept coins")
	}
	return cur.Previous().Address()
}

func requireAdmin(cur realm) {
	if caller(cur) != admin {
		panic("launchpad/config: admin only")
	}
}

func unspendableRealm(who address) bool {
	for _, path := range unspendable {
		if who == chain.PackageAddress(path) {
			return true
		}
	}
	return false
}

// IsUnspendable reports whether a fee or a royalty paid to who could never
// be paid out again: who is one of the realms listed above, which have no
// function for that, or it is not an address as the chain writes one, so no
// caller can ever present it. It is a check for such receivers only, not for
// the recipient of a transfer: the sales realm is on the list and rightly
// holds and moves ledger balances of its own.
func IsUnspendable(who address) bool {
	return !meta.ValidAddress(who) || unspendableRealm(who)
}

func validLane(lane string) bool {
	for _, l := range lanes {
		if l == lane {
			return true
		}
	}
	return false
}

func versionString() string { return strconv.FormatInt(GetCurrentVersion(), 10) }

func validAssetID(id string) bool {
	if len(id) < 2 || len(id) > 20 || (id[0] != 'T' && id[0] != 'C') || id[1] < '1' || id[1] > '9' {
		return false
	}
	for i := 2; i < len(id); i++ {
		if id[i] < '0' || id[i] > '9' {
			return false
		}
	}
	n, err := strconv.ParseInt(id[1:], 10, 64)
	return err == nil && n > 0
}

// ProposeAdmin stages a handoff to a user account or a realm. Nothing changes
// until that exact address accepts, so a target that cannot call is harmless.
func ProposeAdmin(cur realm, next address) {
	requireAdmin(cur)
	if !meta.ValidAddress(next) || next == admin {
		panic("launchpad/config: invalid next admin")
	}
	pendingAdmin = next
	chain.Emit("AdminProposed", "admin", admin.String(), "pending", next.String())
}

func CancelAdminProposal(cur realm) {
	requireAdmin(cur)
	if pendingAdmin == "" {
		panic("launchpad/config: no pending admin")
	}
	pendingAdmin = ""
	chain.Emit("AdminProposalCancelled", "admin", admin.String())
}

func AcceptAdmin(cur realm) {
	who := caller(cur)
	if pendingAdmin == "" || who != pendingAdmin {
		panic("launchpad/config: pending admin only")
	}
	previous := admin
	admin = who
	pendingAdmin = ""
	chain.Emit("AdminAccepted", "admin", who.String(), "previous", previous.String())
}

// validIssuerPath accepts a realm path below the samcrew namespace whose
// segments are plain lowercase names: nothing that could resolve elsewhere.
func validIssuerPath(path string) bool {
	if len(path) > 200 || !strings.HasPrefix(path, issuerPrefix) {
		return false
	}
	for _, segment := range strings.Split(path[len(issuerPrefix):], "/") {
		if segment == "" {
			return false
		}
		for i := 0; i < len(segment); i++ {
			c := segment[i]
			if (c < 'a' || c > 'z') && (c < '0' || c > '9') && c != '_' {
				return false
			}
		}
	}
	return true
}

// AllowIssuer lists a realm under gno.land/r/samcrew/ as an issuer for one
// ledger to read. The list only grows, so a ledger can bind what an issuer
// created to that issuer for good.
func AllowIssuer(cur realm, ledger, pkgPath string) {
	requireAdmin(cur)
	if (ledger != LedgerTokens && ledger != LedgerNFT) || !validIssuerPath(pkgPath) ||
		len(issuers) >= maxIssuers {
		panic("launchpad/config: invalid issuer")
	}
	issuer := chain.PackageAddress(pkgPath)
	if issuer == cur.Address() {
		panic("launchpad/config: invalid issuer")
	}
	key := ledger + ":" + issuer.String()
	if issuers[key] {
		panic("launchpad/config: issuer already allowed")
	}
	issuers[key] = true
	chain.Emit("IssuerAllowed", "ledger", ledger, "path", pkgPath, "issuer", issuer.String(), "actor", admin.String())
}

func IsIssuer(ledger string, who address) bool { return issuers[ledger+":"+who.String()] }

func GetAdmin() address        { return admin }
func GetPendingAdmin() address { return pendingAdmin }
func GetPauser() address       { return pauser }

func copyParams(p Params) Params {
	copyP := p
	copyP.Currencies = make([]CurrencyParams, len(p.Currencies))
	copy(copyP.Currencies, p.Currencies)
	return copyP
}

func GetCurrentVersion() int64 { return int64(len(versions)) }

func GetVersion(version int64) Params {
	if version < 1 || version > int64(len(versions)) {
		panic("launchpad/config: unknown version")
	}
	return copyParams(versions[version-1])
}

// One value of the current terms each, so a check can compare its text: the
// publisher's manual flow reads one before and after each setter. A rate or a
// fee of -1 is not set; so is every fee of a currency without terms.
func GetTreasury() address         { return versions[len(versions)-1].Treasury }
func GetPrimaryFeeBPS() int64      { return versions[len(versions)-1].PrimaryFeeBPS }
func GetNFTPrimaryFeeBPS() int64   { return versions[len(versions)-1].NFTPrimaryFeeBPS }
func GetNFTSecondaryFeeBPS() int64 { return versions[len(versions)-1].NFTSecondaryFeeBPS }

// GetTokenTerms is "<direct creation fee>,<fair-sale creation fee>,<raise cap>"
// in a currency.
func GetTokenTerms(key string) string {
	c, ok := findCurrency(versions[len(versions)-1], key)
	if !ok {
		return "-1,-1,0"
	}
	return strconv.FormatInt(c.DirectCreationFee, 10) + "," + strconv.FormatInt(c.FairSaleCreationFee, 10) + "," + strconv.FormatInt(c.FairSaleRaiseCap, 10)
}

func GetCollectionFee(key string) int64 {
	c, ok := findCurrency(versions[len(versions)-1], key)
	if !ok {
		return -1
	}
	return c.CollectionFee
}

func AssertExpectedVersion(expected int64) {
	if expected != GetCurrentVersion() {
		panic("config changed")
	}
}

func validateParams(p Params) {
	if p.PrimaryFeeBPS < -1 || p.PrimaryFeeBPS > 500 ||
		p.NFTPrimaryFeeBPS < -1 || p.NFTPrimaryFeeBPS > 500 ||
		p.NFTSecondaryFeeBPS < -1 || p.NFTSecondaryFeeBPS > 200 {
		panic("launchpad/config: parameter out of range")
	}
	if p.Treasury != "" {
		if !meta.ValidAddress(p.Treasury) {
			panic("launchpad/config: invalid treasury")
		}
		if unspendableRealm(p.Treasury) {
			panic("launchpad/config: treasury cannot spend")
		}
	}
	if len(p.Currencies) > maxCurrencies {
		panic("launchpad/config: too many currencies")
	}
	seen := map[string]bool{}
	for _, c := range p.Currencies {
		if c.Key == "" || len(c.Key) > 200 || seen[c.Key] ||
			(c.Key != NativeCurrency && grc20reg.Get(c.Key) == nil) ||
			c.DirectCreationFee < -1 || c.DirectCreationFee > maxCreationFee ||
			c.FairSaleCreationFee < -1 || c.FairSaleCreationFee > maxCreationFee ||
			c.CollectionFee < -1 || c.CollectionFee > maxCreationFee ||
			c.FairSaleRaiseCap < 0 {
			panic("launchpad/config: invalid currency terms")
		}
		if c.FairSaleCreationFee >= 0 &&
			(c.DirectCreationFee < 0 || c.FairSaleCreationFee < c.DirectCreationFee) {
			panic("launchpad/config: fair-sale fee below direct fee")
		}
		// With direct <= fair < cap, and no cap while fair sales are closed,
		// no two of the three can be swapped unnoticed.
		if c.FairSaleRaiseCap != 0 &&
			(c.FairSaleCreationFee < 0 || c.FairSaleRaiseCap <= c.FairSaleCreationFee) {
			panic("launchpad/config: raise cap not above fair-sale fee")
		}
		seen[c.Key] = true
	}
}

// Terms change only through the setters below. Each takes scalar arguments,
// so a user account can call it, and appends one snapshot that passed the
// whole validation; earlier snapshots never change. A launch pins the version
// it was created under, and an action signed against an older version fails.

func latest() Params { return copyParams(versions[len(versions)-1]) }

func appendVersion(next Params, change string) int64 {
	validateParams(next)
	versions = append(versions, next)
	chain.Emit("ConfigVersionAdded", "version", versionString(), "change", change, "actor", admin.String())
	return GetCurrentVersion()
}

func findCurrency(p Params, key string) (CurrencyParams, bool) {
	for _, c := range p.Currencies {
		if c.Key == key {
			return c, true
		}
	}
	return CurrencyParams{}, false
}

// currencyTerms returns the index of key's terms in p, adding them with every
// lane closed when the currency is new.
func currencyTerms(p *Params, key string) int {
	for i, c := range p.Currencies {
		if c.Key == key {
			return i
		}
	}
	p.Currencies = append(p.Currencies, CurrencyParams{
		Key: key, DirectCreationFee: -1, FairSaleCreationFee: -1, CollectionFee: -1,
	})
	return len(p.Currencies) - 1
}

// SetTreasury names the receiver of protocol fees. Once named it can be
// replaced, not removed.
func SetTreasury(cur realm, treasury address) int64 {
	requireAdmin(cur)
	if treasury == "" {
		panic("launchpad/config: invalid treasury")
	}
	next := latest()
	next.Treasury = treasury
	return appendVersion(next, "treasury")
}

func SetPrimaryFeeBPS(cur realm, bps int64) int64 {
	requireAdmin(cur)
	next := latest()
	next.PrimaryFeeBPS = bps
	return appendVersion(next, "primary_fee")
}

func SetNFTPrimaryFeeBPS(cur realm, bps int64) int64 {
	requireAdmin(cur)
	next := latest()
	next.NFTPrimaryFeeBPS = bps
	return appendVersion(next, "nft_primary_fee")
}

func SetNFTSecondaryFeeBPS(cur realm, bps int64) int64 {
	requireAdmin(cur)
	next := latest()
	next.NFTSecondaryFeeBPS = bps
	return appendVersion(next, "nft_secondary_fee")
}

// SetTokenTerms prices token creation in one currency and bounds what a
// single fair sale may raise in it.
func SetTokenTerms(cur realm, key string, directCreationFee, fairSaleCreationFee, fairSaleRaiseCap int64) int64 {
	requireAdmin(cur)
	next := latest()
	i := currencyTerms(&next, key)
	next.Currencies[i].DirectCreationFee = directCreationFee
	next.Currencies[i].FairSaleCreationFee = fairSaleCreationFee
	next.Currencies[i].FairSaleRaiseCap = fairSaleRaiseCap
	return appendVersion(next, "token_terms")
}

func SetCollectionFee(cur realm, key string, fee int64) int64 {
	requireAdmin(cur)
	next := latest()
	i := currencyTerms(&next, key)
	next.Currencies[i].CollectionFee = fee
	return appendVersion(next, "collection_fee")
}

// RemoveCurrency drops a currency's terms, its allowlist entry and its owed
// ceiling, so adding terms again later neither reopens it nor brings back an
// old ceiling by itself.
func RemoveCurrency(cur realm, key string) int64 {
	requireAdmin(cur)
	current := latest()
	next := current
	next.Currencies = nil
	for _, c := range current.Currencies {
		if c.Key != key {
			next.Currencies = append(next.Currencies, c)
		}
	}
	if len(next.Currencies) == len(current.Currencies) {
		panic("launchpad/config: unknown currency")
	}
	delete(allowed, key)
	delete(owedCeilings, key)
	return appendVersion(next, "currency_removed")
}

// IsLaneReady checks only immutable terms. The immediate allowlist is checked
// at action time so delisting cannot prevent an old launch's exits.
func IsLaneReady(lane, currency string) bool {
	p := versions[len(versions)-1]
	c, ok := findCurrency(p, currency)
	if !ok || p.Treasury == "" {
		return false
	}
	switch lane {
	// A direct fee is what opens a currency to the token lanes: a fair sale
	// cannot be priced without one, and an airdrop, which is free, needs it too.
	case LaneDirect, LaneAirdrop:
		return c.DirectCreationFee >= 0
	case LaneFairSale:
		return c.FairSaleCreationFee >= 0 && c.FairSaleRaiseCap > 0 && p.PrimaryFeeBPS >= 0
	// A collection fee is what opens a currency to the NFT lanes.
	case LaneCollection:
		return c.CollectionFee >= 0
	case LaneNFTDrops:
		return c.CollectionFee >= 0 && p.NFTPrimaryFeeBPS >= 0
	case LaneNFTMarket:
		return c.CollectionFee >= 0 && p.NFTSecondaryFeeBPS >= 0
	}
	return false
}

// Pause closes a lane to new launches and contributions. Claims, refunds and
// settlements never read the gate, so nothing here can hold funds back.
func Pause(cur realm, lane string) {
	who := caller(cur)
	if !validLane(lane) {
		panic("launchpad/config: invalid lane")
	}
	if who != admin && who != pauser {
		panic("launchpad/config: pauser or admin only")
	}
	paused[lane] = true
	chain.Emit("LanePaused", "lane", lane, "actor", who.String())
}

// Unpause opens a lane. It needs a pauser in place and one listed currency
// whose terms for the lane are complete.
func Unpause(cur realm, lane, currency string) {
	requireAdmin(cur)
	if !validLane(lane) {
		panic("launchpad/config: invalid lane")
	}
	if pauser == "" || !allowed[currency] || !IsLaneReady(lane, currency) {
		panic("launchpad/config: lane is incomplete")
	}
	paused[lane] = false
	chain.Emit("LaneUnpaused", "lane", lane, "currency", currency, "version", versionString(), "actor", admin.String())
}

func IsPaused(lane string) bool {
	if !validLane(lane) {
		return true
	}
	return paused[lane]
}

// AssertLaneOpen gates a new inflow: the lane is open and the currency is
// listed with complete terms. A caller that charges the terms in force reads
// them in the same transaction, as the NFT realms do; one that charges at the
// version its user signed for checks that version with AssertNewAction, as
// token creations and fair-sale launches do. The token lanes' exits use the
// terms recorded at launch and pass no gate.
func AssertLaneOpen(lane, currency string) {
	if IsPaused(lane) || !allowed[currency] || !IsLaneReady(lane, currency) {
		panic("launchpad/config: new action unavailable")
	}
}

// AssertNewAction also pins the version whose prices the caller signed for.
func AssertNewAction(lane, currency string, expectedVersion int64) {
	AssertExpectedVersion(expectedVersion)
	AssertLaneOpen(lane, currency)
}

// SetPauser names the one address, besides the admin, that may close lanes.
func SetPauser(cur realm, next address) {
	requireAdmin(cur)
	if !meta.ValidAddress(next) {
		panic("launchpad/config: invalid pauser")
	}
	pauser = next
	chain.Emit("PauserChanged", "pauser", next.String(), "actor", admin.String())
}

func SetCurrencyAllowed(cur realm, key string, value bool) {
	requireAdmin(cur)
	if !value {
		delete(allowed, key)
	} else if _, ok := findCurrency(versions[len(versions)-1], key); ok {
		allowed[key] = true
	} else {
		panic("launchpad/config: currency terms missing")
	}
	chain.Emit("CurrencyAllowed", "currency", key, "allowed", strconv.FormatBool(value), "version", versionString(), "actor", admin.String())
}

func IsCurrencyAllowed(key string) bool { return allowed[key] }

// SetSalesOwedCeiling bounds what the sales realm may owe in one currency,
// its fees, escrow, refunds and proceeds together, for a fair-sale
// contribution to be accepted. Nothing else reads it: settlements, claims,
// releases and sweeps go through at any ceiling, and a ceiling below what is
// already owed only stops new contributions. Unlike a pause, it lets running
// sales take orders while there is room. MaxInt64, the default, is no
// ceiling. It is not a term a launch signs for, so it adds no version.
func SetSalesOwedCeiling(cur realm, key string, ceiling int64) {
	requireAdmin(cur)
	if _, ok := findCurrency(versions[len(versions)-1], key); !ok {
		panic("launchpad/config: currency terms missing")
	}
	if ceiling < 0 {
		panic("launchpad/config: invalid ceiling")
	}
	if ceiling == sm.MaxInt64 {
		delete(owedCeilings, key)
	} else {
		owedCeilings[key] = ceiling
	}
	chain.Emit("SalesOwedCeiling", "currency", key, "ceiling", strconv.FormatInt(ceiling, 10), "actor", admin.String())
}

func GetSalesOwedCeiling(key string) int64 {
	if ceiling, ok := owedCeilings[key]; ok {
		return ceiling
	}
	return sm.MaxInt64
}

func SetVerified(cur realm, assetID string, value bool) {
	requireAdmin(cur)
	if !validAssetID(assetID) {
		panic("launchpad/config: invalid asset ID")
	}
	verified[assetID] = value
	chain.Emit("Verified", "asset", assetID, "verified", strconv.FormatBool(value), "actor", admin.String())
}

func IsVerified(assetID string) bool { return verified[assetID] }

func SetReserved(cur realm, ticker string, value bool) {
	requireAdmin(cur)
	if meta.Ticker(ticker) != nil {
		panic("launchpad/config: invalid ticker")
	}
	reserved[ticker] = value
	chain.Emit("Reserved", "ticker", ticker, "reserved", strconv.FormatBool(value), "actor", admin.String())
}

func IsReserved(ticker string) bool { return reserved[ticker] }
