package factory

// GnoPump Factory V5 - GRC20-Native Token Launchpad
// Status: Production Ready with DEX Compatibility
// Milestone: 5 (GRC20 Refactor)
// Features:
//   - Standard GRC20 tokens (Transfer, Approve, TransferFrom)
//   - Bonding curve for price discovery
//   - Automatic DEX graduation at threshold
//   - Native GnoSwap compatibility

import (
	"chain"
	"chain/banker"
	"chain/runtime"
	"chain/runtime/unsafe"
	"math"
	"math/overflow"
	"strconv"
	"strings"

	"gno.land/p/demo/tokens/grc20"
	"gno.land/p/nt/ufmt/v0"
)

// =============================================================================
// CONSTANTS
// =============================================================================

const TOKEN_DECIMALS = 6
const FEE_BPS = int64(100)       // 1% protocol fee (bonding curve + AMM)
// LP_FEE_BPS is an additional 1% charged ONLY on graduated-token AMM swaps that
// is retained in the pool (grows k), so external liquidity providers earn yield.
// Total AMM swap fee is therefore FEE_BPS + LP_FEE_BPS = 2%.
const LP_FEE_BPS = int64(100)
const CREATE_FEE = int64(1000000) // 1 GNOT
const MIN_SYMBOL_LEN = 3
const MAX_SYMBOL_LEN = 4
const MAX_NAME_LEN = 20

// Safety Limits
// BONDING-CAP-1: MAX_SUPPLY must equal SAFE_SUPPLY_LIMIT. integral() panics for
// s > SAFE_SUPPLY_LIMIT, and QuoteBuy clamps S_new to MAX_SUPPLY before calling
// integral(); if MAX_SUPPLY were larger, a buy near the cap would panic and
// brick even the read-only QuoteBuy. Keeping them equal makes the clamp the
// real, graceful cap (tokensOut -> 0 at the limit) and the integral guard a
// never-tripped overflow backstop.
const SAFE_SUPPLY_LIMIT = int64(300000000) // 300M - overflow-safe limit for integral()
const MAX_SUPPLY = SAFE_SUPPLY_LIMIT       // 300M (was 1e9; unreachable above the safe limit)
const MAX_BUY_UGNOT = int64(100000000)     // 100 GNOT
const MAX_SELL_TOKENS = int64(10000000)    // 10 Million

// Graduation Threshold (10,000 GNOT)
const GRADUATION_THRESHOLD = int64(10000000000)
const MAX_DESCRIPTION_LEN = 280
const MAX_IMAGE_URL_LEN = 256
const MAX_SOCIAL_URL_LEN = 128

// Pricing: Price(S) = S/A + B
const SLOPE_A = int64(100)
const BASE_B = int64(1)

// =============================================================================
// STATE
// =============================================================================

var protocolFeeAccumulator int64
var admin address
var pausedTokensCount int64
var factoryBanker banker.Banker
var realmAddr address
var globalPaused bool // Emergency global pause - blocks all trading

// GnoSwap integration: authorized pool addresses per token
// symbol -> pool address that can call TransferForDEX
var authorizedPools = make(map[string]address)

// Protocol token fees accumulated from DEX trades (in tokens, per symbol)
// These can be withdrawn by admin and sold
var protocolTokenFees = make(map[string]int64)

// GRC20 token storage
type tokenEntry struct {
	token  *grc20.Token
	ledger *grc20.PrivateLedger
	meta   *TokenMeta
}

var tokenRegistry = make(map[string]*tokenEntry)

// =============================================================================
// TOKEN METADATA (extended beyond GRC20)
// =============================================================================

type TokenMeta struct {
	Symbol            string
	Name              string
	Description       string
	ImageURL          string
	Creator           address
	LaunchedAt        int64
	
	// Social Links
	Twitter           string
	Telegram          string
	Discord           string
	Website           string
	
	// Fork Royalties (V2)
	ParentSymbol      string  // Empty if original, parent's symbol if forked
	OriginCreator     address // Who receives royalties (parent's creator)
	RoyaltyRateBps    int64   // 0-500 (0%-5%) share of collected platform fees
	Reserves          int64
	IsPaused          bool
	IsGraduated       bool   // Threshold reached, eligible for DEX
	GraduatedAt       int64
	IsMigrating       bool   // Temporary lock during DEX pool creation
	MigrationComplete bool   // Migration done, trading resumes on both platforms
	DEXPoolID         string // GnoSwap pool identifier (if migrated)
}

// =============================================================================
// HELPERS
// =============================================================================

func init(cur realm) {
	realmAddr = cur.Address()
	factoryBanker = banker.NewBanker(banker.BankerTypeRealmSend, cur)
	// Deployer becomes admin. unsafe.PreviousRealm() preserves the exact
	// pre-migration semantics (runtime.PreviousRealm() drop-in) for the
	// init/deploy context where no threaded `cur.Previous()` deployer
	// identity is available.
	admin = unsafe.PreviousRealm().Address()
}

func sqrt(y int64) int64 {
	if y < 0 {
		panic("negative sqrt")
	}
	if y == 0 {
		return 0
	}
	z := y
	x := y/2 + 1
	for x < z {
		z = x
		x = (y/x + x) / 2
	}
	return z
}

func integral(s int64) int64 {
	// Overflow guard: s*s can overflow at high values
	// Safe limit is 300M (s*s = 9*10^16, within int64 max ~9.2*10^18)
	if s > SAFE_SUPPLY_LIMIT {
		panic("supply exceeds safe limit for integral calculation")
	}
	term1 := (s * s) / (2 * SLOPE_A)
	term2 := BASE_B * s
	return term1 + term2
}

func spotPrice(s int64) int64 {
	return (s / SLOPE_A) + BASE_B
}

func splitTradeFee(fee int64, royaltyRateBps int64, royaltyRecipient address) (protocolFee int64, royaltyFee int64) {
	if fee < 0 {
		panic("fee cannot be negative")
	}
	if royaltyRateBps < 0 || royaltyRateBps > 500 {
		panic("invalid royalty rate")
	}

	protocolFee = fee
	if fee == 0 || royaltyRateBps == 0 || royaltyRecipient == "" {
		return protocolFee, 0
	}

	royaltyFee = (fee * royaltyRateBps) / 10000
	protocolFee = fee - royaltyFee
	if protocolFee < 0 {
		panic("protocol fee cannot be negative")
	}
	return protocolFee, royaltyFee
}

// assertDirectPayer guards every entry point that reads its ugnot payment from
// unsafe.OriginSend(). OriginSend() reports the coins attached to the *origin
// transaction*, NOT the coins actually received by this realm. If an
// intermediary sits between the user and this call (a wrapper realm called with
// --send, or a `gnokey maketx run` ephemeral realm), it can keep the coins
// while OriginSend() still reports the full amount, letting it credit reserves /
// mint tokens / receive refunds against funds the realm never received and drain
// the shared realm account. Requiring the immediate caller to be a pure EOA
// (IsUserCall, i.e. cur.Previous().PkgPath()=="") guarantees the --send coins
// landed at realmAddr, so OriginSend() == receipt. See PAY-1 in
// docs/SECURITY_AUDIT_2026-06-13.md and gno docs/resources/effective-gno.md
// "Verifying inbound Coin payments".
func assertDirectPayer(cur realm) {
	if !cur.Previous().IsUserCall() {
		panic("payment must come directly from a user account (gnokey maketx call); calls via another realm or maketx run are rejected")
	}
}

// FMT-1: delegate to ufmt instead of the previous naive strings.Replace
// formatters, which could not substitute untyped-int constants (no `case int`),
// mangled width verbs, and rendered `%%` literally. ufmt handles standard verbs
// for both int and int64 and collapses `%%` -> `%`.
func errorf(format string, args ...interface{}) error {
	return ufmt.Errorf(format, args...)
}

func sprintf(format string, args ...interface{}) string {
	return ufmt.Sprintf(format, args...)
}

// safeK computes the informational KLast = x*y, saturating at MaxInt64 instead
// of wrapping to a misleading negative value on overflow (KLAST-OVERFLOW-1).
// KLast is read only by off-chain UI and feeds no on-chain pricing/fee logic,
// so saturating here keeps swaps/liquidity ops from ever reverting on this
// purely cosmetic computation.
func safeK(x, y int64) int64 {
	k, ok := overflow.Mul64(x, y)
	if !ok {
		return math.MaxInt64
	}
	return k
}

// formatBps renders a basis-point value (0-500) as a percentage with two
// fractional digits, e.g. 500 -> "5.00%", 25 -> "0.25%". ufmt does not apply a
// width to %d, so the zero-padding of the fractional part is done explicitly.
func formatBps(bps int64) string {
	cents := bps % 100
	centsStr := strconv.Itoa(int(cents))
	if cents < 10 {
		centsStr = "0" + centsStr
	}
	return ufmt.Sprintf("%d.%s%%", bps/100, centsStr)
}

