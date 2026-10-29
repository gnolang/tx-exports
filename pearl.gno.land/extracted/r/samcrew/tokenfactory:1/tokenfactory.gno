// Package tokenfactory — Samouraï Coop Token Factory
//
// A curated GRC20 token factory with on-chain platform fees, event emission,
// input validation, and faucet rate limiting.
//
// Forked from gno.land/r/demo/defi/grc20factory with improvements.
// Uses the standard gno.land/p/demo/tokens/grc20 package and registers
// tokens with gno.land/r/demo/defi/grc20reg for full ecosystem compatibility.
//
// Improvements over upstream:
//   - On-chain platform fee on Mint and initial supply, read live from the
//     DAO fee spine (memba_market_config, lane "token") — D3(b) ruling
//   - chain.Emit events for all state-changing operations
//   - Symbol validation (1-10 uppercase alphanumeric)
//   - Faucet rate limiting (~24h cooldown per address)
//   - Optional token metadata (description, website, IPFS logo)
//
// All original function signatures are preserved for 100% API compatibility.
package tokenfactory_v2

import (
	"chain"
	"chain/runtime"

	"chain/runtime/unsafe"
	"gno.land/p/demo/tokens/grc20"
	"gno.land/p/samcrew/avl"
	p "gno.land/p/samcrew/avl/pager"
	"gno.land/p/samcrew/avl/rotree"
	"gno.land/p/nt/mux/v0"
	"gno.land/p/nt/ownable/v0"
	"gno.land/p/nt/seqid/v0"
	"gno.land/p/nt/ufmt/v0"
	"gno.land/r/demo/defi/grc20reg"
	cfg "gno.land/r/samcrew/memba_market_config"
)

// ── Fee Configuration ────────────────────────────────────────

// D3(b) ruling (2026-08-16): the platform fee is GOVERNED, not baked. Rate and
// recipient are read from the DAO fee spine at mint time (memba_market_config,
// lane "token" — 50 bps at spine init), so governance can tune or zero the fee
// without redeploying this immutable realm. The previous generation baked
// feeRate=25‰ and a fixed recipient with no setter — exactly the config the
// sapphire deploy hold was declared over.

// laneToken is this realm's lane key into the DAO fee config.
const laneToken = "token"

// maxFeeBPS caps the mint fee locally; mirrors memba_market_config.MaxFeeBPS.
// The spine already bounds fees on write — the local clamp means a future
// config redeploy can never overcharge through this realm either.
const maxFeeBPS int64 = 500

// resolveFee reads the token-lane fee (bps) and treasury from the DAO config.
// FAIL-SAFE, with the opposite polarity from a trade engine: a settlement must
// never strand, so the market engines fall back to a frozen fee — but a MINT
// fee is additive platform revenue, so on any implausible read this realm
// charges NOTHING rather than minting to a stale or empty recipient.
func resolveFee() (int64, address) {
	bps := int64(cfg.GetFeeBPS(laneToken))
	treasury := cfg.GetTreasury()
	if bps < 0 || bps > maxFeeBPS || treasury == "" {
		return 0, treasury
	}
	return bps, treasury
}

// ── State ────────────────────────────────────────────────────

var (
	instances        avl.Tree // symbol → *instance
	pager            = p.NewPager(rotree.Wrap(&instances, nil), 20, false)
	faucetCooldowns  avl.Tree // "SYMBOL:addr" → int64 (block height)
	tokenMetas       avl.Tree // symbol → *TokenMeta

	// nextTokenID is the realm-local grc20 token-id allocator required by
	// grc20 #5908 (NewToken now takes a dedicated seqid.ID; Token.ID() =
	// <realm path>.<symbol>.<id>). ONE persistent sequence shared by every
	// creation path — never reset or reused (mirrors upstream grc20factory).
	// Token identity on-chain remains symbol-first for this realm: instances,
	// grc20reg registration and all events stay keyed by symbol, and the
	// duplicate-symbol reject below is unchanged.
	nextTokenID seqid.ID
)

// Faucet cooldown: ~24h at ~2min blocks = 720 blocks.
const faucetCooldownBlocks int64 = 720

type instance struct {
	token  *grc20.Token
	ledger *grc20.PrivateLedger
	admin  *ownable.Ownable
	faucet int64 // per-request amount. disabled if 0.
}

// TokenMeta holds optional metadata for a token.
type TokenMeta struct {
	Description string
	Website     string
	LogoIPFS    string // "ipfs://Qm..."
}

