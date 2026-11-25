package grc1155

import (
	"strconv"
	"strings"
	"testing"

	"gno.land/p/nt/testutils/v0"
	"gno.land/p/nt/uassert/v0"
	"gno.land/p/nt/urequire/v0"
)

func mustBalanceOf(t *testing.T, tok *Token, owner address, tid TokenID) int64 {
	balance, err := tok.BalanceOf(owner, tid)
	urequire.NoError(t, err)
	return balance
}

// uassert.Equal has no slice support; these keep table assertions readable.
func equalTokenIDs(a, b []TokenID) bool {
	if len(a) != len(b) {
		return false
	}
	for i := range a {
		if a[i] != b[i] {
			return false
		}
	}
	return true
}

func equalInt64s(a, b []int64) bool {
	if len(a) != len(b) {
		return false
	}
	for i := range a {
		if a[i] != b[i] {
			return false
		}
	}
	return true
}

func equalStrings(a, b []string) bool {
	if len(a) != len(b) {
		return false
	}
	for i := range a {
		if a[i] != b[i] {
			return false
		}
	}
	return true
}

// newTestToken builds via same-realm cross (NewToken requires rlm.IsCurrent()).
func newTestToken(name, symbol, defaultURI string, rlm realm) (tok *Token, led *PrivateLedger) {
	func(cur realm) {
		tok, led = NewToken(name, symbol, defaultURI, 0, cur)
	}(cross(rlm))
	return
}

type mockExtension struct {
	mints, transfers, burns int
	lastMintTo              address
	lastMintID              TokenID
	lastMintAmount          int64
	lastTransferFrom        address
	lastTransferTo          address
	lastTransferID          TokenID
	lastTransferAmount      int64
	lastBurnFrom            address
	lastBurnID              TokenID
	lastBurnAmount          int64
	// journal records "kind:id:amount" per hook call, in firing order.
	journal []string
}

func (m *mockExtension) ExtensionKind() string { return "mock" }

func (m *mockExtension) OnMint(to address, tid TokenID, amount int64) {
	m.mints++
	m.lastMintTo = to
	m.lastMintID = tid
	m.lastMintAmount = amount
	m.journal = append(m.journal, "mint:"+tid.String()+":"+strconv.FormatInt(amount, 10))
}

func (m *mockExtension) OnTransfer(from, to address, tid TokenID, amount int64) {
	m.transfers++
	m.lastTransferFrom = from
	m.lastTransferTo = to
	m.lastTransferID = tid
	m.lastTransferAmount = amount
	m.journal = append(m.journal, "transfer:"+tid.String()+":"+strconv.FormatInt(amount, 10))
}

func (m *mockExtension) OnBurn(from address, tid TokenID, amount int64) {
	m.burns++
	m.lastBurnFrom = from
	m.lastBurnID = tid
	m.lastBurnAmount = amount
	m.journal = append(m.journal, "burn:"+tid.String()+":"+strconv.FormatInt(amount, 10))
}

// Value type holding a slice: uncomparable, so `==` on two of them is a runtime fault.
type journalExtension struct{ seen []TokenID }

func (e journalExtension) ExtensionKind() string { return "journal" }
func (e journalExtension) OnMint(to address, tid TokenID, amount int64) {
}
func (e journalExtension) OnTransfer(from, to address, tid TokenID, amount int64) {
}
func (e journalExtension) OnBurn(from address, tid TokenID, amount int64) {
}

var (
	alice = testutils.TestAddress("alice")
	bob   = testutils.TestAddress("bob")
	carl  = testutils.TestAddress("carl")
)

func TestNewToken(cur realm, t *testing.T) {
	tok, led := newTestToken("Forge", "FORGE", "item/{id}", cur)
	urequire.False(t, tok == nil, "token should not be nil")
	urequire.False(t, led == nil, "ledger should not be nil")

	uassert.Equal(t, "Forge", tok.GetName())
	uassert.Equal(t, "FORGE", tok.GetSymbol())
	uassert.Equal(t, int64(0), tok.TotalSupply("wood"))
	uassert.Equal(t, tok.ID(), led.ReadToken().ID())

	uassert.True(t, strings.HasSuffix(tok.ID(), ".FORGE"), "ID must end with .symbol")
	uassert.True(t, strings.HasPrefix(tok.ID(), "gno.land/"), "ID must begin with the origin pkg path")
	uassert.False(t, tok.Exists("wood"), "no token type exists before first mint")
}

func TestNewTokenIDNoSeqid(cur realm, t *testing.T) {
	// Unlike grc721 there is no seqid: the same realm building two tokens with
	// the same symbol gets identical IDs — the NewToken event is what makes
	// that detectable (see filetests).
	first, _ := newTestToken("Same", "DUP", "", cur)
	second, _ := newTestToken("Same", "DUP", "", cur)
	uassert.Equal(t, first.ID(), second.ID())
}

func TestNewTokenValidation(cur realm, t *testing.T) {
	longName := strings.Repeat("a", MaxNameLen+1)
	maxName := strings.Repeat("a", MaxNameLen)
	longSymbol := strings.Repeat("A", MaxSymbolLen+1)
	longURI := strings.Repeat("a", MaxURILen+1)
	maxURI := strings.Repeat("a", MaxURILen)

	tests := []struct {
		name       string
		tokenName  string
		symbol     string
		uri        string
		wantAbort  bool
		wantSubstr string
	}{
		{"valid name symbol uri succeeds", "Foo", "FOO", "item/{id}", false, ""},
		{"symbol with full slug charset succeeds", "Foo", "aZ9_-", "", false, ""},
		{"empty uri succeeds", "Foo", "FOO", "", false, ""},
		{"uri at max length succeeds", "Foo", "FOO", maxURI, false, ""},
		{"name at max length succeeds", maxName, "FOO", "", false, ""},
		{"empty name returns ErrInvalidName", "", "FOO", "", true, "invalid token name"},
		{"name over max length returns ErrInvalidName", longName, "FOO", "", true, "invalid token name"},
		{"name with low control char returns ErrInvalidName", "Foo\x01", "FOO", "", true, "invalid token name"},
		{"name with DEL control char returns ErrInvalidName", "Foo\x7f", "FOO", "", true, "invalid token name"},
		{"empty symbol returns ErrInvalidSymbol", "Foo", "", "", true, "invalid token symbol"},
		{"symbol over max length returns ErrInvalidSymbol", "Foo", longSymbol, "", true, "invalid token symbol"},
		{"symbol with space returns ErrInvalidSymbol", "Foo", "has space", "", true, "invalid token symbol"},
		{"symbol with dot returns ErrInvalidSymbol", "Foo", "FO.O", "", true, "invalid token symbol"},
		{"symbol with slash returns ErrInvalidSymbol", "Foo", "FO/O", "", true, "invalid token symbol"},
		{"uri over max length returns ErrInvalidURI", "Foo", "FOO", longURI, true, "invalid uri"},
		{"uri with control char returns ErrInvalidURI", "Foo", "FOO", "item/\x01{id}", true, "invalid uri"},
	}

	for _, tc := range tests {
		tc := tc
		t.Run(tc.name, func(t *testing.T) {
			if tc.wantAbort {
				urequire.AbortsContains(t, cur, tc.wantSubstr, func() {
					newTestToken(tc.tokenName, tc.symbol, tc.uri, cur)
				})
				return
			}
			tok, _ := newTestToken(tc.tokenName, tc.symbol, tc.uri, cur)
			uassert.Equal(t, tc.tokenName, tok.GetName())
			uassert.Equal(t, tc.symbol, tok.GetSymbol())
		})
	}
}

func TestNewTokenRejectsSpoofedRealm(cur realm, t *testing.T) {
	// Stale outer cur in a fresh frame → ErrSpoofedRealm.
	urequire.AbortsContains(t, cur, "rlm does not match the current crossing frame", func() {
		stale := cur
		func(cur realm) {
			NewToken("Foo", "FOO", "", 0, stale)
		}(cross(cur))
	})
}