// =============================================================================
// VALIDATION
// =============================================================================

func validateSymbol(raw string) (string, error) {
	s := strings.ToUpper(strings.TrimSpace(raw))
	if len(s) < MIN_SYMBOL_LEN || len(s) > MAX_SYMBOL_LEN {
		return "", errorf("symbol must be %d-%d chars", MIN_SYMBOL_LEN, MAX_SYMBOL_LEN)
	}
	for _, r := range s {
		if !((r >= 'A' && r <= 'Z') || (r >= '0' && r <= '9')) {
			return "", errorf("symbol must be A-Z0-9 only")
		}
	}
	return s, nil
}

func validateName(raw string) (string, error) {
	n := strings.TrimSpace(raw)
	if len(n) == 0 {
		return "", errorf("name cannot be empty")
	}
	if len(n) > MAX_NAME_LEN {
		return "", errorf("name too long: max %d chars", MAX_NAME_LEN)
	}
	return n, nil
}

func validateDescription(raw string) string {
	d := strings.TrimSpace(raw)
	if len(d) > MAX_DESCRIPTION_LEN {
		return d[:MAX_DESCRIPTION_LEN]
	}
	return d
}

func validateImageURL(raw string) string {
	u := strings.TrimSpace(raw)
	if len(u) > MAX_IMAGE_URL_LEN {
		return u[:MAX_IMAGE_URL_LEN]
	}
	return u
}

func validateSocialURL(raw string) string {
	u := strings.TrimSpace(raw)
	if len(u) > MAX_SOCIAL_URL_LEN {
		return u[:MAX_SOCIAL_URL_LEN]
	}
	return u
}

func getTokenEntry(symbol string) *tokenEntry {
	entry, exists := tokenRegistry[symbol]
	if !exists {
		panic(errorf("token %s not found", symbol))
	}
	return entry
}

// =============================================================================
// LAUNCH TOKEN
// =============================================================================

func LaunchToken(cur realm, rawSymbol, rawName, rawDescription, rawImageURL, rawTwitter, rawTelegram, rawDiscord, rawWebsite string) string {
	assertDirectPayer(cur)
	caller := cur.Previous().Address()

	symbol, err := validateSymbol(rawSymbol)
	if err != nil {
		panic(err)
	}
	name, err := validateName(rawName)
	if err != nil {
		panic(err)
	}
	description := validateDescription(rawDescription)
	imageURL := validateImageURL(rawImageURL)
	twitter := validateSocialURL(rawTwitter)
	telegram := validateSocialURL(rawTelegram)
	discord := validateSocialURL(rawDiscord)
	website := validateSocialURL(rawWebsite)

	if _, exists := tokenRegistry[symbol]; exists {
		panic(errorf("symbol %s already exists", symbol))
	}

	coinSent := unsafe.OriginSend()
	amtSent := coinSent.AmountOf("ugnot")
	if amtSent < CREATE_FEE {
		panic(errorf("need %d ugnot", CREATE_FEE))
	}

	if amtSent > CREATE_FEE {
		refund := chain.Coins{chain.NewCoin("ugnot", amtSent-CREATE_FEE)}
		factoryBanker.SendCoins(realmAddr, caller, refund)
	}

	// CREATE_FEE is protocol revenue. The GNOT already sits at realmAddr, so we
	// only track it in the single protocol accumulator (counted once, after the
	// refund) so WithdrawProtocolFees drains it to the protocol wallet too.
	protocolFeeAccumulator += CREATE_FEE

	// Create GRC20 token with standard interface
	token, ledger := grc20.NewToken(0, cur, name, symbol, TOKEN_DECIMALS)

	meta := &TokenMeta{
		Symbol:      symbol,
		Name:        name,
		Description: description,
		ImageURL:    imageURL,
		Creator:     caller,
		LaunchedAt:  runtime.ChainHeight(),
		Twitter:     twitter,
		Telegram:    telegram,
		Discord:     discord,
		Website:     website,
		Reserves:    0,
		IsPaused:    false,
		IsGraduated: false,
		GraduatedAt: 0,
	}

	tokenRegistry[symbol] = &tokenEntry{
		token:  token,
		ledger: ledger,
		meta:   meta,
	}

	chain.Emit(
		"TokenLaunched",
		"symbol", symbol,
		"name", name,
		"creator", string(caller),
		"description", description,
		"image_url", imageURL,
		"twitter", twitter,
		"telegram", telegram,
		"discord", discord,
		"website", website,
	)

	return symbol
}

// =============================================================================
// LAUNCH TEMPLATE (for tokens intended to be forked)
// =============================================================================

// LaunchTemplate creates a token with a royalty rate, intended to be forked
// royaltyRateBps: 0-500 (0%-5%) of trade fees paid to creator on forks
func LaunchTemplate(cur realm, rawSymbol, rawName, rawDescription, rawImageURL, rawTwitter, rawTelegram, rawDiscord, rawWebsite string, royaltyRateBps int64) string {
	assertDirectPayer(cur)
	caller := cur.Previous().Address()

	// Validate royalty rate (max 5%)
	if royaltyRateBps < 0 || royaltyRateBps > 500 {
		panic(errorf("royalty rate must be 0-500 bps (0%%-5%%), got %d", royaltyRateBps))
	}

	symbol, err := validateSymbol(rawSymbol)
	if err != nil {
		panic(err)
	}
	name, err := validateName(rawName)
	if err != nil {
		panic(err)
	}
	description := validateDescription(rawDescription)
	imageURL := validateImageURL(rawImageURL)
	twitter := validateSocialURL(rawTwitter)
	telegram := validateSocialURL(rawTelegram)
	discord := validateSocialURL(rawDiscord)
	website := validateSocialURL(rawWebsite)

	if _, exists := tokenRegistry[symbol]; exists {
		panic(errorf("symbol %s already exists", symbol))
	}

	coinSent := unsafe.OriginSend()
	amtSent := coinSent.AmountOf("ugnot")
	if amtSent < CREATE_FEE {
		panic(errorf("need %d ugnot", CREATE_FEE))
	}

	if amtSent > CREATE_FEE {
		refund := chain.Coins{chain.NewCoin("ugnot", amtSent-CREATE_FEE)}
		factoryBanker.SendCoins(realmAddr, caller, refund)
	}

	// CREATE_FEE is protocol revenue; track it once in the protocol accumulator.
	protocolFeeAccumulator += CREATE_FEE

	// Create GRC20 token
	token, ledger := grc20.NewToken(0, cur, name, symbol, TOKEN_DECIMALS)

	meta := &TokenMeta{
		Symbol:         symbol,
		Name:           name,
		Description:    description,
		ImageURL:       imageURL,
		Creator:        caller,
		LaunchedAt:     runtime.ChainHeight(),
		Twitter:        twitter,
		Telegram:       telegram,
		Discord:        discord,
		Website:        website,
		ParentSymbol:   "",        // No parent - this IS the origin
		OriginCreator:  caller,    // Creator earns royalties on forks
		RoyaltyRateBps: royaltyRateBps,
		Reserves:       0,
		IsPaused:       false,
		IsGraduated:    false,
		GraduatedAt:    0,
	}

	tokenRegistry[symbol] = &tokenEntry{
		token:  token,
		ledger: ledger,
		meta:   meta,
	}

	chain.Emit(
		"TemplateLaunched",
		"symbol", symbol,
		"name", name,
		"creator", string(caller),
		"royalty_bps", ufmt.Sprintf("%d", royaltyRateBps),
		"twitter", twitter,
		"telegram", telegram,
		"discord", discord,
		"website", website,
	)

	return symbol
}

// =============================================================================
// FORK TOKEN (create a new token linked to a parent)
// =============================================================================