// ── Event Constants ──────────────────────────────────────────

const (
	EventTokenCreated = "TokenCreated"
	EventFaucetClaim  = "FaucetClaim"
	EventMetaUpdated  = "MetaUpdated"
)

// ── Token Creation ───────────────────────────────────────────

// New creates a new GRC20 token with the caller as admin.
// If initialMint > 0, the token-lane platform fee (fee spine) is applied.
func New(cur realm, name, symbol string, decimals int, initialMint, faucet int64) {
	caller := unsafe.PreviousRealm().Address()
	NewWithAdmin(cur, name, symbol, decimals, initialMint, faucet, caller)
}

// NewWithAdmin creates a new GRC20 token with a specified admin address.
// If initialMint > 0, the token-lane platform fee (fee spine) is applied.
func NewWithAdmin(cur realm, name, symbol string, decimals int, initialMint, faucet int64, admin address) {
	// ── Validation ──
	validateSymbol(symbol)
	validateName(name)
	validateDecimals(decimals)

	exists := instances.Has(symbol)
	if exists {
		panic("token already exists")
	}

	token, ledger := grc20.NewToken(name, symbol, decimals, nextTokenID.Next(), cur)

	if initialMint > 0 {
		fee := applyFee(ledger, admin, initialMint)
		chain.Emit(
			grc20.MintEvent,
			"symbol", symbol,
			"to", string(admin),
			"amount", ufmt.Sprintf("%d", initialMint),
			"fee", ufmt.Sprintf("%d", fee),
		)
	}

	inst := instance{
		token:  token,
		ledger: ledger,
		admin:  ownable.NewWithAddress(admin),
		faucet: faucet,
	}
	instances.Set(symbol, &inst)

	// Register with ecosystem registry for GnoSwap/Gnoscan discoverability
	grc20reg.Register(cross(cur), token, symbol)

	chain.Emit(
		EventTokenCreated,
		"symbol", symbol,
		"name", name,
		"decimals", ufmt.Sprintf("%d", decimals),
		"initialMint", ufmt.Sprintf("%d", initialMint),
		"admin", string(admin),
		"faucet", ufmt.Sprintf("%d", faucet),
	)
}

// ── Read-Only Accessors ──────────────────────────────────────

// Bank returns the standard *grc20.Token for ecosystem interop.
func Bank(symbol string) *grc20.Token {
	inst := mustGetInstance(symbol)
	return inst.token
}

func TotalSupply(symbol string) int64 {
	inst := mustGetInstance(symbol)
	return inst.token.ReadonlyTeller().TotalSupply()
}

func HasAddr(symbol string, owner address) bool {
	inst := mustGetInstance(symbol)
	return inst.token.HasAddr(owner)
}

func BalanceOf(symbol string, owner address) int64 {
	inst := mustGetInstance(symbol)
	return inst.token.ReadonlyTeller().BalanceOf(owner)
}

func Allowance(symbol string, owner, spender address) int64 {
	inst := mustGetInstance(symbol)
	return inst.token.ReadonlyTeller().Allowance(owner, spender)
}

// GetFeeConfig returns the current fee rate and recipient address, resolved
// live from the memba_market_config fee spine ("token" lane).
// NOTE: the unit changed per-mille → BASIS POINTS with the D3(b) rewiring.
func GetFeeConfig() (int64, address) {
	return resolveFee()
}

// GetTokenMeta returns the metadata for a token, or nil if not set.
func GetTokenMeta(symbol string) *TokenMeta {
	v, exists := tokenMetas.Get(symbol)
	if !exists {
		return nil
	}
	return v.(*TokenMeta)
}

// ── State-Changing Operations ────────────────────────────────

func Transfer(cur realm, symbol string, to address, amount int64) {
	inst := mustGetInstance(symbol)
	caller := unsafe.PreviousRealm().Address()
	teller := inst.ledger.ImpersonateTeller(caller)
	checkErr(teller.Transfer(0, cur, to, amount))

	chain.Emit(
		grc20.TransferEvent,
		"symbol", symbol,
		"from", string(caller),
		"to", string(to),
		"amount", ufmt.Sprintf("%d", amount),
	)
}

func Approve(cur realm, symbol string, spender address, amount int64) {
	inst := mustGetInstance(symbol)
	caller := unsafe.PreviousRealm().Address()
	teller := inst.ledger.ImpersonateTeller(caller)
	checkErr(teller.Approve(0, cur, spender, amount))

	chain.Emit(
		grc20.ApprovalEvent,
		"symbol", symbol,
		"owner", string(caller),
		"spender", string(spender),
		"amount", ufmt.Sprintf("%d", amount),
	)
}