func TestMint(cur realm, t *testing.T) {
	tests := []struct {
		name    string
		action  func(led *PrivateLedger) error
		wantErr error
		verify  func(t *testing.T, tok *Token, led *PrivateLedger)
	}{
		{
			name: "mint to valid address succeeds",
			action: func(led *PrivateLedger) error {
				return led.Mint(alice, "wood", 5)
			},
			wantErr: nil,
			verify: func(t *testing.T, tok *Token, led *PrivateLedger) {
				uassert.Equal(t, int64(5), tok.TotalSupply("wood"))
				uassert.Equal(t, int64(5), mustBalanceOf(t, tok, alice, "wood"))
				uassert.True(t, tok.Exists("wood"))
			},
		},
		{
			name: "mint same tid twice accumulates balance and supply",
			action: func(led *PrivateLedger) error {
				urequire.NoError(t, led.Mint(alice, "wood", 5))
				return led.Mint(alice, "wood", 3)
			},
			wantErr: nil,
			verify: func(t *testing.T, tok *Token, led *PrivateLedger) {
				uassert.Equal(t, int64(8), tok.TotalSupply("wood"))
				uassert.Equal(t, int64(8), mustBalanceOf(t, tok, alice, "wood"))
			},
		},
		{
			name: "mint to invalid address returns ErrInvalidAddress",
			action: func(led *PrivateLedger) error {
				return led.Mint(zeroAddress, "wood", 1)
			},
			wantErr: ErrInvalidAddress,
			verify: func(t *testing.T, tok *Token, led *PrivateLedger) {
				uassert.Equal(t, int64(0), tok.TotalSupply("wood"))
			},
		},
		{
			name: "mint with empty token id returns ErrInvalidTokenID",
			action: func(led *PrivateLedger) error {
				return led.Mint(alice, "", 1)
			},
			wantErr: ErrInvalidTokenID,
		},
		{
			name: "mint with colon token id returns ErrInvalidTokenID",
			action: func(led *PrivateLedger) error {
				return led.Mint(alice, "a:b", 1)
			},
			wantErr: ErrInvalidTokenID,
		},
		{
			name: "mint with spaced token id returns ErrInvalidTokenID",
			action: func(led *PrivateLedger) error {
				return led.Mint(alice, "a b", 1)
			},
			wantErr: ErrInvalidTokenID,
		},
		{
			name: "mint with overlong token id returns ErrInvalidTokenID",
			action: func(led *PrivateLedger) error {
				return led.Mint(alice, TokenID(strings.Repeat("a", MaxTokenIDLen+1)), 1)
			},
			wantErr: ErrInvalidTokenID,
		},
		{
			name: "mint with token id at max length succeeds",
			action: func(led *PrivateLedger) error {
				return led.Mint(alice, TokenID(strings.Repeat("a", MaxTokenIDLen)), 1)
			},
			wantErr: nil,
		},
		{
			name: "mint zero amount returns ErrInvalidAmount",
			action: func(led *PrivateLedger) error {
				return led.Mint(alice, "wood", 0)
			},
			wantErr: ErrInvalidAmount,
		},
		{
			name: "mint negative amount returns ErrInvalidAmount",
			action: func(led *PrivateLedger) error {
				return led.Mint(alice, "wood", -3)
			},
			wantErr: ErrInvalidAmount,
		},
		{
			name: "mint overflowing recipient balance returns ErrOverflow",
			action: func(led *PrivateLedger) error {
				urequire.NoError(t, led.Mint(alice, "wood", int64(^uint64(0)>>1)))
				return led.Mint(alice, "wood", 1)
			},
			wantErr: ErrOverflow,
			verify: func(t *testing.T, tok *Token, led *PrivateLedger) {
				uassert.Equal(t, int64(^uint64(0)>>1), mustBalanceOf(t, tok, alice, "wood"))
			},
		},
		{
			name: "mint overflowing supply returns ErrOverflow",
			action: func(led *PrivateLedger) error {
				urequire.NoError(t, led.Mint(alice, "wood", int64(^uint64(0)>>1)))
				return led.Mint(bob, "wood", 1)
			},
			wantErr: ErrOverflow,
			verify: func(t *testing.T, tok *Token, led *PrivateLedger) {
				uassert.Equal(t, int64(0), mustBalanceOf(t, tok, bob, "wood"))
				uassert.Equal(t, int64(^uint64(0)>>1), tok.TotalSupply("wood"))
			},
		},
	}

	for _, tc := range tests {
		tc := tc
		t.Run(tc.name, func(t *testing.T) {
			tok, led := newTestToken("Foo", "FOO", "item/{id}", cur)
			err := tc.action(led)
			if tc.wantErr == nil {
				uassert.NoError(t, err)
			} else {
				uassert.ErrorIs(t, err, tc.wantErr)
			}
			if tc.verify != nil {
				tc.verify(t, tok, led)
			}
		})
	}
}

func TestMintBatch(cur realm, t *testing.T) {
	tests := []struct {
		name    string
		to      address
		tids    []TokenID
		amounts []int64
		setup   func(led *PrivateLedger)
		wantErr error
		verify  func(t *testing.T, tok *Token, led *PrivateLedger)
	}{
		{
			name:    "batch mint of distinct ids succeeds",
			to:      alice,
			tids:    []TokenID{"wood", "ore"},
			amounts: []int64{5, 2},
			wantErr: nil,
			verify: func(t *testing.T, tok *Token, led *PrivateLedger) {
				uassert.Equal(t, int64(5), mustBalanceOf(t, tok, alice, "wood"))
				uassert.Equal(t, int64(2), mustBalanceOf(t, tok, alice, "ore"))
				uassert.Equal(t, int64(5), tok.TotalSupply("wood"))
				uassert.Equal(t, int64(2), tok.TotalSupply("ore"))
			},
		},
		{
			name:    "duplicate tids in one batch accumulate",
			to:      alice,
			tids:    []TokenID{"wood", "wood", "ore"},
			amounts: []int64{5, 7, 1},
			wantErr: nil,
			verify: func(t *testing.T, tok *Token, led *PrivateLedger) {
				uassert.Equal(t, int64(12), mustBalanceOf(t, tok, alice, "wood"))
				uassert.Equal(t, int64(12), tok.TotalSupply("wood"))
			},
		},
		{
			name:    "length mismatch returns ErrLengthMismatch",
			to:      alice,
			tids:    []TokenID{"wood", "ore"},
			amounts: []int64{1},
			wantErr: ErrLengthMismatch,
		},
		{
			name:    "empty batch returns ErrEmptyBatch",
			to:      alice,
			tids:    []TokenID{},
			amounts: []int64{},
			wantErr: ErrEmptyBatch,
		},
		{
			name: "batch over MaxBatchSize returns ErrBatchTooLarge",
			to:   alice,
			tids: func() []TokenID {
				ids := make([]TokenID, MaxBatchSize+1)
				for i := range ids {
					ids[i] = "wood"
				}
				return ids
			}(),
			amounts: func() []int64 {
				amounts := make([]int64, MaxBatchSize+1)
				for i := range amounts {
					amounts[i] = 1
				}
				return amounts
			}(),
			wantErr: ErrBatchTooLarge,
		},
		{
			name:    "batch at MaxBatchSize succeeds",
			to:      alice,
			tids:    func() []TokenID { return batchOf("wood", MaxBatchSize) }(),
			amounts: func() []int64 { return ones(MaxBatchSize) }(),
			wantErr: nil,
			verify: func(t *testing.T, tok *Token, led *PrivateLedger) {
				uassert.Equal(t, int64(MaxBatchSize), tok.TotalSupply("wood"))
			},
		},
		{
			name:    "invalid token id in batch returns ErrInvalidTokenID",
			to:      alice,
			tids:    []TokenID{"wood", "bad:id"},
			amounts: []int64{1, 1},
			wantErr: ErrInvalidTokenID,
		},
		{
			name:    "zero amount in batch returns ErrInvalidAmount",
			to:      alice,
			tids:    []TokenID{"wood", "ore"},
			amounts: []int64{1, 0},
			wantErr: ErrInvalidAmount,
		},
		{
			name:    "invalid recipient returns ErrInvalidAddress",
			to:      zeroAddress,
			tids:    []TokenID{"wood"},
			amounts: []int64{1},
			wantErr: ErrInvalidAddress,
		},
		{
			name:    "duplicate tids overflowing the sum return ErrOverflow",
			to:      alice,
			tids:    []TokenID{"wood", "wood"},
			amounts: []int64{int64(^uint64(0) >> 1), 1},
			wantErr: ErrOverflow,
		},
		{
			name:    "failing batch leaves zero state changes",
			to:      alice,
			tids:    []TokenID{"wood", "ore", "bad:id"},
			amounts: []int64{3, 2, 1},
			setup: func(led *PrivateLedger) {
				urequire.NoError(t, led.Mint(bob, "stone", 4))
			},
			wantErr: ErrInvalidTokenID,
			verify: func(t *testing.T, tok *Token, led *PrivateLedger) {
				uassert.Equal(t, int64(0), mustBalanceOf(t, tok, alice, "wood"))
				uassert.Equal(t, int64(0), mustBalanceOf(t, tok, alice, "ore"))
				uassert.False(t, tok.Exists("wood"))
				uassert.False(t, tok.Exists("ore"))
				uassert.Equal(t, int64(4), mustBalanceOf(t, tok, bob, "stone"))
				uassert.Equal(t, 1, led.balances.Size())
				uassert.Equal(t, 1, led.supplies.Size())
			},
		},
		{
			name:    "batch overflowing recipient balance returns ErrOverflow atomically",
			to:      alice,
			tids:    []TokenID{"wood"},
			amounts: []int64{1},
			setup: func(led *PrivateLedger) {
				urequire.NoError(t, led.Mint(alice, "wood", int64(^uint64(0)>>1)))
			},
			wantErr: ErrOverflow,
			verify: func(t *testing.T, tok *Token, led *PrivateLedger) {
				uassert.Equal(t, int64(^uint64(0)>>1), mustBalanceOf(t, tok, alice, "wood"))
			},
		},
	}

	for _, tc := range tests {
		tc := tc
		t.Run(tc.name, func(t *testing.T) {
			tok, led := newTestToken("Foo", "FOO", "item/{id}", cur)
			if tc.setup != nil {
				tc.setup(led)
			}
			err := led.MintBatch(tc.to, tc.tids, tc.amounts)
			if tc.wantErr == nil {
				uassert.NoError(t, err)
			} else {
				uassert.ErrorIs(t, err, tc.wantErr)
			}
			if tc.verify != nil {
				tc.verify(t, tok, led)
			}
		})
	}
}