// ForkToken creates a new token that pays royalties to the parent's creator
func ForkToken(cur realm, parentSymbol, rawSymbol, rawName, rawDescription, rawImageURL, rawTwitter, rawTelegram, rawDiscord, rawWebsite string) string {
	assertDirectPayer(cur)
	caller := cur.Previous().Address()

	// Get parent token
	parentEntry, exists := tokenRegistry[parentSymbol]
	if !exists {
		panic(errorf("parent token %s not found", parentSymbol))
	}
	parentMeta := parentEntry.meta

	// Validate new token params
	symbol, err := validateSymbol(rawSymbol)
	if err != nil {
		panic(err)
	}
	name, err := validateName(rawName)
	if err != nil {
		panic(err)
	}
	description := validateDescription(rawDescription)
	imageURL := validateImageURL(rawImageURL)
	twitter := validateSocialURL(rawTwitter)
	telegram := validateSocialURL(rawTelegram)
	discord := validateSocialURL(rawDiscord)
	website := validateSocialURL(rawWebsite)

	if _, exists := tokenRegistry[symbol]; exists {
		panic(errorf("symbol %s already exists", symbol))
	}

	coinSent := unsafe.OriginSend()
	amtSent := coinSent.AmountOf("ugnot")
	if amtSent < CREATE_FEE {
		panic(errorf("need %d ugnot", CREATE_FEE))
	}

	if amtSent > CREATE_FEE {
		refund := chain.Coins{chain.NewCoin("ugnot", amtSent-CREATE_FEE)}
		factoryBanker.SendCoins(realmAddr, caller, refund)
	}

	// CREATE_FEE is protocol revenue; track it once in the protocol accumulator.
	protocolFeeAccumulator += CREATE_FEE

	// Create GRC20 token
	token, ledger := grc20.NewToken(0, cur, name, symbol, TOKEN_DECIMALS)

	// Determine origin creator (walk up the chain if parent is also a fork)
	originCreator := parentMeta.OriginCreator
	if originCreator == "" {
		originCreator = parentMeta.Creator
	}

	meta := &TokenMeta{
		Symbol:         symbol,
		Name:           name,
		Description:    description,
		ImageURL:       imageURL,
		Creator:        caller,
		LaunchedAt:     runtime.ChainHeight(),
		Twitter:        twitter,
		Telegram:       telegram,
		Discord:        discord,
		Website:        website,
		ParentSymbol:   parentSymbol,         // Link to parent
		OriginCreator:  originCreator,        // Who gets royalties
		RoyaltyRateBps: parentMeta.RoyaltyRateBps, // Inherit royalty rate
		Reserves:       0,
		IsPaused:       false,
		IsGraduated:    false,
		GraduatedAt:    0,
	}

	tokenRegistry[symbol] = &tokenEntry{
		token:  token,
		ledger: ledger,
		meta:   meta,
	}

	chain.Emit(
		"TokenForked",
		"symbol", symbol,
		"parent_symbol", parentSymbol,
		"creator", string(caller),
		"origin_creator", string(originCreator),
		"royalty_bps", ufmt.Sprintf("%d", parentMeta.RoyaltyRateBps),
		"twitter", twitter,
		"telegram", telegram,
		"discord", discord,
		"website", website,
	)

	return symbol
}

// =============================================================================
// BONDING CURVE TRADING
// =============================================================================

func QuoteBuy(symbol string, ugnotIn int64) (tokensOut int64, fee int64, ugnotChange int64) {
	if ugnotIn > MAX_BUY_UGNOT {
		panic(errorf("buy amount exceeds limit: %d > %d", ugnotIn, MAX_BUY_UGNOT))
	}

	entry := getTokenEntry(symbol)
	
	fee = (ugnotIn * FEE_BPS) / 10000
	if fee == 0 && ugnotIn > 0 {
		fee = 1
	}
	net := ugnotIn - fee

	if net <= 0 {
		return 0, fee, 0
	}

	S := entry.token.TotalSupply()
	A := SLOPE_A

	term1 := (S + A) * (S + A)
	term2 := 2 * A * net

	S_new := sqrt(term1+term2) - A

	if S_new > MAX_SUPPLY {
		S_new = MAX_SUPPLY
	}

	tokensOut = S_new - S

	if tokensOut < 0 {
		tokensOut = 0
	}

	costActual := integral(S_new) - integral(S)
	ugnotChange = net - costActual

	return tokensOut, fee, ugnotChange
}

func QuoteSell(symbol string, tokensIn int64) (ugnotOut int64, fee int64) {
	if tokensIn > MAX_SELL_TOKENS {
		panic(errorf("sell amount exceeds limit: %d > %d", tokensIn, MAX_SELL_TOKENS))
	}

	entry := getTokenEntry(symbol)

	S := entry.token.TotalSupply()
	if tokensIn > S {
		panic("cannot sell more than supply")
	}
	S_new := S - tokensIn

	grossProceeds := integral(S) - integral(S_new)

	fee = (grossProceeds * FEE_BPS) / 10000
	if fee == 0 && grossProceeds > 0 {
		fee = 1
	}

	ugnotOut = grossProceeds - fee
	return ugnotOut, fee
}

func Buy(cur realm, symbol string, minTokensOut int64) int64 {
	assertDirectPayer(cur)
	if globalPaused {
		panic("factory is globally paused")
	}
	caller := cur.Previous().Address()
	entry := getTokenEntry(symbol)

	if entry.meta.IsPaused {
		panic("token trading is paused")
	}
	if entry.meta.IsMigrating {
		panic("token migration in progress - trading temporarily paused")
	}
	if entry.meta.MigrationComplete {
		panic("token graduated to GnoSwap - trade at gnoswap.io")
	}

	coinSent := unsafe.OriginSend()
	payment := coinSent.AmountOf("ugnot")
	if payment <= 0 {
		panic("must send ugnot")
	}

	tokensAmount, fee, change := QuoteBuy(symbol, payment)

	if tokensAmount <= 0 {
		panic("payment too small to buy tokens")
	}

	if minTokensOut > 0 && tokensAmount < minTokensOut {
		panic(errorf("slippage exceeded: got %d, expected min %d", tokensAmount, minTokensOut))
	}

	supplyAfter := entry.token.TotalSupply() + tokensAmount
	if supplyAfter > MAX_SUPPLY {
		panic("supply cap exceeded")
	}

	spent := payment - fee - change
	reservesAfter := entry.meta.Reserves + spent

	if reservesAfter < 0 {
		panic("reserves would go negative")
	}

	// Mint GRC20 tokens to buyer
	if err := entry.ledger.Mint(caller, tokensAmount); err != nil {
		panic(err)
	}

	entry.meta.Reserves = reservesAfter

	// -------------------------------------------------------------------------
	// Fee Distribution: Split between protocol and royalty (if applicable)
	// -------------------------------------------------------------------------
		protocolFee, royaltyFee := splitTradeFee(fee, entry.meta.RoyaltyRateBps, entry.meta.OriginCreator)

		if royaltyFee > 0 {
			royaltyCoins := chain.Coins{chain.NewCoin("ugnot", royaltyFee)}
			factoryBanker.SendCoins(realmAddr, entry.meta.OriginCreator, royaltyCoins)
		}

	protocolFeeAccumulator += protocolFee

	if change > 0 {
		changeCoins := chain.Coins{chain.NewCoin("ugnot", change)}
		factoryBanker.SendCoins(realmAddr, caller, changeCoins)
	}

	chain.Emit(
		"Trade",
		"symbol", symbol,
		"actor", string(caller),
		"type", "buy",
		"tokens_out", strconv.Itoa(int(tokensAmount)),
		"ugnot_in", strconv.Itoa(int(payment)),
		"ugnot_spent", strconv.Itoa(int(spent)),
		"ugnot_change", strconv.Itoa(int(change)),
		"fee_protocol", strconv.Itoa(int(protocolFee)),
		"fee_royalty", strconv.Itoa(int(royaltyFee)),
		"supply_after", strconv.Itoa(int(supplyAfter)),
		"reserves_after", strconv.Itoa(int(reservesAfter)),
	)

	checkGraduation(symbol, reservesAfter)

	return tokensAmount
}

func Sell(cur realm, symbol string, amount int64, minUgnotOut int64) int64 {
	if globalPaused {
		panic("factory is globally paused")
	}
	caller := cur.Previous().Address()
	entry := getTokenEntry(symbol)

	if entry.meta.IsPaused {
		panic("token trading is paused")
	}
	if entry.meta.IsMigrating {
		panic("token migration in progress - trading temporarily paused")
	}
	if entry.meta.MigrationComplete {
		panic("token graduated to GnoSwap - trade at gnoswap.io")
	}

	balance := entry.token.BalanceOf(caller)
	if amount > balance {
		panic(errorf("insufficient balance: %d < %d", balance, amount))
	}

	supplyBefore := entry.token.TotalSupply()
	supplyAfter := supplyBefore - amount
	if supplyAfter < 0 {
		panic("supply would go negative")
	}

	ugnotOut, fee := QuoteSell(symbol, amount)

	if minUgnotOut > 0 && ugnotOut < minUgnotOut {
		panic(errorf("slippage exceeded: got %d ugnot, expected min %d", ugnotOut, minUgnotOut))
	}

	grossProceeds := ugnotOut + fee
	reservesAfter := entry.meta.Reserves - grossProceeds
	if reservesAfter < 0 {
		panic(errorf("insufficient reserves: %d < %d", entry.meta.Reserves, grossProceeds))
	}

	// Burn GRC20 tokens from seller
	if err := entry.ledger.Burn(caller, amount); err != nil {
		panic(err)
	}

	entry.meta.Reserves = reservesAfter

	// -------------------------------------------------------------------------
	// Fee Distribution: Split between protocol and royalty (if applicable)
	// -------------------------------------------------------------------------
		protocolFee, royaltyFee := splitTradeFee(fee, entry.meta.RoyaltyRateBps, entry.meta.OriginCreator)

		if royaltyFee > 0 {
			royaltyCoins := chain.Coins{chain.NewCoin("ugnot", royaltyFee)}
			factoryBanker.SendCoins(realmAddr, entry.meta.OriginCreator, royaltyCoins)
		}

	protocolFeeAccumulator += protocolFee

	if ugnotOut > 0 {
		netCoins := chain.Coins{chain.NewCoin("ugnot", ugnotOut)}
		factoryBanker.SendCoins(realmAddr, caller, netCoins)
	}

	chain.Emit(
		"Trade",
		"symbol", symbol,
		"actor", string(caller),
		"type", "sell",
		"tokens_in", strconv.Itoa(int(amount)),
		"ugnot_out", strconv.Itoa(int(ugnotOut)),
		"fee_protocol", strconv.Itoa(int(protocolFee)),
		"fee_royalty", strconv.Itoa(int(royaltyFee)),
		"supply_after", strconv.Itoa(int(supplyAfter)),
		"reserves_after", strconv.Itoa(int(reservesAfter)),
	)

	return ugnotOut
}

