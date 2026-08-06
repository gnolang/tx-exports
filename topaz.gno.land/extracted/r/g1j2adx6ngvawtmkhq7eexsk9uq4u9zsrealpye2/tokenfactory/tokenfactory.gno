// Package tokenfactory is a shared realm that mints fixed-supply
// GRC20-shaped fungible tokens on demand — an alternative to
// gno-token-minter's other design (gno.land/r/<addr>/token), where each
// creator deploys their own dedicated avl+token realm pair.
//
// Deployed exactly once, ever, under this project's own address. After
// that, creating a new token costs one MsgCall (New) instead of two
// MsgAddPackage deploys — see this project's design notes for the real
// measured cost comparison between the two approaches.
//
// Every token created here is fixed-supply: New mints the entire
// totalSupply to the caller once, at creation, and there is no mint
// path anywhere in this realm that can ever increase a symbol's supply
// afterward — same guarantee gno-token-minter's other design makes, just
// enforced by "no Mint function exists" per instance rather than "no
// Mint function exists in the realm."
//
// Anyone can call New with any symbol — first-come-first-served, no
// identity check tying a symbol to who it might suggest (e.g. calling
// New with symbol "BTC" doesn't mean anything beyond "someone claimed
// that symbol here first"). That's inherent to any public, permissionless
// token factory (the same is true of ERC20 factories on Ethereum), not
// a gap specific to this implementation — Render() surfaces each token's
// real creator address so anyone checking can verify it themselves
// rather than trusting the symbol/name alone.
package tokenfactory

import (
	unsaferealm "chain/runtime/unsafe"
	"chain"
	"errors"
	"math/overflow"
	"strconv"
	"strings"

	"gno.land/p/g1j2adx6ngvawtmkhq7eexsk9uq4u9zsrealpye2/avl"
)

const (
	TokenCreatedEvent = "TokenCreated"
	MintEvent         = "Mint"
	TransferEvent     = "Transfer"
	ApprovalEvent     = "Approval"
)

const (
	MaxNameLen   = 64
	MinSymbolLen = 1
	MaxSymbolLen = 10
	MaxDecimals  = 18
)

var (
	ErrInsufficientBalance   = errors.New("insufficient balance")
	ErrInsufficientAllowance = errors.New("insufficient allowance")
	ErrInvalidAddress        = errors.New("invalid address")
	ErrCannotTransferToSelf  = errors.New("cannot transfer to self")
	ErrInvalidAmount         = errors.New("invalid amount")
	ErrSymbolTaken           = errors.New("symbol already exists")
	ErrUnknownSymbol         = errors.New("unknown token symbol")
	ErrInvalidName           = errors.New("invalid token name (empty, too long, or contains control characters)")
	ErrInvalidSymbol         = errors.New("invalid symbol (must be 1-10 uppercase letters/digits)")
	ErrInvalidDecimals       = errors.New("invalid decimals (must be 0-18)")
	ErrInvalidSupply         = errors.New("invalid total supply (must be positive)")
)

// token is one fixed-supply token instance living inside this factory.
// Every field except balances/allowances is immutable after New() sets
// it — there is no admin, no owner, and no function anywhere in this
// file that can mint more of an already-created token.
type token struct {
	name        string
	symbol      string
	decimals    int
	totalSupply int64
	creator     address
	balances    avl.Tree // address string -> int64
	allowances  avl.Tree // "owner:spender" string -> int64
}

// instances holds every token this factory has ever created, keyed by
// symbol. Symbols are the public identity of a token here (there's no
// separate numeric ID) — chosen deliberately so URLs/render paths and
// every public function signature stay human-readable.
var instances avl.Tree // symbol -> *token