func batchOf(id TokenID, n int) []TokenID {
	ids := make([]TokenID, n)
	for i := range ids {
		ids[i] = id
	}
	return ids
}

func ones(n int) []int64 {
	amounts := make([]int64, n)
	for i := range amounts {
		amounts[i] = 1
	}
	return amounts
}

func TestBurn(cur realm, t *testing.T) {
	tests := []struct {
		name    string
		action  func(led *PrivateLedger) error
		wantErr error
		verify  func(t *testing.T, tok *Token, led *PrivateLedger)
	}{
		{
			name: "burn reduces balance and supply and deletes zero entries",
			action: func(led *PrivateLedger) error {
				urequire.NoError(t, led.Mint(alice, "wood", 5))
				return led.Burn(alice, "wood", 2)
			},
			wantErr: nil,
			verify: func(t *testing.T, tok *Token, led *PrivateLedger) {
				uassert.Equal(t, int64(3), tok.TotalSupply("wood"))
				uassert.Equal(t, int64(3), mustBalanceOf(t, tok, alice, "wood"))
			},
		},
		{
			name: "burning the full balance removes balance and supply entries",
			action: func(led *PrivateLedger) error {
				urequire.NoError(t, led.Mint(alice, "wood", 5))
				return led.Burn(alice, "wood", 5)
			},
			wantErr: nil,
			verify: func(t *testing.T, tok *Token, led *PrivateLedger) {
				uassert.Equal(t, int64(0), tok.TotalSupply("wood"))
				uassert.Equal(t, int64(0), mustBalanceOf(t, tok, alice, "wood"))
				uassert.False(t, tok.Exists("wood"))
				uassert.Equal(t, 0, led.balances.Size())
				uassert.Equal(t, 0, led.supplies.Size())
			},
		},
		{
			name: "burn with invalid address returns ErrInvalidAddress",
			action: func(led *PrivateLedger) error {
				urequire.NoError(t, led.Mint(alice, "wood", 5))
				return led.Burn(zeroAddress, "wood", 1)
			},
			wantErr: ErrInvalidAddress,
		},
		{
			name: "burn exceeding balance returns ErrInsufficientBalance",
			action: func(led *PrivateLedger) error {
				urequire.NoError(t, led.Mint(alice, "wood", 5))
				return led.Burn(alice, "wood", 6)
			},
			wantErr: ErrInsufficientBalance,
			verify: func(t *testing.T, tok *Token, led *PrivateLedger) {
				uassert.Equal(t, int64(5), mustBalanceOf(t, tok, alice, "wood"))
			},
		},
		{
			name: "burn of unknown tid returns ErrInsufficientBalance",
			action: func(led *PrivateLedger) error {
				return led.Burn(alice, "wood", 1)
			},
			wantErr: ErrInsufficientBalance,
		},
		{
			name: "burn zero amount returns ErrInvalidAmount",
			action: func(led *PrivateLedger) error {
				urequire.NoError(t, led.Mint(alice, "wood", 5))
				return led.Burn(alice, "wood", 0)
			},
			wantErr: ErrInvalidAmount,
		},
	}

	for _, tc := range tests {
		tc := tc
		t.Run(tc.name, func(t *testing.T) {
			tok, led := newTestToken("Foo", "FOO", "item/{id}", cur)
			err := tc.action(led)
			if tc.wantErr == nil {
				uassert.NoError(t, err)
			} else {
				uassert.ErrorIs(t, err, tc.wantErr)
			}
			if tc.verify != nil {
				tc.verify(t, tok, led)
			}
		})
	}
}

func TestBurnBatch(cur realm, t *testing.T) {
	tests := []struct {
		name    string
		setup   func(led *PrivateLedger)
		from    address
		tids    []TokenID
		amounts []int64
		wantErr error
		verify  func(t *testing.T, tok *Token, led *PrivateLedger)
	}{
		{
			name: "batch burn of distinct ids succeeds",
			setup: func(led *PrivateLedger) {
				urequire.NoError(t, led.Mint(alice, "wood", 5))
				urequire.NoError(t, led.Mint(alice, "ore", 3))
			},
			from:    alice,
			tids:    []TokenID{"wood", "ore"},
			amounts: []int64{2, 1},
			wantErr: nil,
			verify: func(t *testing.T, tok *Token, led *PrivateLedger) {
				uassert.Equal(t, int64(3), mustBalanceOf(t, tok, alice, "wood"))
				uassert.Equal(t, int64(2), mustBalanceOf(t, tok, alice, "ore"))
				uassert.Equal(t, int64(3), tok.TotalSupply("wood"))
				uassert.Equal(t, int64(2), tok.TotalSupply("ore"))
			},
		},
		{
			name: "duplicate tids accumulate against the balance",
			setup: func(led *PrivateLedger) {
				urequire.NoError(t, led.Mint(alice, "wood", 10))
			},
			from:    alice,
			tids:    []TokenID{"wood", "wood"},
			amounts: []int64{4, 6},
			wantErr: nil,
			verify: func(t *testing.T, tok *Token, led *PrivateLedger) {
				uassert.Equal(t, int64(0), mustBalanceOf(t, tok, alice, "wood"))
				uassert.False(t, tok.Exists("wood"))
			},
		},
		{
			name: "duplicate tids exceeding balance fail atomically",
			setup: func(led *PrivateLedger) {
				urequire.NoError(t, led.Mint(alice, "wood", 10))
				urequire.NoError(t, led.Mint(alice, "ore", 2))
			},
			from:    alice,
			tids:    []TokenID{"wood", "wood", "ore"},
			amounts: []int64{6, 5, 1},
			wantErr: ErrInsufficientBalance,
			verify: func(t *testing.T, tok *Token, led *PrivateLedger) {
				// wood needs 11 > 10: the whole batch must be a no-op,
				// including the ore entry that alone would have succeeded.
				uassert.Equal(t, int64(10), mustBalanceOf(t, tok, alice, "wood"))
				uassert.Equal(t, int64(2), mustBalanceOf(t, tok, alice, "ore"))
				uassert.Equal(t, int64(10), tok.TotalSupply("wood"))
				uassert.Equal(t, int64(2), tok.TotalSupply("ore"))
				uassert.Equal(t, 2, led.balances.Size())
			},
		},
		{
			name:    "length mismatch returns ErrLengthMismatch",
			from:    alice,
			tids:    []TokenID{"wood"},
			amounts: []int64{1, 2},
			wantErr: ErrLengthMismatch,
		},
		{
			name:    "empty batch returns ErrEmptyBatch",
			from:    alice,
			tids:    []TokenID{},
			amounts: []int64{},
			wantErr: ErrEmptyBatch,
		},
		{
			name:    "invalid token id returns ErrInvalidTokenID",
			from:    alice,
			tids:    []TokenID{"wood", "a b"},
			amounts: []int64{1, 1},
			wantErr: ErrInvalidTokenID,
		},
		{
			name:    "invalid from address returns ErrInvalidAddress",
			from:    zeroAddress,
			tids:    []TokenID{"wood"},
			amounts: []int64{1},
			wantErr: ErrInvalidAddress,
		},
	}

	for _, tc := range tests {
		tc := tc
		t.Run(tc.name, func(t *testing.T) {
			tok, led := newTestToken("Foo", "FOO", "item/{id}", cur)
			if tc.setup != nil {
				tc.setup(led)
			}
			err := led.BurnBatch(tc.from, tc.tids, tc.amounts)
			if tc.wantErr == nil {
				uassert.NoError(t, err)
			} else {
				uassert.ErrorIs(t, err, tc.wantErr)
			}
			if tc.verify != nil {
				tc.verify(t, tok, led)
			}
		})
	}
}