// =============================================================================
// GRC20 STANDARD INTERFACE
// =============================================================================

// Transfer moves tokens from caller to recipient
func Transfer(cur realm, symbol string, to address, amount int64) {
	// GRC20-TRANSFER-UNGATED: the emergency global kill-switch must also freeze
	// raw token movement, otherwise it cannot contain an in-progress incident.
	if globalPaused {
		panic("factory is globally paused")
	}
	caller := cur.Previous().Address()
	entry := getTokenEntry(symbol)

	if err := entry.ledger.Transfer(caller, to, amount); err != nil {
		panic(err)
	}
}

// Approve sets allowance for spender to spend caller's tokens
func Approve(cur realm, symbol string, spender address, amount int64) {
	if globalPaused {
		panic("factory is globally paused")
	}
	caller := cur.Previous().Address()
	entry := getTokenEntry(symbol)

	if err := entry.ledger.Approve(caller, spender, amount); err != nil {
		panic(err)
	}
}

// TransferFrom moves tokens using allowance mechanism
func TransferFrom(cur realm, symbol string, from address, to address, amount int64) {
	if globalPaused {
		panic("factory is globally paused")
	}
	caller := cur.Previous().Address()
	entry := getTokenEntry(symbol)

	if err := entry.ledger.TransferFrom(from, caller, to, amount); err != nil {
		panic(err)
	}
}

// Allowance returns the remaining allowance
func Allowance(symbol string, owner address, spender address) int64 {
	entry := getTokenEntry(symbol)
	return entry.token.Allowance(owner, spender)
}

// =============================================================================
// GRADUATION & MIGRATION (DEX INTEGRATION)
// =============================================================================

// checkGraduation marks token as graduated when threshold reached
// Trading continues until admin initiates migration
func checkGraduation(symbol string, reserves int64) {
	if reserves >= GRADUATION_THRESHOLD {
		entry := getTokenEntry(symbol)
		if entry.meta.IsGraduated {
			return
		}

		entry.meta.IsGraduated = true
		entry.meta.GraduatedAt = runtime.ChainHeight()

		chain.Emit(
			"TokenGraduated",
			"symbol", symbol,
			"reserves", strconv.Itoa(int(reserves)),
			"total_supply", strconv.Itoa(int(entry.token.TotalSupply())),
			"block_height", strconv.Itoa(int(entry.meta.GraduatedAt)),
		)
	}
}

// StartMigration temporarily locks trading while DEX pool is created
// This matches pump.fun's model - short pause during liquidity migration
func StartMigration(cur realm, symbol string) {
	caller := cur.Previous().Address()
	if caller != admin {
		panic("unauthorized: only admin can start migration")
	}

	entry := getTokenEntry(symbol)
	
	if !entry.meta.IsGraduated {
		panic("token must graduate before migration")
	}
	if entry.meta.IsMigrating {
		panic("migration already in progress")
	}
	if entry.meta.MigrationComplete {
		panic("token already migrated")
	}

	entry.meta.IsMigrating = true

	chain.Emit(
		"MigrationStarted",
		"symbol", symbol,
		"reserves", strconv.Itoa(int(entry.meta.Reserves)),
		"total_supply", strconv.Itoa(int(entry.token.TotalSupply())),
	)
}

// CompleteMigration unlocks trading after DEX pool is live
// Trading resumes on both GnoPump and GnoSwap (like pump.fun + Raydium)
func CompleteMigration(cur realm, symbol string, dexPoolID string) {
	caller := cur.Previous().Address()
	if caller != admin {
		panic("unauthorized: only admin can complete migration")
	}

	entry := getTokenEntry(symbol)
	
	if !entry.meta.IsMigrating {
		panic("migration not in progress")
	}

	// ACCT-MIGRATE-1: MigrationComplete is a one-way flag that permanently
	// disables bonding-curve Buy/Sell. Refuse to finalize into a dead state:
	// require a live venue for holders - either an internal AMM pool, or a
	// registered external DEX pool with reserves already moved out (so nothing
	// is stranded in the realm with no exit).
	pool := ammPools[symbol]
	hasInternalPool := pool != nil && pool.Active
	hasExternalPool := authorizedPools[symbol] != "" && entry.meta.Reserves == 0
	if !hasInternalPool && !hasExternalPool {
		panic("cannot complete migration: first register a DEX pool and withdraw reserves to it (WithdrawReservesToPool), or initialize the internal AMM pool")
	}

	entry.meta.IsMigrating = false
	entry.meta.MigrationComplete = true
	entry.meta.DEXPoolID = dexPoolID

	chain.Emit(
		"MigrationComplete",
		"symbol", symbol,
		"dex_pool_id", dexPoolID,
		"reserves_migrated", strconv.Itoa(int(entry.meta.Reserves)),
	)
}

// GetMigrationStatus returns current migration state for a token
func GetMigrationStatus(symbol string) (graduated bool, migrating bool, complete bool, poolID string) {
	entry := getTokenEntry(symbol)
	return entry.meta.IsGraduated, entry.meta.IsMigrating, entry.meta.MigrationComplete, entry.meta.DEXPoolID
}

// =============================================================================
// GNOSWAP DEX INTEGRATION
// =============================================================================

// RegisterDEXPool authorizes a GnoSwap pool address to transfer tokens
// This is called after pool creation on GnoSwap side
func RegisterDEXPool(cur realm, symbol string, poolAddr address) {
	caller := cur.Previous().Address()
	if caller != admin {
		panic("unauthorized: only admin can register DEX pools")
	}

	entry := getTokenEntry(symbol)
	
	if !entry.meta.IsGraduated {
		panic("token must graduate before DEX registration")
	}

	authorizedPools[symbol] = poolAddr

	chain.Emit(
		"DEXPoolRegistered",
		"symbol", symbol,
		"pool_address", string(poolAddr),
	)
}