// callerAddress derives the address that crossed into whichever
// exported function called this. Uses chain/runtime/unsafe.PreviousRealm()
// instead of cur.Previous() for the same reason and under the same
// safety argument as gno-nft-minter's identical helper and this
// project's own token.gno: not available on every gno.land network
// (confirmed missing on Beta Mainnet's GnoVM), and every call site below
// is itself the sole crossing frame in its chain — no shared-helper
// reachable via multiple different realms' crossing paths.
func callerAddress() address {
	return unsaferealm.PreviousRealm().Address()
}

func validName(name string) bool {
	if name == "" || len(name) > MaxNameLen {
		return false
	}
	for _, c := range name {
		if c < 0x20 || c == 0x7f {
			return false
		}
	}
	return true
}

func validSymbol(symbol string) bool {
	if len(symbol) < MinSymbolLen || len(symbol) > MaxSymbolLen {
		return false
	}
	for _, c := range symbol {
		if !((c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9')) {
			return false
		}
	}
	return true
}

// New creates a brand-new fixed-supply token and mints the entire
// totalSupply to the caller in the same call. Panics if the symbol is
// already taken, or if any argument fails validation — there is no
// partial-creation state to worry about since Gno rolls back the whole
// call on panic.
func New(cur realm, name, symbol string, decimals int, totalSupply int64) {
	if !validName(name) {
		panic(ErrInvalidName)
	}
	if !validSymbol(symbol) {
		panic(ErrInvalidSymbol)
	}
	if decimals < 0 || decimals > MaxDecimals {
		panic(ErrInvalidDecimals)
	}
	if totalSupply <= 0 {
		panic(ErrInvalidSupply)
	}
	if instances.Has(symbol) {
		panic(ErrSymbolTaken)
	}

	creator := callerAddress()
	t := &token{
		name:        name,
		symbol:      symbol,
		decimals:    decimals,
		totalSupply: totalSupply,
		creator:     creator,
	}
	t.balances.Set(creator.String(), totalSupply)
	instances.Set(symbol, t)

	chain.Emit(
		TokenCreatedEvent,
		"symbol", symbol,
		"name", name,
		"creator", creator.String(),
		"totalSupply", strconv.FormatInt(totalSupply, 10),
	)
	chain.Emit(
		MintEvent,
		"symbol", symbol,
		"to", creator.String(),
		"amount", strconv.FormatInt(totalSupply, 10),
	)
}

func mustGetToken(symbol string) *token {
	v := instances.Get(symbol)
	if v == nil {
		panic(ErrUnknownSymbol)
	}
	return v.(*token)
}

/* -------------------- Reader (standard GRC20-recognizable shape, symbol-scoped) -------------------- */

func Name(symbol string) string       { return mustGetToken(symbol).name }
func Symbol(symbol string) string     { return mustGetToken(symbol).symbol }
func Decimals(symbol string) int      { return mustGetToken(symbol).decimals }
func TotalSupply(symbol string) int64 { return mustGetToken(symbol).totalSupply }
func Creator(symbol string) address   { return mustGetToken(symbol).creator }

func BalanceOf(symbol string, addr address) int64 {
	return mustGetToken(symbol).balanceOf(addr)
}

func Allowance(symbol string, owner, spender address) int64 {
	t := mustGetToken(symbol)
	v := t.allowances.Get(allowanceKey(owner, spender))
	if v == nil {
		return 0
	}
	return v.(int64)
}

func allowanceKey(owner, spender address) string {
	return owner.String() + ":" + spender.String()
}

// TokenCount reports how many distinct tokens this factory has created,
// across every symbol, since it was deployed.
func TokenCount() int {
	return instances.Size()
}

/* ------------------------------- Writes ---------------------------------- */

// Transfer moves amount of the named token from the caller to `to`.
func Transfer(cur realm, symbol string, to address, amount int64) error {
	return mustGetToken(symbol).transfer(callerAddress(), to, amount)
}

// Approve sets the amount spender is allowed to move on the caller's
// behalf for the named token, replacing any previous allowance
// (standard GRC20/ERC20 semantics — not additive).
func Approve(cur realm, symbol string, spender address, amount int64) error {
	t := mustGetToken(symbol)
	owner := callerAddress()
	if !spender.IsValid() {
		return ErrInvalidAddress
	}
	if amount < 0 {
		return ErrInvalidAmount
	}
	t.allowances.Set(allowanceKey(owner, spender), amount)
	chain.Emit(
		ApprovalEvent,
		"symbol", symbol,
		"owner", owner.String(),
		"spender", spender.String(),
		"amount", strconv.FormatInt(amount, 10),
	)
	return nil
}

// TransferFrom moves amount of the named token from `from` to `to`,
// spending part of the caller's allowance from `from`.
func TransferFrom(cur realm, symbol string, from, to address, amount int64) error {
	t := mustGetToken(symbol)
	spender := callerAddress()
	key := allowanceKey(from, spender)
	current := int64(0)
	if v := t.allowances.Get(key); v != nil {
		current = v.(int64)
	}
	if current < amount {
		return ErrInsufficientAllowance
	}
	if err := t.transfer(from, to, amount); err != nil {
		return err
	}
	t.allowances.Set(key, current-amount)
	return nil
}

func (t *token) balanceOf(addr address) int64 {
	v := t.balances.Get(addr.String())
	if v == nil {
		return 0
	}
	return v.(int64)
}

// transfer is the shared move-balance logic for both Transfer and
// TransferFrom, scoped to this one token instance — a bug here can
// never cross into a different symbol's balances/allowances trees,
// since each token owns its own.
func (t *token) transfer(from, to address, amount int64) error {
	if !to.IsValid() {
		return ErrInvalidAddress
	}
	if from == to {
		return ErrCannotTransferToSelf
	}
	if amount <= 0 {
		return ErrInvalidAmount
	}
	fromBal := t.balanceOf(from)
	if fromBal < amount {
		return ErrInsufficientBalance
	}
	// Sub64p/Add64p panic on overflow rather than silently wrapping —
	// defensive redundancy here (the fromBal < amount check above
	// already rules out underflow, and a single balance can never
	// exceed the token's own fixed totalSupply), matching the same
	// belt-and-suspenders pattern gno-nft-minter's grc721 package uses.
	t.balances.Set(from.String(), overflow.Sub64p(fromBal, amount))
	t.balances.Set(to.String(), overflow.Add64p(t.balanceOf(to), amount))
	chain.Emit(
		TransferEvent,
		"symbol", t.symbol,
		"from", from.String(),
		"to", to.String(),
		"amount", strconv.FormatInt(amount, 10),
	)
	return nil
}

/* ------------------------------- Render ---------------------------------- */

func Render(path string) string {
	if path == "" {
		var b strings.Builder
		b.WriteString("# Token Factory\n\n")
		b.WriteString(strconv.Itoa(instances.Size()) + " token(s) created.\n\n")
		instances.Iterate("", "", func(symbol string, v any) bool {
			t := v.(*token)
			b.WriteString("- **" + t.name + "** ($" + t.symbol + ") — created by " + t.creator.String() + "\n")
			return false
		})
		return b.String()
	}

	parts := strings.Split(path, "/")
	v := instances.Get(parts[0])
	if v == nil {
		return "404\n"
	}
	t := v.(*token)
	var b strings.Builder
	b.WriteString("# " + t.name + " ($" + t.symbol + ")\n\n")
	b.WriteString("* **Decimals**: " + strconv.Itoa(t.decimals) + "\n")
	b.WriteString("* **Total supply**: " + strconv.FormatInt(t.totalSupply, 10) + "\n")
	b.WriteString("* **Creator**: " + t.creator.String() + "\n")
	if len(parts) == 3 && parts[1] == "balance" {
		b.WriteString("* **" + parts[2] + " balance**: " + strconv.FormatInt(t.balanceOf(address(parts[2])), 10) + "\n")
	}
	return b.String()
}