func TestTransferFrom(cur realm, t *testing.T) {
	tests := []struct {
		name    string
		setup   func(led *PrivateLedger)
		spender address
		from    address
		to      address
		tid     TokenID
		amount  int64
		wantErr error
		verify  func(t *testing.T, tok *Token, led *PrivateLedger)
	}{
		{
			name: "owner transfers own tokens",
			setup: func(led *PrivateLedger) {
				urequire.NoError(t, led.Mint(alice, "wood", 5))
			},
			spender: alice,
			from:    alice,
			to:      bob,
			tid:     "wood",
			amount:  2,
			wantErr: nil,
			verify: func(t *testing.T, tok *Token, led *PrivateLedger) {
				uassert.Equal(t, int64(3), mustBalanceOf(t, tok, alice, "wood"))
				uassert.Equal(t, int64(2), mustBalanceOf(t, tok, bob, "wood"))
				uassert.Equal(t, int64(5), tok.TotalSupply("wood"))
			},
		},
		{
			name: "approved operator transfers owner's tokens",
			setup: func(led *PrivateLedger) {
				urequire.NoError(t, led.Mint(alice, "wood", 5))
				urequire.NoError(t, led.SetApprovalForAll(alice, bob, true))
			},
			spender: bob,
			from:    alice,
			to:      carl,
			tid:     "wood",
			amount:  2,
			wantErr: nil,
			verify: func(t *testing.T, tok *Token, led *PrivateLedger) {
				uassert.Equal(t, int64(3), mustBalanceOf(t, tok, alice, "wood"))
				uassert.Equal(t, int64(2), mustBalanceOf(t, tok, carl, "wood"))
			},
		},
		{
			name: "unauthorized spender returns ErrCallerIsNotOwnerOrApproved",
			setup: func(led *PrivateLedger) {
				urequire.NoError(t, led.Mint(alice, "wood", 5))
			},
			spender: bob,
			from:    alice,
			to:      carl,
			tid:     "wood",
			amount:  1,
			wantErr: ErrCallerIsNotOwnerOrApproved,
			verify: func(t *testing.T, tok *Token, led *PrivateLedger) {
				uassert.Equal(t, int64(5), mustBalanceOf(t, tok, alice, "wood"))
			},
		},
		{
			name:    "spender on empty from returns ErrCallerIsNotOwnerOrApproved",
			spender: alice,
			from:    bob,
			to:      carl,
			tid:     "wood",
			amount:  1,
			wantErr: ErrCallerIsNotOwnerOrApproved,
		},
		{
			name: "transfer exceeding balance returns ErrInsufficientBalance",
			setup: func(led *PrivateLedger) {
				urequire.NoError(t, led.Mint(alice, "wood", 5))
			},
			spender: alice,
			from:    alice,
			to:      bob,
			tid:     "wood",
			amount:  6,
			wantErr: ErrInsufficientBalance,
			verify: func(t *testing.T, tok *Token, led *PrivateLedger) {
				uassert.Equal(t, int64(5), mustBalanceOf(t, tok, alice, "wood"))
				uassert.Equal(t, int64(0), mustBalanceOf(t, tok, bob, "wood"))
			},
		},
		{
			name: "transfer to self returns ErrCannotTransferToSelf",
			setup: func(led *PrivateLedger) {
				urequire.NoError(t, led.Mint(alice, "wood", 5))
			},
			spender: alice,
			from:    alice,
			to:      alice,
			tid:     "wood",
			amount:  1,
			wantErr: ErrCannotTransferToSelf,
		},
		{
			name: "transfer from invalid address returns ErrInvalidAddress",
			setup: func(led *PrivateLedger) {
				urequire.NoError(t, led.Mint(alice, "wood", 5))
			},
			spender: alice,
			from:    alice,
			to:      zeroAddress,
			tid:     "wood",
			amount:  1,
			wantErr: ErrInvalidAddress,
		},
		{
			name: "transfer with invalid token id returns ErrInvalidTokenID",
			setup: func(led *PrivateLedger) {
				urequire.NoError(t, led.Mint(alice, "wood", 5))
			},
			spender: alice,
			from:    alice,
			to:      bob,
			tid:     "a:b",
			amount:  1,
			wantErr: ErrInvalidTokenID,
		},
		{
			name: "transfer zero amount returns ErrInvalidAmount",
			setup: func(led *PrivateLedger) {
				urequire.NoError(t, led.Mint(alice, "wood", 5))
			},
			spender: alice,
			from:    alice,
			to:      bob,
			tid:     "wood",
			amount:  0,
			wantErr: ErrInvalidAmount,
		},
	}

	for _, tc := range tests {
		tc := tc
		t.Run(tc.name, func(t *testing.T) {
			tok, led := newTestToken("Foo", "FOO", "item/{id}", cur)
			if tc.setup != nil {
				tc.setup(led)
			}
			err := led.TransferFrom(tc.spender, tc.from, tc.to, tc.tid, tc.amount)
			if tc.wantErr == nil {
				uassert.NoError(t, err)
			} else {
				uassert.ErrorIs(t, err, tc.wantErr)
			}
			if tc.verify != nil {
				tc.verify(t, tok, led)
			}
		})
	}
}

