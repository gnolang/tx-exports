package factory_v6

// GnoPump Factory V6 - GRC20-Native Token Launchpad
// Status: Production release candidate (internal AMM only)
// Milestone: 6 (security hardening)
// Features:
//   - Standard GRC20 tokens (Transfer, Approve, TransferFrom)
//   - Bonding curve for price discovery
//   - Automatic graduation at threshold
//   - Protocol-seeded, permanently locked internal AMM liquidity

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
	"gno.land/p/nt/seqid/v0"
	"gno.land/p/nt/ufmt/v0"
)

// =============================================================================
// CONSTANTS
// =============================================================================

// Curve amounts are whole tokens. Keeping decimals at zero makes the GRC20
// display unit match every supply, quote, sell-limit, and UI amount used by the
// protocol (MAX_SUPPLY is 300 million tokens, not 300 display tokens).
const TOKEN_DECIMALS = 0
const FEE_BPS = int64(100) // 1% protocol fee (bonding curve + AMM)
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
var pendingAdmin address // ADMIN-ROTATE-1: two-step admin handover target
var factoryBanker banker.Banker
var realmAddr address
var globalPaused bool // Emergency global pause - blocks all trading

// Current GRC20 identity includes a realm-local sequence ID. All three token
// creation paths must share one counter so emitted token IDs remain unique.
var nextTokenID seqid.ID

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
	Symbol      string
	Name        string
	Description string
	ImageURL    string
	BannerURL   string
	Creator     address
	LaunchedAt  int64

	// Social Links
	Twitter  string
	Telegram string
	Discord  string
	Website  string

	// Fork Royalties (V2)
	ParentSymbol      string  // Empty if original, parent's symbol if forked
	OriginCreator     address // Who receives royalties (parent's creator)
	RoyaltyRateBps    int64   // 0-500 (0%-5%) share of collected platform fees
	Reserves          int64
	IsGraduated       bool // Threshold reached, eligible for internal-AMM migration
	GraduatedAt       int64
	MigrationComplete bool   // One-way flag: bonding curve closed, internal AMM active
	PoolID            string // Internal AMM identifier after migration
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

// safeMul multiplies two non-negative int64 values and panics on overflow,
// turning a silent int64 wrap (which the AMM pricing/liquidity math is otherwise
// exposed to for large pools) into a graceful revert. AMM-OVERFLOW-1.
func safeMul(a, b int64) int64 {
	if a < 0 || b < 0 {
		panic("multiplication operands must be non-negative")
	}
	if a == 0 || b == 0 {
		return 0
	}
	c := a * b
	if c/a != b {
		panic("multiplication overflow")
	}
	return c
}

func safeAdd(a, b int64) int64 {
	if a < 0 || b < 0 {
		panic("addition operands must be non-negative")
	}
	c, ok := overflow.Add64(a, b)
	if !ok {
		panic("addition overflow")
	}
	return c
}

func safeSub(a, b int64) int64 {
	if a < 0 || b < 0 || b > a {
		panic("invalid non-negative subtraction")
	}
	c, ok := overflow.Sub64(a, b)
	if !ok {
		panic("subtraction overflow")
	}
	return c
}

