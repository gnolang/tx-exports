// Package tokens creates registered Launchpad GRC20 ledgers for the issuer
// realms listed in config. A token belongs to the issuer that created it: no
// other realm, and no admin, can mint into it.
package tokens

import (
	"chain"
	"strconv"

	"gno.land/p/nt/avl/v0"
	"gno.land/p/nt/grc20/v0"
	"gno.land/p/nt/seqid/v0"
	"gno.land/p/samcrew/launchpad/currency/v1"
	"gno.land/p/samcrew/launchpad/meta/v1"
	sm "gno.land/p/samcrew/launchpad/safemath/v1"
	"gno.land/r/nt/grc20reg/v0"
	"gno.land/r/samcrew/launchpad/config/v1"
)

const (
	ModeDirectFixed = "direct_fixed"
	ModeDirectCap   = "direct_capped"
	ModeFairSale    = "fairsale"
	maxPublicID     = 9_999_999_999 // T plus ten decimal digits: GRC20 MaxSymbolLen is 11.
)

// Metadata is editable only by the original creator until frozen.
type Metadata struct {
	Description string
	Image       string
	Website     string
	XHandle     string
	Telegram    string
}

// createSpec is assembled within this realm: a foreign Gno realm cannot
// allocate a struct declared here, so the crossing interface uses scalars.
type createSpec struct {
	Creator         address
	Mode            string
	Name            string
	Ticker          string
	Decimals        int
	InitialSupply   int64
	MaxSupply       int64
	CurrencyKey     string
	ExpectedVersion int64
	Metadata        Metadata
}

// Info excludes the private ledger capability and can be returned safely.
type Info struct {
	ID              string
	RegistryKey     string
	GRC20ID         string
	Issuer          address
	Creator         address
	Mode            string
	Name            string
	Ticker          string
	Decimals        int
	InitialSupply   int64
	MaxSupply       int64
	ConfigVersion   int64
	CurrencyKey     string
	Metadata        Metadata
	MetadataFrozen  bool
	MintAuthority   address
	PendingMintAuth address
	MintRenounced   bool
}

type entry struct {
	info   Info
	token  *grc20.Token
	ledger *grc20.PrivateLedger
}

// Tokens live in an AVL tree: creating one touches its own entry and the path
// to it, whatever the number of tokens. A Go map, or a slice of their ids,
// would be rewritten whole on every creation. Ids are T1, T2, ... in creation
// order and no token is ever removed, so a page of the list is a range of ids.
var (
	nextID  seqid.ID
	entries = avl.NewTree() // token id -> *entry
)

// requireIssuer returns the immediate caller, which config must list as a
// token issuer. Only a realm's own address is ever listed, so an account or a
// script never passes.
func requireIssuer(cur realm) address {
	if !cur.IsCurrent() {
		panic("launchpad/tokens: stale realm context")
	}
	issuer := cur.Previous().Address()
	if !config.IsIssuer(config.LedgerTokens, issuer) {
		panic("launchpad/tokens: token issuer only")
	}
	return issuer
}

func check(err error) {
	if err != nil {
		panic(err.Error())
	}
}

// caller is the immediate user or realm. Coins a user attaches to a direct
// call would land in this realm, which has no way to return them.
func caller(cur realm) address {
	if !cur.IsCurrent() {
		panic("launchpad/tokens: stale realm context")
	}
	currency.AssertNoCoins(0, cur)
	return cur.Previous().Address()
}

// The ledger keys balances and allowances by the address text, so an address
// in any spelling but the one the chain gives a caller would hold something
// no caller can reach.
func requireAddress(a address) {
	if !meta.ValidAddress(a) {
		panic("launchpad/tokens: invalid address")
	}
}

func validateMetadata(m Metadata) {
	check(meta.Description(m.Description))
	check(meta.Image(m.Image))
	check(meta.Website(m.Website))
	check(meta.Handle(m.XHandle))
	check(meta.Handle(m.Telegram))
}

// The founding names remain unavailable even if governance globally clears a
// config reservation. A creator-specific grant needs its own reviewed proof.
func protectedTicker(ticker string) bool {
	switch ticker {
	case "MEMBA", "GNOT", "UGNOT", "WUGNOT", "GNS", "USDC", "USDT", "ATOM", "BTC", "ETH", "SAMCREW":
		return true
	}
	return false
}

func validateSpec(s createSpec) {
	requireAddress(s.Creator)
	check(meta.Name(s.Name))
	check(meta.Ticker(s.Ticker))
	validateMetadata(s.Metadata)
	if s.Decimals < 0 || s.Decimals > grc20.MaxDecimals ||
		s.InitialSupply <= 0 || s.MaxSupply < s.InitialSupply ||
		protectedTicker(s.Ticker) || config.IsReserved(s.Ticker) {
		panic("launchpad/tokens: invalid launch terms")
	}
	switch s.Mode {
	case ModeFairSale:
		if s.Decimals > 12 || s.MaxSupply != s.InitialSupply {
			panic("launchpad/tokens: invalid fair-sale terms")
		}
	case ModeDirectFixed:
		if s.Decimals > 12 || s.MaxSupply != s.InitialSupply {
			panic("launchpad/tokens: invalid direct terms")
		}
	case ModeDirectCap:
		if s.Decimals > 12 || s.MaxSupply <= s.InitialSupply {
			panic("launchpad/tokens: invalid capped terms")
		}
	default:
		panic("launchpad/tokens: invalid mode")
	}
}