// TransferForDEX allows authorized GnoSwap pools to transfer tokens during swaps
// GnoSwap calls this instead of requiring user approvals
// 
// Fee Structure (taken from transfer amount, in tokens):
//   - Protocol Fee: 1% (100 bps) → accumulated for protocol
//   - Royalty Fee:  0-5% → paid to parent creator (if forked token)
//   - Net Amount:   remainder → sent to recipient
//
func TransferForDEX(cur realm, symbol string, from address, to address, amount int64) int64 {
	// =========================================================================
	// 1. AUTHORIZATION
	// =========================================================================
	caller := cur.Previous().Address()
	
	authorizedPool, exists := authorizedPools[symbol]
	if !exists {
		panic(errorf("no DEX pool registered for %s", symbol))
	}
	if caller != authorizedPool {
		panic(errorf("unauthorized: caller %s is not registered pool", string(caller)))
	}

	entry := getTokenEntry(symbol)
	if !entry.meta.MigrationComplete {
		panic("token not yet migrated to DEX")
	}

	// =========================================================================
	// 2. CALCULATE FEES
	// =========================================================================
	protocolFee := (amount * FEE_BPS) / 10000 // 1% protocol fee
	if protocolFee == 0 && amount > 0 {
		protocolFee = 1 // minimum 1 token fee
	}

	royaltyFee := int64(0)
	if entry.meta.RoyaltyRateBps > 0 && entry.meta.OriginCreator != "" {
		royaltyFee = (amount * entry.meta.RoyaltyRateBps) / 10000
	}

	totalFees := protocolFee + royaltyFee
	netAmount := amount - totalFees

	if netAmount <= 0 {
		panic("transfer amount too small after fees")
	}

	// =========================================================================
	// 3. COLLECT FEES (in tokens)
	// =========================================================================
	
	// Protocol fee: accumulate in factory (can withdraw later).
	// Skip when 'from' is already the factory: grc20.Transfer panics on a
	// self-transfer (ErrCannotTransferToSelf), and counting a fee against the
	// factory's own tokens would break the
	// BalanceOf(realmAddr) == pool.TokenReserve + protocolTokenFees invariant.
	if protocolFee > 0 && from != realmAddr {
		protocolTokenFees[symbol] += protocolFee
		// Tokens stay with 'from' but are earmarked; actually transfer to factory
		if err := entry.ledger.Transfer(from, realmAddr, protocolFee); err != nil {
			panic(err)
		}
	}

	// Royalty fee: send directly to parent creator.
	// ROYALTY-SELF-1: when the seller IS the royalty recipient, the royalty is
	// already in their account; a self-transfer would panic and brick the swap,
	// so skip it (the recipient keeps the royaltyFee).
	if royaltyFee > 0 && entry.meta.OriginCreator != "" && from != entry.meta.OriginCreator {
		if err := entry.ledger.Transfer(from, entry.meta.OriginCreator, royaltyFee); err != nil {
			panic(err)
		}
	}

	// =========================================================================
	// 4. EXECUTE MAIN TRANSFER
	// =========================================================================
	// Skip a degenerate self-transfer (would panic ErrCannotTransferToSelf);
	// netAmount is already in 'from' == 'to'.
	if to != from {
		if err := entry.ledger.Transfer(from, to, netAmount); err != nil {
			panic(err)
		}
	}

	// =========================================================================
	// 5. EMIT EVENT
	// =========================================================================
	chain.Emit(
		"DEXTransfer",
		"symbol", symbol,
		"from", string(from),
		"to", string(to),
		"amount_gross", strconv.Itoa(int(amount)),
		"amount_net", strconv.Itoa(int(netAmount)),
		"fee_protocol", strconv.Itoa(int(protocolFee)),
		"fee_royalty", strconv.Itoa(int(royaltyFee)),
		"royalty_recipient", string(entry.meta.OriginCreator),
	)

	return netAmount
}

// WithdrawReservesToPool sends GNOT reserves to GnoSwap pool for liquidity
// Called during migration process to seed the AMM pool
func WithdrawReservesToPool(cur realm, symbol string, poolAddr address) int64 {
	caller := cur.Previous().Address()
	if caller != admin {
		panic("unauthorized: only admin can withdraw reserves to pool")
	}

	entry := getTokenEntry(symbol)

	if !entry.meta.IsMigrating {
		panic("can only withdraw during migration")
	}

	// ADMIN-1: the destination must be the DEX pool previously registered via
	// RegisterDEXPool (itself admin-gated and event-logged), not an arbitrary
	// admin-supplied address. This removes the silent "drain reserves to any
	// address" capability and ties the withdrawal to a publicly auditable pool.
	registeredPool, exists := authorizedPools[symbol]
	if !exists || registeredPool == "" {
		panic("no DEX pool registered: call RegisterDEXPool with the destination pool first")
	}
	if poolAddr != registeredPool {
		panic("destination must equal the registered DEX pool address")
	}

	reserves := entry.meta.Reserves
	if reserves <= 0 {
		return 0
	}

	// Send GNOT reserves to the registered pool
	coins := chain.Coins{chain.NewCoin("ugnot", reserves)}
	factoryBanker.SendCoins(realmAddr, poolAddr, coins)

	// Clear reserves (now in pool)
	entry.meta.Reserves = 0

	chain.Emit(
		"ReservesWithdrawn",
		"symbol", symbol,
		"amount", strconv.Itoa(int(reserves)),
		"to_pool", string(poolAddr),
	)

	return reserves
}

// GetAuthorizedPool returns the registered DEX pool for a token
func GetAuthorizedPool(symbol string) address {
	pool, exists := authorizedPools[symbol]
	if !exists {
		return address("")
	}
	return pool
}

// GetDEXInfo returns all info GnoSwap needs to work with a token
func GetDEXInfo(symbol string) (supply int64, decimals int, poolAddr address, migrated bool) {
	entry := getTokenEntry(symbol)
	pool, _ := authorizedPools[symbol]
	return entry.token.TotalSupply(), TOKEN_DECIMALS, pool, entry.meta.MigrationComplete
}

// GetProtocolTokenFees returns accumulated token fees from DEX trades
func GetProtocolTokenFees(symbol string) int64 {
	return protocolTokenFees[symbol]
}

// WithdrawProtocolTokenFees lets admin withdraw accumulated token fees
// Tokens are transferred to specified address (admin can sell them)
func WithdrawProtocolTokenFees(cur realm, symbol string, to address) int64 {
	caller := cur.Previous().Address()
	if caller != admin {
		panic("unauthorized: only admin can withdraw token fees")
	}

	amount := protocolTokenFees[symbol]
	if amount <= 0 {
		return 0
	}

	entry := getTokenEntry(symbol)
	
	// Transfer tokens from factory to recipient
	if err := entry.ledger.Transfer(realmAddr, to, amount); err != nil {
		panic(err)
	}

	protocolTokenFees[symbol] = 0

	chain.Emit(
		"TokenFeesWithdrawn",
		"symbol", symbol,
		"to", string(to),
		"amount", strconv.Itoa(int(amount)),
	)

	return amount
}

// =============================================================================
// INTERNAL AMM POOL FOR GRADUATED TOKENS
// =============================================================================
// After graduation, tokens trade via constant-product AMM (x*y=k)
// This is similar to Uniswap V2 - simple but effective
// GnoSwap integration can still happen via TransferForDEX if they call our pool

// Pool state for graduated tokens
type AMMPool struct {
	TokenReserve int64  // Token reserve in pool
	GNOTReserve  int64  // GNOT reserve in pool
	KLast        int64  // k = token * gnot (for fee calculation)
	TotalLP      int64  // Total LP tokens issued
	Active       bool   // Is pool active for trading
}

// LP token balances per user per pool
var lpBalances = make(map[string]map[address]int64) // symbol -> address -> LP amount
var ammPools = make(map[string]*AMMPool)            // symbol -> pool

// InitializeAMMPool creates the AMM pool during migration
// Called by admin after graduation to seed liquidity
func InitializeAMMPool(cur realm, symbol string, tokenAmount int64) {
	caller := cur.Previous().Address()
	if caller != admin {
		panic("unauthorized: only admin can initialize pool")
	}

	entry := getTokenEntry(symbol)
	if !entry.meta.IsMigrating {
		panic("can only initialize pool during migration")
	}

	gnotReserve := entry.meta.Reserves
	if gnotReserve <= 0 {
		panic("no GNOT reserves to seed pool")
	}

	// INITAMM-NO-SUPPLY-CHECK: the seed amount is admin-chosen and was minted
	// with no bound. Require a positive amount and keep total supply within the
	// curve's MAX_SUPPLY cap so the AMM seed cannot mint past the advertised
	// supply ceiling.
	if tokenAmount <= 0 {
		panic("pool seed token amount must be positive")
	}
	if entry.token.TotalSupply()+tokenAmount > MAX_SUPPLY {
		panic("pool seed would exceed MAX_SUPPLY")
	}

	// Mint tokens for pool liquidity (protocol-owned liquidity)
	if err := entry.ledger.Mint(realmAddr, tokenAmount); err != nil {
		panic(err)
	}

	// Create pool
	k := safeK(tokenAmount, gnotReserve)
	ammPools[symbol] = &AMMPool{
		TokenReserve: tokenAmount,
		GNOTReserve:  gnotReserve,
		KLast:        k,
		TotalLP:      gnotReserve, // Initial LP = GNOT amount
		Active:       true,
	}

	// Initialize LP balance map
	lpBalances[symbol] = make(map[address]int64)
	// Protocol owns initial LP (can burn or keep for fee collection)
	lpBalances[symbol][realmAddr] = gnotReserve

	// Clear reserves (now in pool)
	entry.meta.Reserves = 0
	entry.meta.MigrationComplete = true
	entry.meta.IsMigrating = false
	entry.meta.DEXPoolID = "gnopump-amm-" + symbol

	chain.Emit(
		"AMMPoolCreated",
		"symbol", symbol,
		"token_reserve", strconv.Itoa(int(tokenAmount)),
		"gnot_reserve", strconv.Itoa(int(gnotReserve)),
		"initial_k", strconv.Itoa(int(k)),
	)
}