func TransferFrom(cur realm, symbol string, from, to address, amount int64) {
	inst := mustGetInstance(symbol)
	caller := unsafe.PreviousRealm().Address()
	teller := inst.ledger.ImpersonateTeller(caller)
	checkErr(teller.TransferFrom(0, cur, from, to, amount))

	chain.Emit(
		grc20.TransferEvent,
		"symbol", symbol,
		"from", string(from),
		"to", string(to),
		"amount", ufmt.Sprintf("%d", amount),
		"spender", string(caller),
	)
}

// Mint creates new tokens. Admin only. Token-lane platform fee applied.
func Mint(cur realm, symbol string, to address, amount int64) {
	inst := mustGetInstance(symbol)
	inst.admin.AssertOwnedBy(cur.Previous().Address())

	fee := applyFee(inst.ledger, to, amount)

	chain.Emit(
		grc20.MintEvent,
		"symbol", symbol,
		"to", string(to),
		"amount", ufmt.Sprintf("%d", amount),
		"fee", ufmt.Sprintf("%d", fee),
	)
}

// Burn destroys tokens. Admin only.
func Burn(cur realm, symbol string, from address, amount int64) {
	inst := mustGetInstance(symbol)
	inst.admin.AssertOwnedBy(cur.Previous().Address())
	checkErr(inst.ledger.Burn(from, amount))

	chain.Emit(
		grc20.BurnEvent,
		"symbol", symbol,
		"from", string(from),
		"amount", ufmt.Sprintf("%d", amount),
	)
}

// Faucet mints free tokens if enabled. Rate-limited to ~1 claim per 24h per address.
func Faucet(cur realm, symbol string) {
	inst := mustGetInstance(symbol)
	if inst.faucet == 0 {
		panic("faucet disabled for this token")
	}

	caller := unsafe.PreviousRealm().Address()

	// Rate limiting: per-address cooldown
	key := symbol + ":" + string(caller)
	if v, exists := faucetCooldowns.Get(key); exists {
		lastBlock := v.(int64)
		if runtime.ChainHeight()-lastBlock < faucetCooldownBlocks {
			panic("faucet: cooldown active (try again in ~24h)")
		}
	}

	checkErr(inst.ledger.Mint(caller, inst.faucet))
	faucetCooldowns.Set(key, runtime.ChainHeight())

	chain.Emit(
		EventFaucetClaim,
		"symbol", symbol,
		"to", string(caller),
		"amount", ufmt.Sprintf("%d", inst.faucet),
		"block", ufmt.Sprintf("%d", runtime.ChainHeight()),
	)
}

// ── Admin Functions ──────────────────────────────────────────

func DropInstanceOwnership(cur realm, symbol string) {
	inst := mustGetInstance(symbol)
	checkErr(inst.admin.DropOwnership(0, cur))
}

func TransferInstanceOwnership(cur realm, symbol string, newOwner address) {
	inst := mustGetInstance(symbol)
	checkErr(inst.admin.TransferOwnership(0, cur, newOwner))
}

// SetTokenMeta sets optional metadata for a token. Admin only.
// Lengths: description ≤ 280, website ≤ 128, logo ≤ 100 chars.
func SetTokenMeta(cur realm, symbol, description, website, logo string) {
	inst := mustGetInstance(symbol)
	inst.admin.AssertOwnedBy(cur.Previous().Address())

	if len(description) > 280 {
		panic("description too long (max 280 chars)")
	}
	if len(website) > 128 {
		panic("website too long (max 128 chars)")
	}
	if len(logo) > 100 {
		panic("logo URI too long (max 100 chars)")
	}

	tokenMetas.Set(symbol, &TokenMeta{
		Description: description,
		Website:     website,
		LogoIPFS:    logo,
	})

	chain.Emit(
		EventMetaUpdated,
		"symbol", symbol,
	)
}

// ── Pagination ───────────────────────────────────────────────

func ListTokens(pageNumber, pageSize int) []*grc20.Token {
	page := pager.GetPageWithSize(pageNumber, pageSize)

	tokens := make([]*grc20.Token, len(page.Items))
	for i := range page.Items {
		tokens[i] = page.Items[i].Value.(*instance).token
	}

	return tokens
}