func laneForMode(mode string) string {
	switch mode {
	case ModeDirectFixed, ModeDirectCap:
		return config.LaneDirect
	case ModeFairSale:
		return config.LaneFairSale
	}
	panic("launchpad/tokens: invalid mode")
}

func nextPublicID() (string, seqid.ID) {
	if uint64(nextID) >= maxPublicID {
		panic("launchpad/tokens: token ID exhausted")
	}
	idNumber := nextID.Next()
	return "T" + strconv.FormatUint(uint64(idNumber), 10), idNumber
}

// Create registers exactly one new GRC20 for a listed issuer, which must
// authenticate the creator, reserve the launch terms and collect payment
// before this crossing call. The currency key names the config action
// currency: creation-fee currency for a direct token, quote currency for a
// fair sale; the issuer binds it to the corresponding payment route. The
// public symbol T<n> is distinct from the nonunique creator-selected ticker.
// The whole initial mint lands in the issuer's custody for atomic allocation
// and escrow setup, and the token stays bound to that issuer.
func Create(cur realm, creator address, mode, name, ticker string,
	decimals int, initialSupply, maxSupply int64,
	currencyKey string, expectedVersion int64,
	description, image, website, xHandle, telegram string) string {
	issuer := requireIssuer(cur)
	s := createSpec{
		Creator: creator, Mode: mode, Name: name, Ticker: ticker,
		Decimals: decimals, InitialSupply: initialSupply, MaxSupply: maxSupply,
		CurrencyKey: currencyKey,
		ExpectedVersion: expectedVersion,
		Metadata: Metadata{
			Description: description, Image: image, Website: website,
			XHandle: xHandle, Telegram: telegram,
		},
	}
	validateSpec(s)
	config.AssertNewAction(laneForMode(s.Mode), s.CurrencyKey, s.ExpectedVersion)
	id, idNumber := nextPublicID()
	token, ledger := grc20.NewToken(s.Name, id, s.Decimals, idNumber, cur)
	check(ledger.Mint(issuer, s.InitialSupply))
	registryKey := grc20reg.Register(cross(cur), token, id)
	info := Info{
		ID: id, RegistryKey: registryKey, GRC20ID: token.ID(),
		Issuer: issuer, Creator: s.Creator,
		Mode: s.Mode, Name: s.Name, Ticker: s.Ticker, Decimals: s.Decimals,
		InitialSupply: s.InitialSupply, MaxSupply: s.MaxSupply,
		ConfigVersion: s.ExpectedVersion, CurrencyKey: s.CurrencyKey,
		Metadata: s.Metadata,
	}
	if s.Mode == ModeDirectCap {
		info.MintAuthority = s.Creator
	}
	entries.Set(id, &entry{info: info, token: token, ledger: ledger})
	chain.Emit("LaunchpadTokenCreated", "id", id, "registry_key", registryKey,
		"grc20_id", token.ID(), "issuer", issuer.String(),
		"creator", s.Creator.String(),
		"mode", s.Mode, "ticker", s.Ticker, "currency_key", s.CurrencyKey)
	return id
}

func mustEntry(id string) *entry {
	e, ok := entries.Get(id).(*entry)
	if !ok || e.info.ID != id {
		panic("launchpad/tokens: unknown token")
	}
	return e
}

func GetInfo(id string) Info { return mustEntry(id).info }

// Count is the number of tokens created: ids are T1 to T<Count>, none removed.
func Count() int64 { return int64(nextID) }

func RegistryKeyOf(id string) string { return mustEntry(id).info.RegistryKey }

func BalanceOf(id string, owner address) int64 {
	requireAddress(owner)
	return mustEntry(id).token.BalanceOf(owner)
}

func TotalSupply(id string) int64 { return mustEntry(id).token.TotalSupply() }

// MintCapped can only be reached through the issuer that created the token.
// That issuer authenticates the live caller as the current mint authority
// and must partition the newly minted balance into recorded allocations in
// this same transaction. The ledger independently rechecks the authority and
// the immutable cap, and takes no mint while the direct lane is closed: the
// pauser stops every issuer here, whatever each one checks by itself.
func MintCapped(cur realm, id string, authority address, amount int64) {
	issuer := requireIssuer(cur)
	e := mustEntry(id)
	config.AssertLaneOpen(config.LaneDirect, e.info.CurrencyKey)
	if e.info.Issuer != issuer || e.info.Mode != ModeDirectCap || e.info.MintRenounced ||
		e.info.MintAuthority != authority || amount <= 0 ||
		sm.Add(e.token.TotalSupply(), amount) > e.info.MaxSupply {
		panic("launchpad/tokens: capped mint denied")
	}
	check(e.ledger.Mint(issuer, amount))
	chain.Emit("LaunchpadTokenCappedMinted", "id", id,
		"authority", authority.String(), "amount", strconv.FormatInt(amount, 10))
}