// SwapGNOTForToken buys tokens from the AMM pool
// Constant product: (x + dx)(y - dy) = k
// dy = y * dx / (x + dx)
func SwapGNOTForToken(cur realm, symbol string, minTokensOut int64) int64 {
	assertDirectPayer(cur)
	if globalPaused {
		panic("factory is globally paused")
	}
	caller := cur.Previous().Address()
	entry := getTokenEntry(symbol)

	// Check if trading on bonding curve or AMM
	if !entry.meta.MigrationComplete {
		panic("token not graduated - use Buy() for bonding curve")
	}

	pool := ammPools[symbol]
	if pool == nil || !pool.Active {
		panic("AMM pool not active for this token")
	}

	coinSent := unsafe.OriginSend()
	ugnotIn := coinSent.AmountOf("ugnot")
	if ugnotIn <= 0 {
		panic("must send GNOT to swap")
	}

	// AMM fee = 2%: 1% protocol (FEE_BPS, withdrawable / royalty-split) + 1% LP
	// (LP_FEE_BPS, retained in the pool so liquidity providers earn yield).
	protoFee := (ugnotIn * FEE_BPS) / 10000
	if protoFee == 0 && ugnotIn > 0 {
		protoFee = 1
	}
	lpFee := (ugnotIn * LP_FEE_BPS) / 10000

	// Amount actually swapped against the curve (input minus both fees).
	amountForPricing := ugnotIn - protoFee - lpFee
	if amountForPricing <= 0 {
		panic("swap amount too small")
	}

	// Calculate tokens out using constant product formula
	// dy = y * dx / (x + dx + 1) -- +1 to prevent rounding exploits
	tokensOut := (pool.TokenReserve * amountForPricing) / (pool.GNOTReserve + amountForPricing + 1)

	if tokensOut <= 0 {
		panic("swap amount too small")
	}
	if tokensOut < minTokensOut {
		panic(errorf("slippage exceeded: got %d, expected min %d", tokensOut, minTokensOut))
	}
	if tokensOut >= pool.TokenReserve {
		panic("insufficient liquidity")
	}

		// Split the protocol fee between protocol and royalty
		protocolFee, royaltyFee := splitTradeFee(protoFee, entry.meta.RoyaltyRateBps, entry.meta.OriginCreator)

		if royaltyFee > 0 {
			royaltyCoins := chain.Coins{chain.NewCoin("ugnot", royaltyFee)}
			factoryBanker.SendCoins(realmAddr, entry.meta.OriginCreator, royaltyCoins)
		}
	protocolFeeAccumulator += protocolFee

	// Update pool state. The pool keeps everything except the protocol fee
	// (which leaves as accumulator + royalty): the LP fee thus stays in the
	// pool, raising k for liquidity providers.
	pool.GNOTReserve += ugnotIn - protoFee
	pool.TokenReserve -= tokensOut
	pool.KLast = safeK(pool.GNOTReserve, pool.TokenReserve)

	// Transfer tokens to buyer
	if err := entry.ledger.Transfer(realmAddr, caller, tokensOut); err != nil {
		panic(err)
	}

	chain.Emit(
		"AMMSwap",
		"symbol", symbol,
		"type", "buy",
		"actor", string(caller),
		"gnot_in", strconv.Itoa(int(ugnotIn)),
		"tokens_out", strconv.Itoa(int(tokensOut)),
		"fee_protocol", strconv.Itoa(int(protocolFee)),
		"fee_royalty", strconv.Itoa(int(royaltyFee)),
		"new_token_reserve", strconv.Itoa(int(pool.TokenReserve)),
		"new_gnot_reserve", strconv.Itoa(int(pool.GNOTReserve)),
	)

	return tokensOut
}

// SwapTokenForGNOT sells tokens to the AMM pool for GNOT
func SwapTokenForGNOT(cur realm, symbol string, tokenAmount int64, minGNOTOut int64) int64 {
	if globalPaused {
		panic("factory is globally paused")
	}
	caller := cur.Previous().Address()
	entry := getTokenEntry(symbol)

	if !entry.meta.MigrationComplete {
		panic("token not graduated - use Sell() for bonding curve")
	}

	pool := ammPools[symbol]
	if pool == nil || !pool.Active {
		panic("AMM pool not active for this token")
	}

	if tokenAmount <= 0 {
		panic("must sell positive amount")
	}

	balance := entry.token.BalanceOf(caller)
	if tokenAmount > balance {
		panic(errorf("insufficient balance: %d < %d", balance, tokenAmount))
	}

	// Calculate GNOT out using constant product formula
	// dx = x * dy / (y + dy + 1)
	gnotOut := (pool.GNOTReserve * tokenAmount) / (pool.TokenReserve + tokenAmount + 1)

	if gnotOut <= 0 {
		panic("swap amount too small")
	}

	// AMM fee = 2%: 1% protocol (FEE_BPS) + 1% LP (LP_FEE_BPS, retained in pool).
	protoFee := (gnotOut * FEE_BPS) / 10000
	if protoFee == 0 && gnotOut > 0 {
		protoFee = 1
	}
	lpFee := (gnotOut * LP_FEE_BPS) / 10000
	netGNOTOut := gnotOut - protoFee - lpFee
	if netGNOTOut <= 0 {
		panic("swap amount too small")
	}

	if netGNOTOut < minGNOTOut {
		panic(errorf("slippage exceeded: got %d, expected min %d", netGNOTOut, minGNOTOut))
	}
	if gnotOut >= pool.GNOTReserve {
		panic("insufficient liquidity")
	}

		// Split the protocol fee between protocol and royalty
		protocolFee, royaltyFee := splitTradeFee(protoFee, entry.meta.RoyaltyRateBps, entry.meta.OriginCreator)

		if royaltyFee > 0 {
			royaltyCoins := chain.Coins{chain.NewCoin("ugnot", royaltyFee)}
			factoryBanker.SendCoins(realmAddr, entry.meta.OriginCreator, royaltyCoins)
		}
	protocolFeeAccumulator += protocolFee

	// Transfer tokens from seller to pool
	if err := entry.ledger.Transfer(caller, realmAddr, tokenAmount); err != nil {
		panic(err)
	}

	// Update pool state. The pool pays out only (gnotOut - lpFee), so the LP fee
	// stays in the pool, raising k for liquidity providers.
	pool.TokenReserve += tokenAmount
	pool.GNOTReserve -= gnotOut - lpFee
	pool.KLast = safeK(pool.GNOTReserve, pool.TokenReserve)

	// Send GNOT to seller
	if netGNOTOut > 0 {
		netCoins := chain.Coins{chain.NewCoin("ugnot", netGNOTOut)}
		factoryBanker.SendCoins(realmAddr, caller, netCoins)
	}

	chain.Emit(
		"AMMSwap",
		"symbol", symbol,
		"type", "sell",
		"actor", string(caller),
		"tokens_in", strconv.Itoa(int(tokenAmount)),
		"gnot_out", strconv.Itoa(int(netGNOTOut)),
		"fee_protocol", strconv.Itoa(int(protocolFee)),
		"fee_royalty", strconv.Itoa(int(royaltyFee)),
		"new_token_reserve", strconv.Itoa(int(pool.TokenReserve)),
		"new_gnot_reserve", strconv.Itoa(int(pool.GNOTReserve)),
	)

	return netGNOTOut
}

// QuoteAMMBuy returns expected tokens out for GNOT in
// fee is the TOTAL swap fee (protocol 1% + LP 1% = 2%), matching SwapGNOTForToken.
func QuoteAMMBuy(symbol string, ugnotIn int64) (tokensOut int64, fee int64) {
	pool := ammPools[symbol]
	if pool == nil || !pool.Active {
		return 0, 0
	}

	protoFee := (ugnotIn * FEE_BPS) / 10000
	if protoFee == 0 && ugnotIn > 0 {
		protoFee = 1
	}
	lpFee := (ugnotIn * LP_FEE_BPS) / 10000
	fee = protoFee + lpFee

	amountForPricing := ugnotIn - fee
	if amountForPricing <= 0 {
		return 0, fee
	}
	tokensOut = (pool.TokenReserve * amountForPricing) / (pool.GNOTReserve + amountForPricing + 1)
	return tokensOut, fee
}

// QuoteAMMSell returns expected GNOT out for tokens in.
// fee is the TOTAL swap fee (protocol 1% + LP 1% = 2%), matching SwapTokenForGNOT.
func QuoteAMMSell(symbol string, tokenAmount int64) (gnotOut int64, fee int64) {
	pool := ammPools[symbol]
	if pool == nil || !pool.Active {
		return 0, 0
	}

	grossOut := (pool.GNOTReserve * tokenAmount) / (pool.TokenReserve + tokenAmount + 1)
	protoFee := (grossOut * FEE_BPS) / 10000
	if protoFee == 0 && grossOut > 0 {
		protoFee = 1
	}
	lpFee := (grossOut * LP_FEE_BPS) / 10000
	fee = protoFee + lpFee
	gnotOut = grossOut - fee
	return gnotOut, fee
}