func TestBatchTransferFrom(cur realm, t *testing.T) {
	tests := []struct {
		name    string
		setup   func(led *PrivateLedger)
		spender address
		from    address
		to      address
		tids    []TokenID
		amounts []int64
		wantErr error
		verify  func(t *testing.T, tok *Token, led *PrivateLedger)
	}{
		{
			name: "batch transfer of distinct ids succeeds",
			setup: func(led *PrivateLedger) {
				urequire.NoError(t, led.Mint(alice, "wood", 5))
				urequire.NoError(t, led.Mint(alice, "ore", 3))
			},
			spender: alice,
			from:    alice,
			to:      bob,
			tids:    []TokenID{"wood", "ore"},
			amounts: []int64{2, 1},
			wantErr: nil,
			verify: func(t *testing.T, tok *Token, led *PrivateLedger) {
				uassert.Equal(t, int64(3), mustBalanceOf(t, tok, alice, "wood"))
				uassert.Equal(t, int64(2), mustBalanceOf(t, tok, alice, "ore"))
				uassert.Equal(t, int64(2), mustBalanceOf(t, tok, bob, "wood"))
				uassert.Equal(t, int64(1), mustBalanceOf(t, tok, bob, "ore"))
			},
		},
		{
			name: "duplicate tids accumulate against sender balance",
			setup: func(led *PrivateLedger) {
				urequire.NoError(t, led.Mint(alice, "wood", 10))
			},
			spender: alice,
			from:    alice,
			to:      bob,
			tids:    []TokenID{"wood", "wood"},
			amounts: []int64{4, 6},
			wantErr: nil,
			verify: func(t *testing.T, tok *Token, led *PrivateLedger) {
				uassert.Equal(t, int64(0), mustBalanceOf(t, tok, alice, "wood"))
				uassert.Equal(t, int64(10), mustBalanceOf(t, tok, bob, "wood"))
			},
		},
		{
			name: "duplicate tids exceeding balance fail with zero state changes",
			setup: func(led *PrivateLedger) {
				urequire.NoError(t, led.Mint(alice, "wood", 10))
				urequire.NoError(t, led.Mint(alice, "ore", 2))
			},
			spender: alice,
			from:    alice,
			to:      bob,
			tids:    []TokenID{"wood", "wood", "ore"},
			amounts: []int64{6, 5, 1},
			wantErr: ErrInsufficientBalance,
			verify: func(t *testing.T, tok *Token, led *PrivateLedger) {
				uassert.Equal(t, int64(10), mustBalanceOf(t, tok, alice, "wood"))
				uassert.Equal(t, int64(2), mustBalanceOf(t, tok, alice, "ore"))
				uassert.Equal(t, int64(0), mustBalanceOf(t, tok, bob, "wood"))
				uassert.Equal(t, int64(0), mustBalanceOf(t, tok, bob, "ore"))
				uassert.Equal(t, 2, led.balances.Size())
			},
		},
		{
			name: "unauthorized batch spender returns ErrCallerIsNotOwnerOrApproved",
			setup: func(led *PrivateLedger) {
				urequire.NoError(t, led.Mint(alice, "wood", 5))
			},
			spender: bob,
			from:    alice,
			to:      carl,
			tids:    []TokenID{"wood"},
			amounts: []int64{1},
			wantErr: ErrCallerIsNotOwnerOrApproved,
		},
		{
			name: "batch transfer to self returns ErrCannotTransferToSelf",
			setup: func(led *PrivateLedger) {
				urequire.NoError(t, led.Mint(alice, "wood", 5))
			},
			spender: alice,
			from:    alice,
			to:      alice,
			tids:    []TokenID{"wood"},
			amounts: []int64{1},
			wantErr: ErrCannotTransferToSelf,
		},
		{
			name:    "length mismatch returns ErrLengthMismatch",
			spender: alice,
			from:    alice,
			to:      bob,
			tids:    []TokenID{"wood", "ore"},
			amounts: []int64{1},
			wantErr: ErrLengthMismatch,
		},
		{
			name:    "empty batch returns ErrEmptyBatch",
			spender: alice,
			from:    alice,
			to:      bob,
			tids:    []TokenID{},
			amounts: []int64{},
			wantErr: ErrEmptyBatch,
		},
		{
			name: "batch over MaxBatchSize returns ErrBatchTooLarge",
			setup: func(led *PrivateLedger) {
				urequire.NoError(t, led.Mint(alice, "wood", int64(MaxBatchSize)+1))
			},
			spender: alice,
			from:    alice,
			to:      bob,
			tids:    batchOf("wood", MaxBatchSize+1),
			amounts: ones(MaxBatchSize + 1),
			wantErr: ErrBatchTooLarge,
		},
		{
			name: "invalid token id returns ErrInvalidTokenID",
			setup: func(led *PrivateLedger) {
				urequire.NoError(t, led.Mint(alice, "wood", 5))
			},
			spender: alice,
			from:    alice,
			to:      bob,
			tids:    []TokenID{"wood", "bad id"},
			amounts: []int64{1, 1},
			wantErr: ErrInvalidTokenID,
		},
	}

	for _, tc := range tests {
		tc := tc
		t.Run(tc.name, func(t *testing.T) {
			tok, led := newTestToken("Foo", "FOO", "item/{id}", cur)
			if tc.setup != nil {
				tc.setup(led)
			}
			err := led.BatchTransferFrom(tc.spender, tc.from, tc.to, tc.tids, tc.amounts)
			if tc.wantErr == nil {
				uassert.NoError(t, err)
			} else {
				uassert.ErrorIs(t, err, tc.wantErr)
			}
			if tc.verify != nil {
				tc.verify(t, tok, led)
			}
		})
	}
}

func TestSetApprovalForAll(cur realm, t *testing.T) {
	tests := []struct {
		name     string
		owner    address
		operator address
		approved bool
		preGrant bool
		wantErr  error
		verify   func(t *testing.T, tok *Token, led *PrivateLedger)
	}{
		{
			name:     "grant operator approval",
			owner:    alice,
			operator: bob,
			approved: true,
			wantErr:  nil,
			verify: func(t *testing.T, tok *Token, led *PrivateLedger) {
				uassert.True(t, tok.IsApprovedForAll(alice, bob))
			},
		},
		{
			name:     "revoke operator approval releases the node",
			owner:    alice,
			operator: bob,
			approved: false,
			preGrant: true,
			wantErr:  nil,
			verify: func(t *testing.T, tok *Token, led *PrivateLedger) {
				uassert.False(t, tok.IsApprovedForAll(alice, bob))
				uassert.Equal(t, 0, led.operatorApprovals.Size())
			},
		},
		{
			name:     "revoke without a prior grant stores nothing",
			owner:    alice,
			operator: bob,
			approved: false,
			wantErr:  nil,
		},
		{
			name:     "invalid operator returns ErrInvalidAddress",
			owner:    alice,
			operator: zeroAddress,
			approved: true,
			wantErr:  ErrInvalidAddress,
		},
		{
			name:     "invalid owner returns ErrInvalidAddress",
			owner:    zeroAddress,
			operator: bob,
			approved: true,
			wantErr:  ErrInvalidAddress,
		},
		{
			name:     "owner equals operator returns ErrApprovalToCurrentOwner",
			owner:    alice,
			operator: alice,
			approved: true,
			wantErr:  ErrApprovalToCurrentOwner,
		},
	}

	for _, tc := range tests {
		tc := tc
		t.Run(tc.name, func(t *testing.T) {
			tok, led := newTestToken("Foo", "FOO", "item/{id}", cur)
			if tc.preGrant {
				urequire.NoError(t, led.SetApprovalForAll(alice, bob, true))
			}
			err := led.SetApprovalForAll(tc.owner, tc.operator, tc.approved)
			if tc.wantErr == nil {
				uassert.NoError(t, err)
			} else {
				uassert.ErrorIs(t, err, tc.wantErr)
			}
			if tc.verify != nil {
				tc.verify(t, tok, led)
			}
		})
	}
}

func TestOperatorApprovalFlow(cur realm, t *testing.T) {
	tok, led := newTestToken("Foo", "FOO", "item/{id}", cur)
	urequire.NoError(t, led.Mint(alice, "wood", 5))

	// Approve, transfer as operator, revoke, transfer fails.
	urequire.NoError(t, led.SetApprovalForAll(alice, bob, true))
	uassert.True(t, tok.IsApprovedForAll(alice, bob))
	urequire.NoError(t, led.TransferFrom(bob, alice, carl, "wood", 2))
	uassert.Equal(t, int64(2), mustBalanceOf(t, tok, carl, "wood"))

	urequire.NoError(t, led.SetApprovalForAll(alice, bob, false))
	uassert.False(t, tok.IsApprovedForAll(alice, bob))
	uassert.ErrorIs(t, led.TransferFrom(bob, alice, carl, "wood", 1), ErrCallerIsNotOwnerOrApproved)
}