// ── Render ───────────────────────────────────────────────────

func Render(path string) string {
	router := mux.NewRouter()
	router.HandleFunc("", renderHome)
	router.HandleFunc("{symbol}", renderToken)
	router.HandleFunc("{symbol}/balance/{address}", renderBalance)
	return router.Render(path)
}

func renderHome(res *mux.ResponseWriter, req *mux.Request) {
	out := ufmt.Sprintf("# Samcrew Token Factory (%d tokens)\n\n", instances.Size())
	bps, treasury := resolveFee()
	out += ufmt.Sprintf("*Platform fee: %d.%02d%% (token lane, DAO fee spine) → `%s`*\n\n", bps/100, bps%100, string(treasury))

	page := pager.MustGetPageByPath(req.RawPath)

	for _, item := range page.Items {
		token := item.Value.(*instance).token
		out += "- " + ufmt.Sprintf(
			"[%s ($%s)](/r/samcrew/tokenfactory_v2:%s)",
			token.GetName(), token.GetSymbol(), token.GetSymbol(),
		) + "\n"
	}
	out += "\n"
	out += page.Picker(req.Path)

	res.Write(out)
}

func renderToken(res *mux.ResponseWriter, req *mux.Request) {
	symbol := req.GetVar("symbol")
	inst := mustGetInstance(symbol)

	out := inst.token.RenderHome()
	out += ufmt.Sprintf("- **Admin**: %s\n", string(inst.admin.Owner()))

	if inst.faucet > 0 {
		out += ufmt.Sprintf("- **Faucet**: %d per claim (~24h cooldown)\n", inst.faucet)
	}

	// Show metadata if set
	if meta := GetTokenMeta(symbol); meta != nil {
		out += "\n### Metadata\n"
		if meta.Description != "" {
			out += ufmt.Sprintf("- **Description**: %s\n", meta.Description)
		}
		if meta.Website != "" {
			out += ufmt.Sprintf("- **Website**: %s\n", meta.Website)
		}
		if meta.LogoIPFS != "" {
			out += ufmt.Sprintf("- **Logo**: %s\n", meta.LogoIPFS)
		}
	}

	res.Write(out)
}

func renderBalance(res *mux.ResponseWriter, req *mux.Request) {
	symbol := req.GetVar("symbol")
	addr := req.GetVar("address")

	inst := mustGetInstance(symbol)
	// Token.BalanceOf, not CallerTeller().BalanceOf: the pearl ref moved
	// CallerTeller from *Token to *PrivateLedger (grc721/grc20 Teller-axis
	// rewrite, in p/demo/tokens/grc20 on pearl-1), and this render path only
	// READS a balance — the teller indirection carried no authority here.
	// Token.BalanceOf exists on both the sapphire and pearl refs, so this one
	// form deploys on either chain.
	balance := inst.token.BalanceOf(address(addr))

	out := ufmt.Sprintf("%s balance: %d\n", addr, balance)
	res.Write(out)
}

// ── Internal Helpers ─────────────────────────────────────────

// applyFee mints tokens to the recipient and the platform fee — resolved live
// from the DAO fee spine, in basis points — as additional supply to the
// treasury. Returns the fee amount.
func applyFee(ledger *grc20.PrivateLedger, to address, amount int64) int64 {
	bps, treasury := resolveFee()
	fee := amount * bps / 10000
	// Mint full amount to recipient
	checkErr(ledger.Mint(to, amount))
	// Mint fee as additional supply to the DAO treasury
	if fee > 0 {
		checkErr(ledger.Mint(treasury, fee))
	}
	return fee
}

func mustGetInstance(symbol string) *instance {
	t, exists := instances.Get(symbol)
	if !exists {
		panic("token instance does not exist")
	}
	return t.(*instance)
}

func checkErr(err error) {
	if err != nil {
		panic(err.Error())
	}
}

// ── Validation ───────────────────────────────────────────────

func validateSymbol(symbol string) {
	if len(symbol) < 1 || len(symbol) > 10 {
		panic("symbol must be 1-10 characters")
	}
	for _, c := range symbol {
		if !((c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9')) {
			panic("symbol must be uppercase alphanumeric (A-Z, 0-9)")
		}
	}
}

func validateName(name string) {
	if len(name) < 1 || len(name) > 64 {
		panic("name must be 1-64 characters")
	}
}

func validateDecimals(decimals int) {
	if decimals < 0 || decimals > 18 {
		panic("decimals must be 0-18")
	}
}