// GetAMMPoolInfo returns pool state for a graduated token
func GetAMMPoolInfo(symbol string) (tokenReserve int64, gnotReserve int64, k int64, totalLP int64, active bool) {
	pool := ammPools[symbol]
	if pool == nil {
		return 0, 0, 0, 0, false
	}
	return pool.TokenReserve, pool.GNOTReserve, pool.KLast, pool.TotalLP, pool.Active
}

// GetAMMPrice returns current price from pool (GNOT per token, scaled by 1e6)
func GetAMMPrice(symbol string) int64 {
	pool := ammPools[symbol]
	if pool == nil || pool.TokenReserve == 0 {
		return 0
	}
	// Price = GNOT / Tokens, scaled by 1e6 for precision
	return (pool.GNOTReserve * 1000000) / pool.TokenReserve
}

// =============================================================================
// LP TOKEN MANAGEMENT (for users to add/remove liquidity)
// =============================================================================

// AddLiquidity lets users add liquidity to graduated token pools
// They send GNOT and equivalent tokens get pulled from their balance.
// minLpOut is the caller's slippage bound (0 = no bound): the call reverts if
// fewer LP tokens than minLpOut would be minted.
func AddLiquidity(cur realm, symbol string, tokenAmount int64, minLpOut int64) int64 {
	assertDirectPayer(cur)
	if globalPaused {
		panic("factory is globally paused")
	}
	caller := cur.Previous().Address()
	entry := getTokenEntry(symbol)

	pool := ammPools[symbol]
	if pool == nil || !pool.Active {
		panic("AMM pool not active")
	}

	coinSent := unsafe.OriginSend()
	gnotAmount := coinSent.AmountOf("ugnot")
	if gnotAmount <= 0 {
		panic("must send GNOT")
	}

	// Check user has enough tokens
	balance := entry.token.BalanceOf(caller)
	if tokenAmount > balance {
		panic(errorf("insufficient token balance: %d < %d", balance, tokenAmount))
	}

	// Calculate expected ratio
	expectedTokens := (gnotAmount * pool.TokenReserve) / pool.GNOTReserve
	if tokenAmount < expectedTokens {
		panic(errorf("insufficient tokens for ratio: need %d, got %d", expectedTokens, tokenAmount))
	}

	// Use exact amounts based on GNOT sent
	actualTokens := expectedTokens

	// Calculate LP tokens to mint (proportional to GNOT added)
	lpTokens := (gnotAmount * pool.TotalLP) / pool.GNOTReserve

	// ADDLIQ-NO-GNOT-REFUND-ZERO-LP: reject dust adds that would credit 0 LP or
	// pull 0 tokens for nonzero GNOT - otherwise the GNOT is kept by the pool
	// with nothing (or an unbacked LP balance) returned to the provider.
	if lpTokens <= 0 || actualTokens <= 0 {
		panic("liquidity amount too small: would mint zero LP")
	}
	// AMM-ADDLIQ-SLIP-1: enforce the caller's slippage bound on minted LP.
	if minLpOut > 0 && lpTokens < minLpOut {
		panic(errorf("slippage exceeded: LP out %d < min %d", lpTokens, minLpOut))
	}

	// Transfer tokens from user to pool
	if err := entry.ledger.Transfer(caller, realmAddr, actualTokens); err != nil {
		panic(err)
	}

	// Update pool state
	pool.TokenReserve += actualTokens
	pool.GNOTReserve += gnotAmount
	pool.TotalLP += lpTokens
	pool.KLast = safeK(pool.TokenReserve, pool.GNOTReserve)

	// Credit LP tokens to user
	if lpBalances[symbol] == nil {
		lpBalances[symbol] = make(map[address]int64)
	}
	lpBalances[symbol][caller] += lpTokens

	// Refund excess tokens if any
	if tokenAmount > actualTokens {
		// User sent too many tokens - we only transferred actualTokens
		// No refund needed since we only transferred what we need
	}

	chain.Emit(
		"LiquidityAdded",
		"symbol", symbol,
		"provider", string(caller),
		"gnot_added", strconv.Itoa(int(gnotAmount)),
		"tokens_added", strconv.Itoa(int(actualTokens)),
		"lp_minted", strconv.Itoa(int(lpTokens)),
	)

	return lpTokens
}

// RemoveLiquidity lets LP holders withdraw their share
func RemoveLiquidity(cur realm, symbol string, lpAmount int64) (tokensOut int64, gnotOut int64) {
	if globalPaused {
		panic("factory is globally paused")
	}
	caller := cur.Previous().Address()
	entry := getTokenEntry(symbol)

	pool := ammPools[symbol]
	if pool == nil {
		panic("pool not found")
	}

	userLP := lpBalances[symbol][caller]
	if lpAmount > userLP {
		panic(errorf("insufficient LP tokens: %d < %d", userLP, lpAmount))
	}

	// Calculate share of pool
	tokensOut = (lpAmount * pool.TokenReserve) / pool.TotalLP
	gnotOut = (lpAmount * pool.GNOTReserve) / pool.TotalLP

	if tokensOut <= 0 || gnotOut <= 0 {
		panic("withdrawal too small")
	}

	// Update pool state
	pool.TokenReserve -= tokensOut
	pool.GNOTReserve -= gnotOut
	pool.TotalLP -= lpAmount
	if pool.TokenReserve > 0 && pool.GNOTReserve > 0 {
		pool.KLast = safeK(pool.TokenReserve, pool.GNOTReserve)
	}

	// Burn LP tokens
	lpBalances[symbol][caller] -= lpAmount

	// Transfer tokens to user
	if err := entry.ledger.Transfer(realmAddr, caller, tokensOut); err != nil {
		panic(err)
	}

	// Send GNOT to user
	if gnotOut > 0 {
		gnotCoins := chain.Coins{chain.NewCoin("ugnot", gnotOut)}
		factoryBanker.SendCoins(realmAddr, caller, gnotCoins)
	}

	chain.Emit(
		"LiquidityRemoved",
		"symbol", symbol,
		"provider", string(caller),
		"gnot_withdrawn", strconv.Itoa(int(gnotOut)),
		"tokens_withdrawn", strconv.Itoa(int(tokensOut)),
		"lp_burned", strconv.Itoa(int(lpAmount)),
	)

	return tokensOut, gnotOut
}

// GetLPBalance returns user's LP token balance
func GetLPBalance(symbol string, user address) int64 {
	if lpBalances[symbol] == nil {
		return 0
	}
	return lpBalances[symbol][user]
}

// =============================================================================
// UNIFIED TRADE HELPERS - Query functions to help UI route correctly
// =============================================================================

// GetTradeRoute tells the UI which function to call for a given token
// Returns: "bonding" for Buy/Sell, "amm" for SwapGNOTForToken/SwapTokenForGNOT
func GetTradeRoute(symbol string) string {
	entry := getTokenEntry(symbol)
	if entry.meta.MigrationComplete {
		return "amm"
	}
	return "bonding"
}

// QuoteTrade returns expected output regardless of which route will be used
func QuoteTrade(symbol string, isBuy bool, amountIn int64) (amountOut int64, fee int64, route string) {
	entry := getTokenEntry(symbol)

	if entry.meta.MigrationComplete {
		if isBuy {
			out, f := QuoteAMMBuy(symbol, amountIn)
			return out, f, "amm"
		} else {
			out, f := QuoteAMMSell(symbol, amountIn)
			return out, f, "amm"
		}
	} else {
		if isBuy {
			out, f, _ := QuoteBuy(symbol, amountIn)
			return out, f, "bonding"
		} else {
			out, f := QuoteSell(symbol, amountIn)
			return out, f, "bonding"
		}
	}
}

// =============================================================================
// GNOSWAP EXTERNAL INTEGRATION (for external DEX compatibility)
// =============================================================================

// GnoSwap router realm address (configure for mainnet/testnet)
var gnoswapRouterAddr = address("g1gnoswap_router_placeholder") // TODO: Set real address

// SetGnoSwapRouter allows admin to configure the GnoSwap router address
func SetGnoSwapRouter(cur realm, routerAddr address) {
	caller := cur.Previous().Address()
	if caller != admin {
		panic("unauthorized: only admin can set router")
	}
	gnoswapRouterAddr = routerAddr

	chain.Emit(
		"GnoSwapRouterSet",
		"router", string(routerAddr),
	)
}

// GetGnoSwapRouter returns the configured GnoSwap router address
func GetGnoSwapRouter() address {
	return gnoswapRouterAddr
}