func TestURI(cur realm, t *testing.T) {
	tok, led := newTestToken("Foo", "FOO", "item/{id}", cur)

	// Default template substitutes every {id}.
	uassert.Equal(t, "item/wood", tok.URI("wood"))

	// A template without {id} returns itself for every tid.
	_, led2 := newTestToken("Bar", "BAR", "static", cur)
	uassert.Equal(t, "static", led2.ReadToken().URI("wood"))
	uassert.Equal(t, "static", led2.ReadToken().URI("ore"))

	// Per-token override wins over the template.
	urequire.NoError(t, led.SetURI("wood", "wood-special"))
	uassert.Equal(t, "wood-special", tok.URI("wood"))
	uassert.Equal(t, "item/ore", tok.URI("ore"))

	// Empty override clears back to the template.
	urequire.NoError(t, led.SetURI("wood", ""))
	uassert.Equal(t, "item/wood", tok.URI("wood"))

	// SetDefaultURI changes the template for ids without overrides.
	urequire.NoError(t, led.SetDefaultURI("new/{id}"))
	uassert.Equal(t, "new/wood", tok.URI("wood"))

	// Overrides survive a default change.
	urequire.NoError(t, led.SetURI("ore", "ore-pin"))
	urequire.NoError(t, led.SetDefaultURI("other/{id}"))
	uassert.Equal(t, "ore-pin", tok.URI("ore"))
	uassert.Equal(t, "other/wood", tok.URI("wood"))
}

func TestURIValidation(cur realm, t *testing.T) {
	_, led := newTestToken("Foo", "FOO", "item/{id}", cur)

	tests := []struct {
		name    string
		fn      func() error
		wantErr error
	}{
		{"SetURI with invalid tid returns ErrInvalidTokenID", func() error {
			return led.SetURI("a:b", "x")
		}, ErrInvalidTokenID},
		{"SetURI with overlong uri returns ErrInvalidURI", func() error {
			return led.SetURI("wood", strings.Repeat("a", MaxURILen+1))
		}, ErrInvalidURI},
		{"SetURI with control char returns ErrInvalidURI", func() error {
			return led.SetURI("wood", "bad\x01uri")
		}, ErrInvalidURI},
		{"SetURI at max length succeeds", func() error {
			return led.SetURI("wood", strings.Repeat("a", MaxURILen))
		}, nil},
		{"SetDefaultURI with control char returns ErrInvalidURI", func() error {
			return led.SetDefaultURI("bad\x7furi")
		}, ErrInvalidURI},
		{"SetDefaultURI empty succeeds", func() error {
			return led.SetDefaultURI("")
		}, nil},
	}

	for _, tc := range tests {
		tc := tc
		t.Run(tc.name, func(t *testing.T) {
			err := tc.fn()
			if tc.wantErr == nil {
				uassert.NoError(t, err)
			} else {
				uassert.ErrorIs(t, err, tc.wantErr)
			}
		})
	}
}

func TestBalanceOfBatch(cur realm, t *testing.T) {
	tok, led := newTestToken("Foo", "FOO", "item/{id}", cur)
	urequire.NoError(t, led.Mint(alice, "wood", 5))
	urequire.NoError(t, led.Mint(bob, "ore", 2))

	tests := []struct {
		name    string
		owners  []address
		tids    []TokenID
		want    []int64
		wantErr error
	}{
		{
			name:   "batch balances across owners and ids",
			owners: []address{alice, bob, carl},
			tids:   []TokenID{"wood", "ore", "wood"},
			want:   []int64{5, 2, 0},
		},
		{
			name:    "length mismatch returns ErrLengthMismatch",
			owners:  []address{alice},
			tids:    []TokenID{"wood", "ore"},
			wantErr: ErrLengthMismatch,
		},
		{
			name:    "empty batch returns ErrEmptyBatch",
			owners:  []address{},
			tids:    []TokenID{},
			wantErr: ErrEmptyBatch,
		},
		{
			name:    "over MaxBatchSize returns ErrBatchTooLarge",
			owners:  batchAddrs(MaxBatchSize+1, alice),
			tids:    batchOf("wood", MaxBatchSize+1),
			wantErr: ErrBatchTooLarge,
		},
		{
			name:    "invalid owner returns ErrInvalidAddress",
			owners:  []address{alice, zeroAddress},
			tids:    []TokenID{"wood", "ore"},
			wantErr: ErrInvalidAddress,
		},
	}

	for _, tc := range tests {
		tc := tc
		t.Run(tc.name, func(t *testing.T) {
			got, err := tok.BalanceOfBatch(tc.owners, tc.tids)
			if tc.wantErr != nil {
				uassert.ErrorIs(t, err, tc.wantErr)
				return
			}
			urequire.NoError(t, err)
			uassert.True(t, equalInt64s(tc.want, got))
		})
	}
}

func batchAddrs(n int, addr address) []address {
	addrs := make([]address, n)
	for i := range addrs {
		addrs[i] = addr
	}
	return addrs
}

func TestHoldingsAndTokenIDs(cur realm, t *testing.T) {
	tok, led := newTestToken("Foo", "FOO", "item/{id}", cur)
	urequire.NoError(t, led.Mint(alice, "wood", 5))
	urequire.NoError(t, led.Mint(alice, "ore", 3))
	urequire.NoError(t, led.Mint(alice, "ingot", 1))
	urequire.NoError(t, led.Mint(bob, "wood", 2))

	t.Run("HoldingsOf returns sorted id/balance pairs", func(t *testing.T) {
		tids, bals := tok.HoldingsOf(alice, 0, 50)
		uassert.True(t, equalTokenIDs([]TokenID{"ingot", "ore", "wood"}, tids))
		uassert.True(t, equalInt64s([]int64{1, 3, 5}, bals))
	})

	t.Run("HoldingsOf offset skips entries", func(t *testing.T) {
		tids, bals := tok.HoldingsOf(alice, 1, 50)
		uassert.True(t, equalTokenIDs([]TokenID{"ore", "wood"}, tids))
		uassert.True(t, equalInt64s([]int64{3, 5}, bals))
	})

	t.Run("HoldingsOf limit bounds the page", func(t *testing.T) {
		tids, _ := tok.HoldingsOf(alice, 0, 2)
		uassert.True(t, equalTokenIDs([]TokenID{"ingot", "ore"}, tids))
	})

	t.Run("HoldingsOf limit is clamped to maxPageSize", func(t *testing.T) {
		tids, _ := tok.HoldingsOf(alice, 0, 1000)
		uassert.Equal(t, 3, len(tids))
	})

	t.Run("HoldingsOf non-positive limit yields nothing", func(t *testing.T) {
		tids, bals := tok.HoldingsOf(alice, 0, 0)
		uassert.Equal(t, 0, len(tids))
		uassert.Equal(t, 0, len(bals))
	})

	t.Run("HoldingsOf offset past end yields nothing", func(t *testing.T) {
		tids, _ := tok.HoldingsOf(alice, 99, 10)
		uassert.Equal(t, 0, len(tids))
	})

	t.Run("HoldingsOf invalid owner yields nothing", func(t *testing.T) {
		tids, _ := tok.HoldingsOf(zeroAddress, 0, 10)
		uassert.Equal(t, 0, len(tids))
	})

	t.Run("HoldingsOf only sees the owner's own range", func(t *testing.T) {
		tids, _ := tok.HoldingsOf(bob, 0, 50)
		uassert.True(t, equalTokenIDs([]TokenID{"wood"}, tids))
	})

	t.Run("TokenIDs returns sorted live ids", func(t *testing.T) {
		uassert.True(t, equalTokenIDs([]TokenID{"ingot", "ore", "wood"}, tok.TokenIDs(0, 50)))
	})

	t.Run("TokenIDs offset and limit paginate", func(t *testing.T) {
		uassert.True(t, equalTokenIDs([]TokenID{"ore"}, tok.TokenIDs(1, 1)))
		uassert.True(t, equalTokenIDs([]TokenID{"wood"}, tok.TokenIDs(2, 1)))
	})

	t.Run("TokenIDs drops ids whose supply hit zero", func(t *testing.T) {
		urequire.NoError(t, led.Burn(alice, "ingot", 1))
		uassert.True(t, equalTokenIDs([]TokenID{"ore", "wood"}, tok.TokenIDs(0, 50)))
		uassert.False(t, tok.Exists("ingot"))
	})
}