func Allowance(id string, owner, spender address) int64 {
	requireAddress(owner)
	requireAddress(spender)
	return mustEntry(id).token.Allowance(owner, spender)
}

// Standard wrappers operate only on the immediate caller's balance or
// allowance, accept no coins, and take an address only as the chain writes
// one. A realm can also move its own balance, or an allowance it holds,
// through the token in the registry, where the GRC20 library alone checks the
// receiver. A script an account runs is such a realm with the account's
// address, so these wrappers are an account's only way in only while the
// chain does not let that account submit scripts.
func Transfer(cur realm, id string, to address, amount int64) {
	caller(cur)
	requireAddress(to)
	check(mustEntry(id).ledger.CallerTeller().Transfer(0, cur, to, amount))
}

func Approve(cur realm, id string, spender address, amount int64) {
	caller(cur)
	requireAddress(spender)
	check(mustEntry(id).ledger.CallerTeller().Approve(0, cur, spender, amount))
}

func TransferFrom(cur realm, id string, from, to address, amount int64) {
	caller(cur)
	requireAddress(from)
	requireAddress(to)
	check(mustEntry(id).ledger.CallerTeller().TransferFrom(0, cur, from, to, amount))
}

func Burn(cur realm, id string, amount int64) {
	who := caller(cur)
	if amount <= 0 {
		panic("launchpad/tokens: invalid burn")
	}
	check(mustEntry(id).ledger.Burn(who, amount))
}

func SetMetadata(cur realm, id, description, image, website, xHandle, telegram string) {
	who := caller(cur)
	e := mustEntry(id)
	if e.info.MetadataFrozen || who != e.info.Creator {
		panic("launchpad/tokens: creator metadata only")
	}
	m := Metadata{
		Description: description, Image: image, Website: website,
		XHandle: xHandle, Telegram: telegram,
	}
	validateMetadata(m)
	e.info.Metadata = m
	chain.Emit("TokenMetadataChanged", "id", id, "creator", e.info.Creator.String())
}

func FreezeMetadata(cur realm, id string) {
	who := caller(cur)
	e := mustEntry(id)
	if e.info.MetadataFrozen || who != e.info.Creator {
		panic("launchpad/tokens: creator metadata only")
	}
	e.info.MetadataFrozen = true
	chain.Emit("TokenMetadataFrozen", "id", id, "creator", e.info.Creator.String())
}

// A capped token's authority moves only through its own two-step handoff.
// The issuer checks this live authority before each later mint.
func ProposeMintAuthority(cur realm, id string, next address) {
	who := caller(cur)
	e := mustEntry(id)
	if e.info.Mode != ModeDirectCap || e.info.MintRenounced ||
		who != e.info.MintAuthority ||
		!meta.ValidAddress(next) || next == e.info.MintAuthority {
		panic("launchpad/tokens: mint authority only")
	}
	e.info.PendingMintAuth = next
	chain.Emit("MintAuthorityProposed", "id", id, "next", next.String())
}

func CancelMintAuthority(cur realm, id string) {
	who := caller(cur)
	e := mustEntry(id)
	if e.info.Mode != ModeDirectCap || e.info.MintRenounced ||
		who != e.info.MintAuthority || e.info.PendingMintAuth == "" {
		panic("launchpad/tokens: no mint authority proposal")
	}
	e.info.PendingMintAuth = ""
	chain.Emit("MintAuthorityCancelled", "id", id)
}

func AcceptMintAuthority(cur realm, id string) {
	who := caller(cur)
	e := mustEntry(id)
	if e.info.Mode != ModeDirectCap || e.info.MintRenounced ||
		e.info.PendingMintAuth == "" || who != e.info.PendingMintAuth {
		panic("launchpad/tokens: pending mint authority only")
	}
	e.info.MintAuthority = who
	e.info.PendingMintAuth = ""
	chain.Emit("MintAuthorityAccepted", "id", id, "authority", who.String())
}

func RenounceMintAuthority(cur realm, id string) {
	who := caller(cur)
	e := mustEntry(id)
	if e.info.Mode != ModeDirectCap || e.info.MintRenounced ||
		who != e.info.MintAuthority {
		panic("launchpad/tokens: mint authority only")
	}
	e.info.MintAuthority = ""
	e.info.PendingMintAuth = ""
	e.info.MintRenounced = true
	chain.Emit("MintAuthorityRenounced", "id", id)
}

func Render(path string) string {
	if path == "" {
		return "# Launchpad tokens\n\nRegistered GRC20 ledgers created by the issuers listed in config.\n"
	}
	e := mustEntry(path)
	return "# " + meta.EscapeMarkdown(e.info.Name) + "\n\nTicker: " +
		meta.EscapeMarkdown(e.info.Ticker) + "\n"
}