// calculateBps avoids amount*bps overflow by splitting the quotient and
// remainder around the 10,000-basis-point denominator.
func calculateBps(amount, bps int64) int64 {
	if amount < 0 || bps < 0 || bps > 10000 {
		panic("invalid basis-point calculation")
	}
	whole := safeMul(amount/10000, bps)
	fraction := safeMul(amount%10000, bps) / 10000
	return safeAdd(whole, fraction)
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

	royaltyFee = calculateBps(fee, royaltyRateBps)
	protocolFee = safeSub(fee, royaltyFee)
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

func ugnotPayment() int64 {
	coins := unsafe.OriginSend()
	if len(coins) != 1 || coins[0].Denom != "ugnot" || coins[0].Amount <= 0 {
		panic("payment must contain only positive ugnot")
	}
	return coins[0].Amount
}

func assertNoPayment() {
	if !unsafe.OriginSend().IsZero() {
		panic("this operation does not accept attached coins")
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
	if err := rejectControlCharacters(n, "name"); err != nil {
		return "", err
	}
	return n, nil
}

func rejectControlCharacters(value, label string) error {
	for _, r := range value {
		if r < 32 || r == 127 {
			return errorf("%s cannot contain control characters", label)
		}
	}
	return nil
}

func validateDescription(raw string) (string, error) {
	d := strings.TrimSpace(raw)
	if len(d) > MAX_DESCRIPTION_LEN {
		return "", errorf("description too long: max %d chars", MAX_DESCRIPTION_LEN)
	}
	if err := rejectControlCharacters(d, "description"); err != nil {
		return "", err
	}
	return d, nil
}

func validateImageURL(raw string) (string, error) {
	u := strings.TrimSpace(raw)
	if len(u) > MAX_IMAGE_URL_LEN {
		return "", errorf("image URL too long: max %d chars", MAX_IMAGE_URL_LEN)
	}
	if err := rejectControlCharacters(u, "image URL"); err != nil {
		return "", err
	}
	if u != "" && !strings.HasPrefix(u, "https://") && !strings.HasPrefix(u, "ipfs://") {
		return "", errorf("image URL must use https:// or ipfs://")
	}
	return u, nil
}

func validateSocialURL(raw string) (string, error) {
	u := strings.TrimSpace(raw)
	if len(u) > MAX_SOCIAL_URL_LEN {
		return "", errorf("social URL too long: max %d chars", MAX_SOCIAL_URL_LEN)
	}
	if err := rejectControlCharacters(u, "social URL"); err != nil {
		return "", err
	}
	if u != "" && !strings.HasPrefix(u, "https://") {
		return "", errorf("social URL must use https://")
	}
	return u, nil
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

func LaunchToken(cur realm, rawSymbol, rawName, rawDescription, rawImageURL, rawBannerURL, rawTwitter, rawTelegram, rawDiscord, rawWebsite string) string {
	assertDirectPayer(cur)
	if globalPaused {
		panic("factory is globally paused")
	}
	caller := cur.Previous().Address()

	symbol, err := validateSymbol(rawSymbol)
	if err != nil {
		panic(err)
	}
	name, err := validateName(rawName)
	if err != nil {
		panic(err)
	}
	description, err := validateDescription(rawDescription)
	if err != nil {
		panic(err)
	}
	imageURL, err := validateImageURL(rawImageURL)
	if err != nil {
		panic(err)
	}
	bannerURL, err := validateImageURL(rawBannerURL)
	if err != nil {
		panic(err)
	}
	twitter, err := validateSocialURL(rawTwitter)
	if err != nil {
		panic(err)
	}
	telegram, err := validateSocialURL(rawTelegram)
	if err != nil {
		panic(err)
	}
	discord, err := validateSocialURL(rawDiscord)
	if err != nil {
		panic(err)
	}
	website, err := validateSocialURL(rawWebsite)
	if err != nil {
		panic(err)
	}

	if _, exists := tokenRegistry[symbol]; exists {
		panic(errorf("symbol %s already exists", symbol))
	}

	amtSent := ugnotPayment()
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
	protocolFeeAccumulator = safeAdd(protocolFeeAccumulator, CREATE_FEE)

	// Create GRC20 token with standard interface and a unique realm-local ID.
	token, ledger := grc20.NewToken(name, symbol, TOKEN_DECIMALS, nextTokenID.Next(), cur)

	meta := &TokenMeta{
		Symbol:      symbol,
		Name:        name,
		Description: description,
		ImageURL:    imageURL,
		BannerURL:   bannerURL,
		Creator:     caller,
		LaunchedAt:  runtime.ChainHeight(),
		Twitter:     twitter,
		Telegram:    telegram,
		Discord:     discord,
		Website:     website,
		Reserves:    0,
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
		"token_id", token.ID(),
		"symbol", symbol,
		"name", name,
		"decimals", strconv.Itoa(TOKEN_DECIMALS),
		"creator", string(caller),
		"description", description,
		"image_url", imageURL,
		"banner_url", bannerURL,
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
func LaunchTemplate(cur realm, rawSymbol, rawName, rawDescription, rawImageURL, rawBannerURL, rawTwitter, rawTelegram, rawDiscord, rawWebsite string, royaltyRateBps int64) string {
	assertDirectPayer(cur)
	if globalPaused {
		panic("factory is globally paused")
	}
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
	description, err := validateDescription(rawDescription)
	if err != nil {
		panic(err)
	}
	imageURL, err := validateImageURL(rawImageURL)
	if err != nil {
		panic(err)
	}
	bannerURL, err := validateImageURL(rawBannerURL)
	if err != nil {
		panic(err)
	}
	twitter, err := validateSocialURL(rawTwitter)
	if err != nil {
		panic(err)
	}
	telegram, err := validateSocialURL(rawTelegram)
	if err != nil {
		panic(err)
	}
	discord, err := validateSocialURL(rawDiscord)
	if err != nil {
		panic(err)
	}
	website, err := validateSocialURL(rawWebsite)
	if err != nil {
		panic(err)
	}

	if _, exists := tokenRegistry[symbol]; exists {
		panic(errorf("symbol %s already exists", symbol))
	}

	amtSent := ugnotPayment()
	if amtSent < CREATE_FEE {
		panic(errorf("need %d ugnot", CREATE_FEE))
	}

	if amtSent > CREATE_FEE {
		refund := chain.Coins{chain.NewCoin("ugnot", amtSent-CREATE_FEE)}
		factoryBanker.SendCoins(realmAddr, caller, refund)
	}

	// CREATE_FEE is protocol revenue; track it once in the protocol accumulator.
	protocolFeeAccumulator = safeAdd(protocolFeeAccumulator, CREATE_FEE)

	// Create GRC20 token with the factory-wide identity sequence.
	token, ledger := grc20.NewToken(name, symbol, TOKEN_DECIMALS, nextTokenID.Next(), cur)

	meta := &TokenMeta{
		Symbol:         symbol,
		Name:           name,
		Description:    description,
		ImageURL:       imageURL,
		BannerURL:      bannerURL,
		Creator:        caller,
		LaunchedAt:     runtime.ChainHeight(),
		Twitter:        twitter,
		Telegram:       telegram,
		Discord:        discord,
		Website:        website,
		ParentSymbol:   "",     // No parent - this IS the origin
		OriginCreator:  caller, // Creator earns royalties on forks
		RoyaltyRateBps: royaltyRateBps,
		Reserves:       0,
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
		"token_id", token.ID(),
		"symbol", symbol,
		"name", name,
		"decimals", strconv.Itoa(TOKEN_DECIMALS),
		"creator", string(caller),
		"origin_creator", string(caller),
		"description", description,
		"image_url", imageURL,
		"banner_url", bannerURL,
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
func ForkToken(cur realm, parentSymbol, rawSymbol, rawName, rawDescription, rawImageURL, rawBannerURL, rawTwitter, rawTelegram, rawDiscord, rawWebsite string) string {
	assertDirectPayer(cur)
	if globalPaused {
		panic("factory is globally paused")
	}
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
	description, err := validateDescription(rawDescription)
	if err != nil {
		panic(err)
	}
	imageURL, err := validateImageURL(rawImageURL)
	if err != nil {
		panic(err)
	}
	bannerURL, err := validateImageURL(rawBannerURL)
	if err != nil {
		panic(err)
	}
	twitter, err := validateSocialURL(rawTwitter)
	if err != nil {
		panic(err)
	}
	telegram, err := validateSocialURL(rawTelegram)
	if err != nil {
		panic(err)
	}
	discord, err := validateSocialURL(rawDiscord)
	if err != nil {
		panic(err)
	}
	website, err := validateSocialURL(rawWebsite)
	if err != nil {
		panic(err)
	}

	if _, exists := tokenRegistry[symbol]; exists {
		panic(errorf("symbol %s already exists", symbol))
	}

	amtSent := ugnotPayment()
	if amtSent < CREATE_FEE {
		panic(errorf("need %d ugnot", CREATE_FEE))
	}

	if amtSent > CREATE_FEE {
		refund := chain.Coins{chain.NewCoin("ugnot", amtSent-CREATE_FEE)}
		factoryBanker.SendCoins(realmAddr, caller, refund)
	}

	// CREATE_FEE is protocol revenue; track it once in the protocol accumulator.
	protocolFeeAccumulator = safeAdd(protocolFeeAccumulator, CREATE_FEE)

	// Create GRC20 token with the factory-wide identity sequence.
	token, ledger := grc20.NewToken(name, symbol, TOKEN_DECIMALS, nextTokenID.Next(), cur)

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
		BannerURL:      bannerURL,
		Creator:        caller,
		LaunchedAt:     runtime.ChainHeight(),
		Twitter:        twitter,
		Telegram:       telegram,
		Discord:        discord,
		Website:        website,
		ParentSymbol:   parentSymbol,              // Link to parent
		OriginCreator:  originCreator,             // Who gets royalties
		RoyaltyRateBps: parentMeta.RoyaltyRateBps, // Inherit royalty rate
		Reserves:       0,
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
		"token_id", token.ID(),
		"symbol", symbol,
		"name", name,
		"decimals", strconv.Itoa(TOKEN_DECIMALS),
		"parent_symbol", parentSymbol,
		"creator", string(caller),
		"origin_creator", string(originCreator),
		"description", description,
		"image_url", imageURL,
		"banner_url", bannerURL,
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
	if entry.meta.IsGraduated {
		panic("bonding curve closed at graduation")
	}

	fee = calculateBps(ugnotIn, FEE_BPS)
	if fee == 0 && ugnotIn > 0 {
		fee = 1
	}
	net := safeSub(ugnotIn, fee)

	if net <= 0 {
		return 0, fee, 0
	}

	S := entry.token.TotalSupply()
	A := SLOPE_A

	term1 := (S + A) * (S + A)
	term2 := 2 * A * net

	S_new := sqrt(term1+term2) - A

	clamped := false
	if S_new > MAX_SUPPLY {
		S_new = MAX_SUPPLY
		clamped = true
	}

	tokensOut = S_new - S

	if tokensOut < 0 {
		tokensOut = 0
	}

	costActual := integral(S_new) - integral(S)
	ugnotChange = safeSub(net, costActual)

	// FEE-ON-CHANGE-1: when the buy is clamped at MAX_SUPPLY, a large portion of
	// the payment is refunded as change, but `fee` was taken on the full payment.
	// Recompute the fee on the GNOT actually spent and refund the difference so a
	// capped buy is not overcharged. Normal (unclamped) buys are unaffected.
	if clamped {
		spentFee := calculateBps(costActual, FEE_BPS)
		if spentFee == 0 && costActual > 0 {
			spentFee = 1
		}
		if spentFee < fee {
			ugnotChange = safeAdd(ugnotChange, fee-spentFee)
			fee = spentFee
		}
	}

	return tokensOut, fee, ugnotChange
}

func QuoteSell(symbol string, tokensIn int64) (ugnotOut int64, fee int64) {
	if tokensIn > MAX_SELL_TOKENS {
		panic(errorf("sell amount exceeds limit: %d > %d", tokensIn, MAX_SELL_TOKENS))
	}

	entry := getTokenEntry(symbol)
	if entry.meta.IsGraduated {
		panic("bonding curve closed at graduation")
	}

	S := entry.token.TotalSupply()
	if tokensIn > S {
		panic("cannot sell more than supply")
	}
	S_new := safeSub(S, tokensIn)

	grossProceeds := safeSub(integral(S), integral(S_new))

	fee = calculateBps(grossProceeds, FEE_BPS)
	if fee == 0 && grossProceeds > 0 {
		fee = 1
	}

	ugnotOut = safeSub(grossProceeds, fee)
	return ugnotOut, fee
}

func Buy(cur realm, symbol string, minTokensOut int64) int64 {
	assertDirectPayer(cur)
	if globalPaused {
		panic("factory is globally paused")
	}
	if minTokensOut <= 0 {
		panic("minimum token output required")
	}
	caller := cur.Previous().Address()
	entry := getTokenEntry(symbol)

	if entry.meta.MigrationComplete {
		panic("token migrated to the internal AMM - use SwapGNOTForToken")
	}
	if entry.meta.IsGraduated {
		panic("bonding curve closed at graduation - activate the internal AMM")
	}

	payment := ugnotPayment()
	if payment <= 0 {
		panic("must send ugnot")
	}

	tokensAmount, fee, change := QuoteBuy(symbol, payment)

	if tokensAmount <= 0 {
		panic("payment too small to buy tokens")
	}

	if tokensAmount < minTokensOut {
		panic(errorf("slippage exceeded: got %d, expected min %d", tokensAmount, minTokensOut))
	}

	supplyAfter := safeAdd(entry.token.TotalSupply(), tokensAmount)
	if supplyAfter > MAX_SUPPLY {
		panic("supply cap exceeded")
	}

	spent := safeSub(safeSub(payment, fee), change)
	reservesAfter := safeAdd(entry.meta.Reserves, spent)

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

	protocolFeeAccumulator = safeAdd(protocolFeeAccumulator, protocolFee)

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
	assertNoPayment()
	if globalPaused {
		panic("factory is globally paused")
	}
	if minUgnotOut <= 0 {
		panic("minimum GNOT output required")
	}
	caller := cur.Previous().Address()
	entry := getTokenEntry(symbol)

	if entry.meta.MigrationComplete {
		panic("token migrated to the internal AMM - use SwapTokenForGNOT")
	}
	if entry.meta.IsGraduated {
		panic("bonding curve closed at graduation - activate the internal AMM")
	}

	balance := entry.token.BalanceOf(caller)
	if amount > balance {
		panic(errorf("insufficient balance: %d < %d", balance, amount))
	}

	supplyBefore := entry.token.TotalSupply()
	supplyAfter := safeSub(supplyBefore, amount)

	ugnotOut, fee := QuoteSell(symbol, amount)

	// DUST-SELL-1: reject sales whose net proceeds round to zero - otherwise the
	// seller burns tokens and reduces reserves for no ugnot in return.
	if ugnotOut <= 0 {
		panic("sale proceeds too small: would burn tokens for zero ugnot")
	}

	if ugnotOut < minUgnotOut {
		panic(errorf("slippage exceeded: got %d ugnot, expected min %d", ugnotOut, minUgnotOut))
	}

	grossProceeds := safeAdd(ugnotOut, fee)
	if grossProceeds > entry.meta.Reserves {
		panic(errorf("insufficient reserves: %d < %d", entry.meta.Reserves, grossProceeds))
	}
	reservesAfter := safeSub(entry.meta.Reserves, grossProceeds)

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

	protocolFeeAccumulator = safeAdd(protocolFeeAccumulator, protocolFee)

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
	assertNoPayment()
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
	assertNoPayment()
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
	assertNoPayment()
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
// GRADUATION & INTERNAL-AMM MIGRATION
// =============================================================================

// checkGraduation marks token as graduated when threshold reached
// Curve trading closes immediately. Any caller can then atomically activate the
// deterministic AMM, so no privileged operator can choose or block the venue.
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

// GetMigrationStatus preserves the read shape used by existing clients. V6 has
// no intermediate migration state: activation is a single atomic transaction,
// so migrating is always false.
func GetMigrationStatus(symbol string) (graduated bool, migrating bool, complete bool, poolID string) {
	entry := getTokenEntry(symbol)
	return entry.meta.IsGraduated, false, entry.meta.MigrationComplete, entry.meta.PoolID
}

// =============================================================================
// INTERNAL AMM POOL FOR GRADUATED TOKENS
// =============================================================================
// After graduation, tokens trade via constant-product AMM (x*y=k)
// V6 deliberately has no external pool adapter. Holders move their tokens only
// through direct GRC20 calls and the internal AMM entry points below.

// Pool state for graduated tokens
type AMMPool struct {
	TokenReserve int64 // Token reserve in pool
	GNOTReserve  int64 // GNOT reserve in pool
	KLast        int64 // k = token * gnot (for fee calculation)
	TotalLP      int64 // Total LP tokens issued
	Active       bool  // Is pool active for trading
}

// LP token balances per user per pool
var lpBalances = make(map[string]map[address]int64) // symbol -> address -> LP amount
var ammPools = make(map[string]*AMMPool)            // symbol -> pool

// InitializeAMMPool atomically closes the bonding curve and creates its AMM.
// Activation is permissionless because every parameter is derived on-chain;
// no operator can choose the opening price, seed amount, or LP recipient.
func InitializeAMMPool(cur realm, symbol string) {
	assertNoPayment()
	if globalPaused {
		panic("factory is globally paused")
	}

	entry := getTokenEntry(symbol)
	if !entry.meta.IsGraduated {
		panic("token must graduate before AMM activation")
	}
	if entry.meta.MigrationComplete {
		panic("token already migrated")
	}
	if ammPools[symbol] != nil {
		panic("AMM pool already exists")
	}

	gnotReserve := entry.meta.Reserves
	if gnotReserve <= 0 {
		panic("no GNOT reserves to seed pool")
	}

	currentSupply := entry.token.TotalSupply()
	openingPrice := spotPrice(currentSupply)
	if openingPrice <= 0 {
		panic("invalid opening price")
	}
	tokenAmount := gnotReserve / openingPrice
	if tokenAmount <= 0 {
		panic("reserves too small to seed AMM at the bonding-curve price")
	}
	if safeAdd(currentSupply, tokenAmount) > MAX_SUPPLY {
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
	// The realm owns the initial LP. There is intentionally no exported method
	// that can impersonate realmAddr or withdraw this position, so the seed stays
	// permanently locked and TotalLP cannot reach zero through user exits.
	lpBalances[symbol][realmAddr] = gnotReserve

	// Clear reserves (now in pool)
	entry.meta.Reserves = 0
	entry.meta.MigrationComplete = true
	entry.meta.PoolID = "gnopump-amm-" + symbol

	chain.Emit(
		"AMMPoolCreated",
		"symbol", symbol,
		"actor", string(cur.Previous().Address()),
		"token_reserve", strconv.Itoa(int(tokenAmount)),
		"gnot_reserve", strconv.Itoa(int(gnotReserve)),
		"opening_price", strconv.Itoa(int(openingPrice)),
		"initial_k", strconv.Itoa(int(k)),
	)
	chain.Emit(
		"MigrationComplete",
		"symbol", symbol,
		"pool_id", entry.meta.PoolID,
		"venue", "internal_amm",
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
	if minTokensOut <= 0 {
		panic("minimum token output required")
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

	ugnotIn := ugnotPayment()
	if ugnotIn <= 0 {
		panic("must send GNOT to swap")
	}

	// AMM fee = 2%: 1% protocol (FEE_BPS, withdrawable / royalty-split) + 1% LP
	// (LP_FEE_BPS, retained in the pool so liquidity providers earn yield).
	protoFee := calculateBps(ugnotIn, FEE_BPS)
	if protoFee == 0 && ugnotIn > 0 {
		protoFee = 1
	}
	lpFee := calculateBps(ugnotIn, LP_FEE_BPS)

	// Amount actually swapped against the curve (input minus both fees).
	amountForPricing := safeSub(safeSub(ugnotIn, protoFee), lpFee)
	if amountForPricing <= 0 {
		panic("swap amount too small")
	}

	// Calculate tokens out using constant product formula
	// dy = y * dx / (x + dx + 1) -- +1 to prevent rounding exploits
	buyDenominator := safeAdd(safeAdd(pool.GNOTReserve, amountForPricing), 1)
	tokensOut := safeMul(pool.TokenReserve, amountForPricing) / buyDenominator

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
	protocolFeeAccumulator = safeAdd(protocolFeeAccumulator, protocolFee)

	// Update pool state. The pool keeps everything except the protocol fee
	// (which leaves as accumulator + royalty): the LP fee thus stays in the
	// pool, raising k for liquidity providers.
	pool.GNOTReserve = safeAdd(pool.GNOTReserve, ugnotIn-protoFee)
	pool.TokenReserve = safeSub(pool.TokenReserve, tokensOut)
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
	assertNoPayment()
	if globalPaused {
		panic("factory is globally paused")
	}
	if minGNOTOut <= 0 {
		panic("minimum GNOT output required")
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
	sellDenominator := safeAdd(safeAdd(pool.TokenReserve, tokenAmount), 1)
	gnotOut := safeMul(pool.GNOTReserve, tokenAmount) / sellDenominator

	if gnotOut <= 0 {
		panic("swap amount too small")
	}

	// AMM fee = 2%: 1% protocol (FEE_BPS) + 1% LP (LP_FEE_BPS, retained in pool).
	protoFee := calculateBps(gnotOut, FEE_BPS)
	if protoFee == 0 && gnotOut > 0 {
		protoFee = 1
	}
	lpFee := calculateBps(gnotOut, LP_FEE_BPS)
	netGNOTOut := safeSub(safeSub(gnotOut, protoFee), lpFee)
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
	protocolFeeAccumulator = safeAdd(protocolFeeAccumulator, protocolFee)

	// Transfer tokens from seller to pool
	if err := entry.ledger.Transfer(caller, realmAddr, tokenAmount); err != nil {
		panic(err)
	}

	// Update pool state. The pool pays out only (gnotOut - lpFee), so the LP fee
	// stays in the pool, raising k for liquidity providers.
	pool.TokenReserve = safeAdd(pool.TokenReserve, tokenAmount)
	pool.GNOTReserve = safeSub(pool.GNOTReserve, gnotOut-lpFee)
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
	if ugnotIn <= 0 || pool == nil || !pool.Active || pool.TokenReserve <= 0 || pool.GNOTReserve <= 0 {
		return 0, 0
	}

	protoFee := calculateBps(ugnotIn, FEE_BPS)
	if protoFee == 0 && ugnotIn > 0 {
		protoFee = 1
	}
	lpFee := calculateBps(ugnotIn, LP_FEE_BPS)
	fee = safeAdd(protoFee, lpFee)

	amountForPricing := safeSub(ugnotIn, fee)
	if amountForPricing <= 0 {
		return 0, fee
	}
	buyDenominator := safeAdd(safeAdd(pool.GNOTReserve, amountForPricing), 1)
	tokensOut = safeMul(pool.TokenReserve, amountForPricing) / buyDenominator
	return tokensOut, fee
}

// QuoteAMMSell returns expected GNOT out for tokens in.
// fee is the TOTAL swap fee (protocol 1% + LP 1% = 2%), matching SwapTokenForGNOT.
func QuoteAMMSell(symbol string, tokenAmount int64) (gnotOut int64, fee int64) {
	pool := ammPools[symbol]
	if tokenAmount <= 0 || pool == nil || !pool.Active || pool.TokenReserve <= 0 || pool.GNOTReserve <= 0 {
		return 0, 0
	}

	sellDenominator := safeAdd(safeAdd(pool.TokenReserve, tokenAmount), 1)
	grossOut := safeMul(pool.GNOTReserve, tokenAmount) / sellDenominator
	protoFee := calculateBps(grossOut, FEE_BPS)
	if protoFee == 0 && grossOut > 0 {
		protoFee = 1
	}
	lpFee := calculateBps(grossOut, LP_FEE_BPS)
	fee = safeAdd(protoFee, lpFee)
	gnotOut = safeSub(grossOut, fee)
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
	return safeMul(pool.GNOTReserve, 1000000) / pool.TokenReserve
}

// =============================================================================
// LP TOKEN MANAGEMENT (for users to add/remove liquidity)
// =============================================================================

// QuoteAddLiquidity returns the token amount required and LP amount minted for a
// given GNOT contribution at the current pool ratio.
func QuoteAddLiquidity(symbol string, gnotAmount int64) (tokensRequired int64, lpOut int64) {
	pool := ammPools[symbol]
	if gnotAmount <= 0 || pool == nil || !pool.Active || pool.TokenReserve <= 0 || pool.GNOTReserve <= 0 || pool.TotalLP <= 0 {
		return 0, 0
	}
	tokensRequired = safeMul(gnotAmount, pool.TokenReserve) / pool.GNOTReserve
	lpOut = safeMul(gnotAmount, pool.TotalLP) / pool.GNOTReserve
	return tokensRequired, lpOut
}

// QuoteRemoveLiquidity returns the two assets represented by an LP amount at the
// current pool state.
func QuoteRemoveLiquidity(symbol string, lpAmount int64) (tokensOut int64, gnotOut int64) {
	pool := ammPools[symbol]
	if lpAmount <= 0 || pool == nil || !pool.Active || pool.TotalLP <= 0 {
		return 0, 0
	}
	tokensOut = safeMul(lpAmount, pool.TokenReserve) / pool.TotalLP
	gnotOut = safeMul(lpAmount, pool.GNOTReserve) / pool.TotalLP
	return tokensOut, gnotOut
}

// AddLiquidity lets users add liquidity to graduated token pools. tokenAmount is
// the maximum number of tokens the caller is willing to contribute; minLpOut is
// mandatory and protects the minted position from a changed pool state.
func AddLiquidity(cur realm, symbol string, tokenAmount int64, minLpOut int64) int64 {
	assertDirectPayer(cur)
	if globalPaused {
		panic("factory is globally paused")
	}
	caller := cur.Previous().Address()
	entry := getTokenEntry(symbol)

	pool := ammPools[symbol]
	if pool == nil || !pool.Active || pool.TokenReserve <= 0 || pool.GNOTReserve <= 0 || pool.TotalLP <= 0 {
		panic("AMM pool not active")
	}
	if tokenAmount <= 0 {
		panic("token amount must be positive")
	}
	if minLpOut <= 0 {
		panic("minimum LP output required")
	}

	gnotAmount := ugnotPayment()
	if gnotAmount <= 0 {
		panic("must send GNOT")
	}

	// Check user has enough tokens
	balance := entry.token.BalanceOf(caller)
	if tokenAmount > balance {
		panic(errorf("insufficient token balance: %d < %d", balance, tokenAmount))
	}

	// Calculate expected ratio and LP output from one consistent pool snapshot.
	expectedTokens, lpTokens := QuoteAddLiquidity(symbol, gnotAmount)
	if tokenAmount < expectedTokens {
		panic(errorf("insufficient tokens for ratio: need %d, got %d", expectedTokens, tokenAmount))
	}

	// Use exact amounts based on GNOT sent
	actualTokens := expectedTokens

	// ADDLIQ-NO-GNOT-REFUND-ZERO-LP: reject dust adds that would credit 0 LP or
	// pull 0 tokens for nonzero GNOT - otherwise the GNOT is kept by the pool
	// with nothing (or an unbacked LP balance) returned to the provider.
	if lpTokens <= 0 || actualTokens <= 0 {
		panic("liquidity amount too small: would mint zero LP")
	}
	if lpTokens < minLpOut {
		panic(errorf("slippage exceeded: LP out %d < min %d", lpTokens, minLpOut))
	}

	// Transfer tokens from user to pool
	if err := entry.ledger.Transfer(caller, realmAddr, actualTokens); err != nil {
		panic(err)
	}

	// Update pool state
	pool.TokenReserve = safeAdd(pool.TokenReserve, actualTokens)
	pool.GNOTReserve = safeAdd(pool.GNOTReserve, gnotAmount)
	pool.TotalLP = safeAdd(pool.TotalLP, lpTokens)
	pool.KLast = safeK(pool.TokenReserve, pool.GNOTReserve)

	// Credit LP tokens to user
	if lpBalances[symbol] == nil {
		lpBalances[symbol] = make(map[address]int64)
	}
	lpBalances[symbol][caller] = safeAdd(lpBalances[symbol][caller], lpTokens)

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

// RemoveLiquidity lets LP holders withdraw their share while binding both assets
// received. At least one positive minimum is required so an unbounded exit cannot
// be submitted.
func RemoveLiquidity(cur realm, symbol string, lpAmount int64, minTokensOut int64, minGNOTOut int64) (tokensOut int64, gnotOut int64) {
	assertNoPayment()
	if globalPaused {
		panic("factory is globally paused")
	}
	if lpAmount <= 0 {
		panic("LP amount must be positive")
	}
	if minTokensOut < 0 || minGNOTOut < 0 {
		panic("minimum outputs cannot be negative")
	}
	if minTokensOut == 0 && minGNOTOut == 0 {
		panic("at least one minimum output is required")
	}
	caller := cur.Previous().Address()
	entry := getTokenEntry(symbol)

	pool := ammPools[symbol]
	if pool == nil || !pool.Active || pool.TotalLP <= 0 || pool.TokenReserve <= 0 || pool.GNOTReserve <= 0 {
		panic("pool not found")
	}

	userLP := lpBalances[symbol][caller]
	if lpAmount > userLP {
		panic(errorf("insufficient LP tokens: %d < %d", userLP, lpAmount))
	}

	// Calculate share of pool from the same state checked by the output bounds.
	tokensOut, gnotOut = QuoteRemoveLiquidity(symbol, lpAmount)

	// AMM-REMOVELIQ-ROUND-1: only reject when BOTH sides round to zero. In an
	// imbalanced pool one side can integer-truncate to 0 for a small LP burn;
	// requiring both > 0 previously bricked the only exit for dust LP holders.
	if tokensOut <= 0 && gnotOut <= 0 {
		panic("withdrawal too small")
	}
	if tokensOut < minTokensOut {
		panic(errorf("slippage exceeded: tokens out %d < min %d", tokensOut, minTokensOut))
	}
	if gnotOut < minGNOTOut {
		panic(errorf("slippage exceeded: GNOT out %d < min %d", gnotOut, minGNOTOut))
	}
	if pool.TotalLP-lpAmount < lpBalances[symbol][realmAddr] {
		panic("withdrawal would consume locked protocol liquidity")
	}

	// Update pool state
	pool.TokenReserve = safeSub(pool.TokenReserve, tokensOut)
	pool.GNOTReserve = safeSub(pool.GNOTReserve, gnotOut)
	pool.TotalLP = safeSub(pool.TotalLP, lpAmount)
	pool.KLast = safeK(pool.TokenReserve, pool.GNOTReserve)

	// Burn LP tokens
	lpBalances[symbol][caller] = safeSub(lpBalances[symbol][caller], lpAmount)

	// Transfer tokens to user (skip a zero side, see AMM-REMOVELIQ-ROUND-1)
	if tokensOut > 0 {
		if err := entry.ledger.Transfer(realmAddr, caller, tokensOut); err != nil {
			panic(err)
		}
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

// GetTradeRoute tells the UI which lifecycle action is currently valid.
// "graduated" is a deliberately non-trading state awaiting permissionless,
// deterministic internal-AMM activation.
func GetTradeRoute(symbol string) string {
	entry := getTokenEntry(symbol)
	if entry.meta.MigrationComplete {
		return "amm"
	}
	if entry.meta.IsGraduated {
		return "graduated"
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
	} else if entry.meta.IsGraduated {
		return 0, 0, "graduated"
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
// ADMIN FUNCTIONS
// =============================================================================

func WithdrawProtocolFees(cur realm, to address) {
	assertNoPayment()
	if cur.Previous().Address() != admin {
		panic("unauthorized: only admin can withdraw fees")
	}
	if to == "" {
		panic("recipient required")
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

// GetProtocolLockedLP exposes the permanently locked seed position for audits.
// There is deliberately no corresponding withdrawal entry point.
func GetProtocolLockedLP(symbol string) int64 {
	if lpBalances[symbol] == nil {
		return 0
	}
	return lpBalances[symbol][realmAddr]
}

// ProposeAdmin / AcceptAdmin implement a two-step admin handover.
// ADMIN-ROTATE-1: the admin key was previously immutable and unrecoverable. This
// lets the current admin hand control to a new key (e.g. a multisig) which must
// confirm, preventing a handover to a wrong or uncontrolled address.
func ProposeAdmin(cur realm, newAdmin address) {
	assertNoPayment()
	if cur.Previous().Address() != admin {
		panic("unauthorized: only admin can propose a new admin")
	}
	if newAdmin == "" {
		panic("new admin required")
	}
	if newAdmin == admin {
		panic("new admin must differ from current admin")
	}
	if newAdmin == pendingAdmin {
		panic("admin proposal already pending for this address")
	}
	pendingAdmin = newAdmin
	chain.Emit("AdminProposed", "current", string(admin), "pending", string(newAdmin))
}

func CancelAdminProposal(cur realm) {
	assertNoPayment()
	if cur.Previous().Address() != admin {
		panic("unauthorized: only admin can cancel an admin proposal")
	}
	if pendingAdmin == "" {
		panic("no pending admin")
	}
	cancelled := pendingAdmin
	pendingAdmin = ""
	chain.Emit("AdminProposalCancelled", "admin", string(admin), "cancelled", string(cancelled))
}

func AcceptAdmin(cur realm) {
	assertNoPayment()
	caller := cur.Previous().Address()
	if pendingAdmin == "" {
		panic("no pending admin")
	}
	if caller != pendingAdmin {
		panic("unauthorized: only the pending admin can accept")
	}
	old := admin
	admin = pendingAdmin
	pendingAdmin = ""
	chain.Emit("AdminTransferred", "from", string(old), "to", string(admin))
}

// GetAdmin returns the current admin address.
func GetAdmin() address { return admin }

// GetPendingAdmin returns the proposed next admin (empty if none).
func GetPendingAdmin() address { return pendingAdmin }

// GlobalPause halts all trading on the factory (emergency use only)
func GlobalPause(cur realm) {
	assertNoPayment()
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
	assertNoPayment()
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

// GetTokenID returns the canonical GRC20 identity emitted at creation. GnoPump
// tokens share this factory realm rather than deploying one realm per token.
func GetTokenID(symbol string) string {
	entry := getTokenEntry(symbol)
	return entry.token.ID()
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
	GraduationThreshold    int64
	GlobalPaused           bool
}

func GetFactoryState() FactoryState {
	return FactoryState{
		ProtocolFeeAccumulator: protocolFeeAccumulator,
		MaxSupply:              MAX_SUPPLY,
		MaxBuy:                 MAX_BUY_UGNOT,
		MaxSell:                MAX_SELL_TOKENS,
		GraduationThreshold:    GRADUATION_THRESHOLD,
		GlobalPaused:           globalPaused,
	}
}

// =============================================================================
// RENDER
// =============================================================================

func Render(path string) string {
	if path == "" {
		return "GnoPump Factory v6 (GRC20 Native)\n\nFeatures: GRC20 Tokens, Bonding Curve, Locked-Liquidity Internal AMM\nUsage: FACTORY_PATH:SYMBOL or FACTORY_PATH:SYMBOL/ADDRESS\n\nAll tokens are GRC20 compatible: Transfer, Approve, TransferFrom"
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
	displayedReserves := meta.Reserves
	if meta.MigrationComplete {
		pool := ammPools[symbol]
		if pool != nil && pool.Active && pool.TokenReserve > 0 {
			displayedReserves = pool.GNOTReserve
			price = pool.GNOTReserve / pool.TokenReserve
		}
	}

	gradProgress := (meta.Reserves * 100) / GRADUATION_THRESHOLD
	if gradProgress > 100 {
		gradProgress = 100
	}

	result := sprintf("=== %s ($%s) ===\n", meta.Name, meta.Symbol)
	result += sprintf("Standard: GRC20\n")
	result += sprintf("Decimals: %d\n", TOKEN_DECIMALS)

	if meta.Description != "" {
		result += sprintf("Description: %s\n", meta.Description)
	}
	if meta.ImageURL != "" {
		result += sprintf("Image: %s\n", meta.ImageURL)
	}
	if meta.BannerURL != "" {
		result += sprintf("Banner: %s\n", meta.BannerURL)
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
	if globalPaused {
		status = "GLOBAL PAUSE - Transfers and trading disabled"
	} else if meta.MigrationComplete {
		status = sprintf("ACTIVE (Internal AMM, locked seed LP; Pool: %s)", meta.PoolID)
	} else if meta.IsGraduated {
		status = sprintf("GRADUATED (block %d) - AMM activation available", meta.GraduatedAt)
	}
	result += sprintf("Status: %s\n", status)

	result += sprintf("\nSupply: %d / %d (Cap)\n", s, MAX_SUPPLY)
	result += sprintf("Reserves: %d ugnot\n", displayedReserves)
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