// TestHoldingsAfter covers cursor pagination: the range seek lands directly
// after "owner:after", so pages cost O(log n + page) no matter how deep the
// cursor sits. Empty after starts from the first holding; an out-of-charset
// after yields nil, nil.
func TestHoldingsAfter(cur realm, t *testing.T) {
	tok, led := newTestToken("Foo", "FOO", "item/{id}", cur)

	// Five distinct ids so cursor pages of two span more than one page.
	for _, tid := range []TokenID{"axe", "bow", "club", "dagger", "emerald"} {
		urequire.NoError(t, led.Mint(alice, tid, 1))
	}
	urequire.NoError(t, led.Mint(bob, "zed", 7))

	t.Run("empty after returns the first page", func(t *testing.T) {
		tids, bals := tok.HoldingsAfter(alice, "", 2)
		uassert.True(t, equalTokenIDs([]TokenID{"axe", "bow"}, tids))
		uassert.True(t, equalInt64s([]int64{1, 1}, bals))
	})

	t.Run("cursor walks every page in order", func(t *testing.T) {
		var got []TokenID
		after := TokenID("")
		for i := 0; i < 3; i++ {
			tids, _ := tok.HoldingsAfter(alice, after, 2)
			uassert.True(t, len(tids) > 0)
			got = append(got, tids...)
			after = tids[len(tids)-1]
		}
		uassert.True(t, equalTokenIDs(
			[]TokenID{"axe", "bow", "club", "dagger", "emerald"}, got))
	})

	t.Run("cursor past the last holding yields nothing", func(t *testing.T) {
		tids, bals := tok.HoldingsAfter(alice, "emerald", 10)
		uassert.Equal(t, 0, len(tids))
		uassert.Equal(t, 0, len(bals))
	})

	t.Run("cursor on a tid the owner does not hold still lands correctly", func(t *testing.T) {
		// "crossbow" sorts between "club" and "dagger" but alice holds neither.
		tids, _ := tok.HoldingsAfter(alice, "crossbow", 10)
		uassert.True(t, equalTokenIDs([]TokenID{"dagger", "emerald"}, tids))
	})

	t.Run("invalid non-empty after yields nil", func(t *testing.T) {
		tids, bals := tok.HoldingsAfter(alice, "bad:id", 10)
		uassert.Equal(t, 0, len(tids))
		uassert.Equal(t, 0, len(bals))
		tids, bals = tok.HoldingsAfter(alice, TokenID("x](y)"), 10)
		uassert.Equal(t, 0, len(tids))
		uassert.Equal(t, 0, len(bals))
	})

	t.Run("limit is clamped and non-positive limit yields nothing", func(t *testing.T) {
		tids, _ := tok.HoldingsAfter(alice, "", 1000)
		uassert.Equal(t, 5, len(tids))
		tids, _ = tok.HoldingsAfter(alice, "", 0)
		uassert.Equal(t, 0, len(tids))
	})

	t.Run("invalid owner yields nil", func(t *testing.T) {
		tids, _ := tok.HoldingsAfter(zeroAddress, "", 10)
		uassert.Equal(t, 0, len(tids))
	})

	t.Run("other owner's range is unaffected", func(t *testing.T) {
		tids, bals := tok.HoldingsAfter(bob, "", 10)
		uassert.True(t, equalTokenIDs([]TokenID{"zed"}, tids))
		uassert.True(t, equalInt64s([]int64{7}, bals))
	})
}

// TestUppercaseAddressRejected covers the bech32 uppercase-canonical hole:
// an all-uppercase address passes IsValid() but is a different ledger key no
// frame-derived identity can match, so every address-taking path must reject
// it as ErrInvalidAddress (ImpersonateTeller panics).
func TestUppercaseAddressRejected(cur realm, t *testing.T) {
	tok, led := newTestToken("Foo", "FOO", "item/{id}", cur)
	urequire.NoError(t, led.Mint(alice, "wood", 5))

	upper := address(strings.ToUpper(alice.String()))
	// Sanity: bech32 accepts the uppercase form — this is exactly why the
	// lowercase-canonical check exists.
	uassert.True(t, upper.IsValid())

	t.Run("mint to uppercase returns ErrInvalidAddress", func(t *testing.T) {
		uassert.ErrorIs(t, led.Mint(upper, "ore", 1), ErrInvalidAddress)
		uassert.ErrorIs(t, led.MintBatch(upper,
			[]TokenID{"ore"}, []int64{1}), ErrInvalidAddress)
	})

	t.Run("burn from uppercase returns ErrInvalidAddress", func(t *testing.T) {
		uassert.ErrorIs(t, led.Burn(upper, "wood", 1), ErrInvalidAddress)
		uassert.ErrorIs(t, led.BurnBatch(upper,
			[]TokenID{"wood"}, []int64{1}), ErrInvalidAddress)
	})

	t.Run("transfer involving uppercase returns ErrInvalidAddress", func(t *testing.T) {
		// alice -> UPPER(alice) would otherwise bypass from != to and strand
		// her own tokens under a key no identity can spend from.
		uassert.ErrorIs(t, led.TransferFrom(alice, alice, upper, "wood", 1),
			ErrInvalidAddress)
		uassert.ErrorIs(t, led.BatchTransferFrom(alice, alice, upper,
			[]TokenID{"wood"}, []int64{1}), ErrInvalidAddress)
		uassert.ErrorIs(t, led.TransferFrom(upper, upper, alice, "wood", 1),
			ErrInvalidAddress)
	})

	t.Run("approve with uppercase party returns ErrInvalidAddress", func(t *testing.T) {
		uassert.ErrorIs(t, led.SetApprovalForAll(alice, upper, true), ErrInvalidAddress)
		uassert.ErrorIs(t, led.SetApprovalForAll(upper, bob, true), ErrInvalidAddress)
	})

	t.Run("BalanceOf uppercase returns ErrInvalidAddress", func(t *testing.T) {
		_, err := tok.BalanceOf(upper, "wood")
		uassert.ErrorIs(t, err, ErrInvalidAddress)
		_, err = tok.BalanceOfBatch([]address{alice, upper},
			[]TokenID{"wood", "wood"})
		uassert.ErrorIs(t, err, ErrInvalidAddress)
	})

	t.Run("HoldingsOf and HoldingsAfter uppercase yield nothing", func(t *testing.T) {
		tids, _ := tok.HoldingsOf(upper, 0, 10)
		uassert.Equal(t, 0, len(tids))
		tids, _ = tok.HoldingsAfter(upper, "", 10)
		uassert.Equal(t, 0, len(tids))
	})

	// The uppercase forms moved nothing: alice still holds her wood.
	uassert.Equal(t, int64(5), mustBalanceOf(t, tok, alice, "wood"))
}

// TestURIRejectsUnvalidatedID: URI echoes tid into the rendered template, so
// an id outside the write-path charset must yield "" rather than inject
// markdown into a consumer's Render output.
func TestURIRejectsUnvalidatedID(cur realm, t *testing.T) {
	tok, _ := newTestToken("Foo", "FOO", "https://x/{id}.json", cur)

	uassert.Equal(t, "", tok.URI(TokenID("x](javascript:alert(1))\n# pwn")))
	uassert.Equal(t, "", tok.URI(TokenID("bad:id")))
	uassert.Equal(t, "", tok.URI(TokenID("has space")))
	uassert.Equal(t, "", tok.URI(TokenID("")))
	uassert.Equal(t, "", tok.URI(TokenID(strings.Repeat("a", MaxTokenIDLen+1))))

	// Valid ids still substitute normally.
	uassert.Equal(t, "https://x/wood.json", tok.URI("wood"))
}