// GetGnoSwapPoolInfo returns info about our pool for external DEX compatibility
func GetGnoSwapPoolInfo(symbol string) (poolAddr address, migrated bool, tokenReserve int64, gnotReserve int64) {
	entry := getTokenEntry(symbol)
	pool := ammPools[symbol]
	
	externalPool := authorizedPools[symbol]
	if pool != nil {
		return externalPool, entry.meta.MigrationComplete, pool.TokenReserve, pool.GNOTReserve
	}
	return externalPool, entry.meta.MigrationComplete, 0, 0
}

// =============================================================================
// ADMIN FUNCTIONS
// =============================================================================

func WithdrawProtocolFees(cur realm, to address) {
	if cur.Previous().Address() != admin {
		panic("unauthorized: only admin can withdraw fees")
	}

	amount := protocolFeeAccumulator
	if amount <= 0 {
		return
	}

	coins := chain.Coins{chain.NewCoin("ugnot", amount)}
	protocolFeeAccumulator = 0
	factoryBanker.SendCoins(realmAddr, to, coins)

	chain.Emit("ProtocolFeeWithdrawn", "to", string(to), "amount", strconv.Itoa(int(amount)))
}

// GlobalPause halts all trading on the factory (emergency use only)
func GlobalPause(cur realm) {
	if cur.Previous().Address() != admin {
		panic("unauthorized: only admin can global pause")
	}
	if globalPaused {
		return // Already paused
	}
	globalPaused = true
	chain.Emit("GlobalPaused", "admin", string(admin))
}

// GlobalUnpause resumes trading on the factory
func GlobalUnpause(cur realm) {
	if cur.Previous().Address() != admin {
		panic("unauthorized: only admin can global unpause")
	}
	if !globalPaused {
		return // Not paused
	}
	globalPaused = false
	chain.Emit("GlobalUnpaused", "admin", string(admin))
}

// IsGlobalPaused returns the global pause state
func IsGlobalPaused() bool {
	return globalPaused
}

func PauseToken(cur realm, symbol string) {
	entry := getTokenEntry(symbol)

	caller := cur.Previous().Address()
	if caller != entry.meta.Creator {
		panic("unauthorized: only token creator can pause")
	}

	if !entry.meta.IsPaused {
		entry.meta.IsPaused = true
		pausedTokensCount++
		chain.Emit("TokenPaused", "symbol", symbol)
	}
}

func UnpauseToken(cur realm, symbol string) {
	entry := getTokenEntry(symbol)

	// CREATOR-PAUSE-1: the admin is an emergency circuit-breaker that can
	// force-unpause a token. Without this, a creator could PauseToken and
	// indefinitely block the sole pre-graduation redemption path (Sell),
	// stranding all holders with no recourse. Pausing stays creator-only;
	// only un-pausing gains the admin override.
	caller := cur.Previous().Address()
	if caller != entry.meta.Creator && caller != admin {
		panic("unauthorized: only token creator or factory admin can unpause")
	}

	if entry.meta.IsPaused {
		entry.meta.IsPaused = false
		pausedTokensCount--
		emitter := "creator"
		if caller == admin {
			emitter = "admin"
		}
		chain.Emit("TokenUnpaused", "symbol", symbol, "by", emitter)
	}
}

// =============================================================================
// READ-ONLY QUERIES
// =============================================================================

func GetTokenInfo(symbol string) TokenMeta {
	entry := getTokenEntry(symbol)
	return *entry.meta
}

func BalanceOf(symbol string, addr address) int64 {
	entry := getTokenEntry(symbol)
	return entry.token.BalanceOf(addr)
}

func TotalSupply(symbol string) int64 {
	entry := getTokenEntry(symbol)
	return entry.token.TotalSupply()
}

func GetName(symbol string) string {
	entry := getTokenEntry(symbol)
	return entry.token.GetName()
}

func GetSymbol(symbol string) string {
	entry := getTokenEntry(symbol)
	return entry.token.GetSymbol()
}

func GetDecimals(symbol string) int {
	entry := getTokenEntry(symbol)
	return entry.token.GetDecimals()
}

func GetProtocolFees() int64 {
	return protocolFeeAccumulator
}

type FactoryState struct {
	ProtocolFeeAccumulator int64
	MaxSupply              int64
	MaxBuy                 int64
	MaxSell                int64
	PausedTokensCount      int64
	GraduationThreshold    int64
	GlobalPaused           bool
}

func GetFactoryState() FactoryState {
	return FactoryState{
		ProtocolFeeAccumulator: protocolFeeAccumulator,
		MaxSupply:              MAX_SUPPLY,
		MaxBuy:                 MAX_BUY_UGNOT,
		MaxSell:                MAX_SELL_TOKENS,
		PausedTokensCount:      pausedTokensCount,
		GraduationThreshold:    GRADUATION_THRESHOLD,
		GlobalPaused:           globalPaused,
	}
}

// =============================================================================
// RENDER
// =============================================================================

func Render(path string) string {
	if path == "" {
		return "GnoPump Factory v5 (GRC20 Native)\n\nFeatures: GRC20 Tokens, Bonding Curve, DEX Graduation\nUsage: /r/gnopump/factory:SYMBOL or /r/gnopump/factory:SYMBOL/ADDRESS\n\nAll tokens are GRC20 compatible: Transfer, Approve, TransferFrom"
	}

	parts := strings.Split(path, "/")
	symbol := parts[0]

	entry, exists := tokenRegistry[symbol]
	if !exists {
		return sprintf("Token %s not found", symbol)
	}

	meta := entry.meta
	token := entry.token
	s := token.TotalSupply()
	price := spotPrice(s)

	gradProgress := (meta.Reserves * 100) / GRADUATION_THRESHOLD
	if gradProgress > 100 {
		gradProgress = 100
	}

	result := sprintf("=== %s ($%s) ===\n", meta.Name, meta.Symbol)
	result += sprintf("Standard: GRC20 (DEX Compatible)\n")
	result += sprintf("Decimals: %d\n", TOKEN_DECIMALS)
	
	if meta.Description != "" {
		result += sprintf("Description: %s\n", meta.Description)
	}
	if meta.ImageURL != "" {
		result += sprintf("Image: %s\n", meta.ImageURL)
	}
	result += sprintf("Creator: %s\n", string(meta.Creator))
	result += sprintf("Launched: block %d\n", meta.LaunchedAt)

	// Social Links
	if meta.Twitter != "" || meta.Telegram != "" || meta.Discord != "" || meta.Website != "" {
		result += "\nSocials:\n"
		if meta.Twitter != "" {
			result += sprintf("  Twitter: %s\n", meta.Twitter)
		}
		if meta.Telegram != "" {
			result += sprintf("  Telegram: %s\n", meta.Telegram)
		}
		if meta.Discord != "" {
			result += sprintf("  Discord: %s\n", meta.Discord)
		}
		if meta.Website != "" {
			result += sprintf("  Website: %s\n", meta.Website)
		}
	}

	status := "ACTIVE (Bonding Curve)"
	if meta.MigrationComplete {
		status = sprintf("MIGRATED - Trade on GnoPump or GnoSwap (Pool: %s)", meta.DEXPoolID)
	} else if meta.IsMigrating {
		status = "MIGRATING - Trading temporarily paused"
	} else if meta.IsGraduated {
		status = sprintf("GRADUATED (block %d) - Awaiting DEX migration", meta.GraduatedAt)
	} else if meta.IsPaused {
		status = "PAUSED"
	}
	result += sprintf("Status: %s\n", status)

	result += sprintf("\nSupply: %d / %d (Cap)\n", s, MAX_SUPPLY)
	result += sprintf("Reserves: %d ugnot\n", meta.Reserves)
	result += sprintf("Price: %d ugnot/token (spot)\n", price)

	if !meta.IsGraduated {
		result += sprintf("Graduation: %d%% (%d / %d ugnot)\n", gradProgress, meta.Reserves, GRADUATION_THRESHOLD)
	}

	// Fork/Royalty Info
	if meta.ParentSymbol != "" {
		result += sprintf("\nFork: Yes (Parent: %s)\n", meta.ParentSymbol)
		result += sprintf("Royalty Recipient: %s\n", string(meta.OriginCreator))
		result += sprintf("Royalty Rate: %d bps (%s)\n", meta.RoyaltyRateBps, formatBps(meta.RoyaltyRateBps))
	} else if meta.RoyaltyRateBps > 0 {
		result += sprintf("\nTemplate: Yes (Forkable)\n")
		result += sprintf("Royalty Rate: %d bps (%s)\n", meta.RoyaltyRateBps, formatBps(meta.RoyaltyRateBps))
		result += sprintf("Origin Creator: %s\n", string(meta.OriginCreator))
	}

	if len(parts) > 1 && parts[1] != "" {
		addr := address(parts[1])
		balance := token.BalanceOf(addr)
		result += sprintf("\nBalance of %s: %d\n", parts[1], balance)
	}

	return result
}