func TestReadViews(cur realm, t *testing.T) {
	tok, led := newTestToken("Foo", "FOO", "item/{id}", cur)
	urequire.NoError(t, led.Mint(alice, "wood", 5))
	urequire.NoError(t, led.Mint(alice, "ore", 3))
	urequire.NoError(t, led.Mint(bob, "wood", 2))
	urequire.NoError(t, led.SetApprovalForAll(alice, bob, true))

	tests := []struct {
		name  string
		check func(t *testing.T)
	}{
		{"GetName returns token name", func(t *testing.T) {
			uassert.Equal(t, "Foo", tok.GetName())
		}},
		{"GetSymbol returns token symbol", func(t *testing.T) {
			uassert.Equal(t, "FOO", tok.GetSymbol())
		}},
		{"ID carries realm path and symbol", func(t *testing.T) {
			uassert.True(t, strings.HasPrefix(tok.ID(), "gno.land/"))
			uassert.True(t, strings.HasSuffix(tok.ID(), ".FOO"))
		}},
		{"TotalSupply per tid", func(t *testing.T) {
			uassert.Equal(t, int64(7), tok.TotalSupply("wood"))
			uassert.Equal(t, int64(3), tok.TotalSupply("ore"))
			uassert.Equal(t, int64(0), tok.TotalSupply("unknown"))
		}},
		{"Exists reports live token types", func(t *testing.T) {
			uassert.True(t, tok.Exists("wood"))
			uassert.False(t, tok.Exists("unknown"))
		}},
		{"BalanceOf of a holder", func(t *testing.T) {
			uassert.Equal(t, int64(5), mustBalanceOf(t, tok, alice, "wood"))
		}},
		{"BalanceOf of a non-holder is zero", func(t *testing.T) {
			uassert.Equal(t, int64(0), mustBalanceOf(t, tok, carl, "wood"))
		}},
		{"BalanceOf of the zero address returns ErrInvalidAddress", func(t *testing.T) {
			_, err := tok.BalanceOf(zeroAddress, "wood")
			uassert.ErrorIs(t, err, ErrInvalidAddress)
		}},
		{"IsApprovedForAll true for operator", func(t *testing.T) {
			uassert.True(t, tok.IsApprovedForAll(alice, bob))
		}},
		{"IsApprovedForAll false for non-operator", func(t *testing.T) {
			uassert.False(t, tok.IsApprovedForAll(alice, carl))
		}},
		{"RenderHome renders header and counters", func(t *testing.T) {
			out := tok.RenderHome()
			uassert.True(t, strings.Contains(out, "# Foo ($FOO)"), "header")
			uassert.True(t, strings.Contains(out, "**Token types**: 2"), "types")
			uassert.True(t, strings.Contains(out, "**Default URI**: item/{id}"), "uri")
		}},
	}

	for _, tc := range tests {
		tc := tc
		t.Run(tc.name, tc.check)
	}
}

func TestRegisterExtensionNil(cur realm, t *testing.T) {
	_, led := newTestToken("Foo", "FOO", "", cur)
	uassert.PanicsWithMessage(t, cur, "grc1155: nil extension", func() {
		led.RegisterExtension(nil)
	})
}

func TestRegisterExtensionRejectsDuplicateKind(cur realm, t *testing.T) {
	_, led := newTestToken("Foo", "FOO", "", cur)
	ext := &mockExtension{}
	led.RegisterExtension(ext)

	uassert.PanicsWithMessage(t, cur, "grc1155: extension kind already registered: mock", func() {
		led.RegisterExtension(ext)
	})
	uassert.PanicsWithMessage(t, cur, "grc1155: extension kind already registered: mock", func() {
		led.RegisterExtension(&mockExtension{})
	})
}

func TestRegisterExtensionRejectsDuplicateKindOfUncomparableType(cur realm, t *testing.T) {
	_, led := newTestToken("Foo", "FOO", "", cur)
	led.RegisterExtension(journalExtension{seen: []TokenID{"wood"}})

	uassert.PanicsWithMessage(t, cur, "grc1155: extension kind already registered: journal", func() {
		led.RegisterExtension(journalExtension{seen: []TokenID{"ore"}})
	})
}

func TestExtensionHookFanOut(cur realm, t *testing.T) {
	tests := []struct {
		name   string
		run    func(t *testing.T, led *PrivateLedger, ext *mockExtension)
		verify func(t *testing.T, ext *mockExtension)
	}{
		{
			name: "mint, transfer and burn each notify the extension with amounts",
			run: func(t *testing.T, led *PrivateLedger, ext *mockExtension) {
				led.RegisterExtension(ext)
				urequire.NoError(t, led.Mint(alice, "wood", 5))
				urequire.NoError(t, led.TransferFrom(alice, alice, bob, "wood", 2))
				urequire.NoError(t, led.Burn(bob, "wood", 1))
			},
			verify: func(t *testing.T, ext *mockExtension) {
				uassert.Equal(t, 1, ext.mints)
				uassert.Equal(t, alice, ext.lastMintTo)
				uassert.Equal(t, "wood", ext.lastMintID.String())
				uassert.Equal(t, int64(5), ext.lastMintAmount)
				uassert.Equal(t, 1, ext.transfers)
				uassert.Equal(t, alice, ext.lastTransferFrom)
				uassert.Equal(t, bob, ext.lastTransferTo)
				uassert.Equal(t, int64(2), ext.lastTransferAmount)
				uassert.Equal(t, 1, ext.burns)
				uassert.Equal(t, bob, ext.lastBurnFrom)
				uassert.Equal(t, "wood", ext.lastBurnID.String())
				uassert.Equal(t, int64(1), ext.lastBurnAmount)
			},
		},
		{
			name: "batch ops fire hooks once per entry in order",
			run: func(t *testing.T, led *PrivateLedger, ext *mockExtension) {
				led.RegisterExtension(ext)
				urequire.NoError(t, led.MintBatch(alice, []TokenID{"wood", "ore", "wood"}, []int64{5, 2, 3}))
			},
			verify: func(t *testing.T, ext *mockExtension) {
				uassert.Equal(t, 3, ext.mints)
				uassert.True(t, equalStrings([]string{"mint:wood:5", "mint:ore:2", "mint:wood:3"}, ext.journal))
			},
		},
		{
			name: "failed operations do not notify the extension",
			run: func(t *testing.T, led *PrivateLedger, ext *mockExtension) {
				led.RegisterExtension(ext)
				uassert.ErrorIs(t, led.Mint(zeroAddress, "wood", 1), ErrInvalidAddress)
				uassert.ErrorIs(t, led.MintBatch(alice, []TokenID{"wood", "bad:id"}, []int64{1, 1}), ErrInvalidTokenID)
				uassert.ErrorIs(t, led.BurnBatch(alice, []TokenID{"wood", "wood"}, []int64{6, 6}), ErrInsufficientBalance)
			},
			verify: func(t *testing.T, ext *mockExtension) {
				uassert.Equal(t, 0, ext.mints)
				uassert.Equal(t, 0, ext.burns)
				uassert.Equal(t, 0, len(ext.journal))
			},
		},
		{
			name: "failing batch notifies nothing even when an early entry was valid",
			run: func(t *testing.T, led *PrivateLedger, ext *mockExtension) {
				led.RegisterExtension(ext)
				urequire.NoError(t, led.Mint(alice, "wood", 4))
				uassert.ErrorIs(t,
					led.BatchTransferFrom(alice, alice, bob,
						[]TokenID{"wood", "wood", "ore"}, []int64{3, 2, 1}),
					ErrInsufficientBalance)
			},
			verify: func(t *testing.T, ext *mockExtension) {
				// The first mint notifies once; the failed batch notifies zero.
				uassert.Equal(t, 1, ext.mints)
				uassert.Equal(t, 0, ext.transfers)
				uassert.True(t, equalStrings([]string{"mint:wood:4"}, ext.journal))
			},
		},
	}

	for _, tc := range tests {
		tc := tc
		t.Run(tc.name, func(t *testing.T) {
			_, led := newTestToken("Foo", "FOO", "", cur)
			ext := &mockExtension{}
			tc.run(t, led, ext)
			tc.verify(t, ext)
		})
	}
}

func TestReadToken(cur realm, t *testing.T) {
	tok, led := newTestToken("Foo", "FOO", "", cur)
	uassert.Equal(t, tok.ID(), led.ReadToken().ID())
	uassert.True(t, led.ReadToken() == tok, "ReadToken returns the same *Token")
}
