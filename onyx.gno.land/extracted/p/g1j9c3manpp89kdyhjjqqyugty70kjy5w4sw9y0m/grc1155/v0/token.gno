package grc1155

import (
	"chain"
	"math/overflow"
	"strconv"
	"strings"
)

// NewToken creates a core multi-token and its ledger.
// rlm must be the caller's own captured cur (IsCurrent); its PkgPath becomes the unforgeable origRealm.
//
// Every successful call emits a NewToken event carrying the resulting Token.ID().
// Because Token's fields are unexported, NewToken is the only way a Token can come
// into existence, so this event makes token creation fully observable: an indexer
// that sees the same Token.ID() announced twice knows the realm built two
// independent ledgers behind one identifier, and that every later
// movement carrying that id is ambiguous. Such a realm is emitting untrustworthy
// events and should be flagged or ignored wholesale.
//
// Token.ID() is pkgPath + "." + symbol with no per-creation discriminator, so a
// realm must not create two tokens with the same symbol: their IDs would collide
// in indexers and registries keyed on ID().
func NewToken(name, symbol, defaultURI string, _ int, rlm realm) (*Token, *PrivateLedger) {
	if !rlm.IsCurrent() {
		panic(ErrSpoofedRealm)
	}

	pkgPath := rlm.PkgPath()
	if pkgPath == "" {
		panic(ErrNotRealm)
	}

	if !validName(name) {
		panic(ErrInvalidName)
	}

	if !validSymbol(symbol) {
		panic(ErrInvalidSymbol)
	}

	if !validURI(defaultURI) {
		panic(ErrInvalidURI)
	}

	// origRealm is the host path, with any "#subpath" synthesized by realm.Sub
	// stripped. guardHome strips the invoking path the same way, so a token
	// created from a sub frame is not locked out of its own host realm, and a
	// host's sub-realms are not falsely rejected. Token.ID() keeps the raw
	// pkgPath, so identities and the NewToken event are unaffected.
	origRealm, _, _ := chain.SplitPkgSubPath(pkgPath)

	ledger := &PrivateLedger{}
	token := &Token{
		id:         pkgPath + "." + symbol,
		name:       name,
		symbol:     symbol,
		defaultURI: defaultURI,
		ledger:     ledger,
		origRealm:  origRealm,
	}
	ledger.token = token

	chain.Emit(
		NewTokenEvent,
		"token", token.id,
		"name", name,
		"symbol", symbol,
	)

	return token, ledger
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

func validSymbol(s string) bool {
	if s == "" || len(s) > MaxSymbolLen {
		return false
	}

	for _, c := range s {
		if !isAlnum(c) && c != '_' && c != '-' {
			return false
		}
	}

	return true
}

func isAlnum(c rune) bool {
	return (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9')
}

// validTokenID restricts ids to a charset that is safe in markdown and in the
// composite "owner:id" storage keys: no ':', no whitespace, no control chars.
func validTokenID(tid string) bool {
	if tid == "" || len(tid) > MaxTokenIDLen {
		return false
	}

	for _, c := range tid {
		if !isAlnum(c) && c != '_' && c != '-' && c != '.' {
			return false
		}
	}

	return true
}

func validURI(uri string) bool {
	if len(uri) > MaxURILen {
		return false
	}

	for _, c := range uri {
		if c < 0x20 || c == 0x7f {
			return false
		}
	}

	return true
}

// validAddr is IsValid() plus the lowercase-canonical form: bech32 accepts an
// all-uppercase encoding that decodes to the same bytes, but String() then
// differs, so it would be a distinct ledger key no frame-derived identity can
// ever match — tokens sent there are stranded.
func validAddr(a address) bool {
	s := a.String()
	return a.IsValid() && s == strings.ToLower(s)
}

func (tok *Token) GetName() string { return tok.name }

func (tok *Token) GetSymbol() string { return tok.symbol }

func (tok *Token) ID() string { return tok.id }

// URI returns the per-token override when one is set, else the default URI
// template with every "{id}" placeholder replaced by the raw TokenID string —
// substitution happens on-chain here, unlike EIP-1155 where clients fill in a
// 64-hex id themselves. An id outside the write-path charset returns "" so an
// unvalidated caller-supplied id can never be echoed into rendered output.
func (tok *Token) URI(tid TokenID) string {
	if !validTokenID(tid.String()) {
		return ""
	}

	if uri := tok.ledger.uris.Get(tid.String()); uri != nil {
		return uri.(string)
	}

	return strings.ReplaceAll(tok.defaultURI, "{id}", tid.String())
}

func (tok *Token) TotalSupply(tid TokenID) int64 { return tok.ledger.totalSupplyOf(tid) }

// Exists reports whether tid currently has nonzero total supply. Supply
// entries are removed when they reach zero, so this is also the count of
// live token types backing TokenIDs.
func (tok *Token) Exists(tid TokenID) bool { return tok.ledger.supplies.Has(tid.String()) }

// EIP-1155: balanceOf throws for queries about addresses that cannot hold
// tokens, so the zero/invalid address is rejected up front.
func (tok *Token) BalanceOf(owner address, tid TokenID) (int64, error) {
	if !validAddr(owner) {
		return 0, ErrInvalidAddress
	}

	return tok.ledger.balanceOf(owner, tid), nil
}

func (tok *Token) BalanceOfBatch(owners []address, tids []TokenID) ([]int64, error) {
	if len(owners) != len(tids) {
		return nil, ErrLengthMismatch
	}

	if len(owners) == 0 {
		return nil, ErrEmptyBatch
	}

	if len(owners) > MaxBatchSize {
		return nil, ErrBatchTooLarge
	}

	balances := make([]int64, len(owners))
	for i := 0; i < len(owners); i++ {
		if !validAddr(owners[i]) {
			return nil, ErrInvalidAddress
		}

		balances[i] = tok.ledger.balanceOf(owners[i], tids[i])
	}

	return balances, nil
}

func (tok *Token) IsApprovedForAll(owner, operator address) bool {
	return tok.ledger.isApprovedForAll(owner, operator)
}

// HoldingsOf returns up to limit (TokenID, balance) pairs held by owner, in
// TokenID order, skipping the first offset entries. limit is clamped to
// maxPageSize; offset < 0 counts from the first entry; limit <= 0 yields
// nothing. Reads stay inside the owner's "owner:" key range, but the offset
// skip walks entries one at a time, so a deep page costs O(offset) — use
// HoldingsAfter for cursor pagination whose cost is O(log n + page).
func (tok *Token) HoldingsOf(owner address, offset, limit int) ([]TokenID, []int64) {
	if !validAddr(owner) || limit <= 0 {
		return nil, nil
	}

	if offset < 0 {
		offset = 0
	}

	if limit > maxPageSize {
		limit = maxPageSize
	}

	prefix := owner.String() + ":"
	// ";" sorts immediately after ":", so [prefix, owner+";") selects exactly
	// this owner's "owner:tid" keys and nothing else.
	end := owner.String() + ";"

	tids := []TokenID{}
	balances := []int64{}
	tok.ledger.balances.Iterate(prefix, end, func(key string, value any) bool {
		if offset > 0 {
			offset--
			return false
		}

		tids = append(tids, TokenID(key[len(prefix):]))
		balances = append(balances, value.(int64))

		return len(tids) >= limit
	})

	return tids, balances
}

// HoldingsAfter is the cursor-paginated form of HoldingsOf: it returns up to
// limit (TokenID, balance) pairs held by owner with TokenID strictly greater
// than after, in TokenID order. An empty after starts from the owner's first
// holding; a non-empty after outside the write-path charset yields nil, nil.
// limit is clamped to maxPageSize; limit <= 0 yields nothing. The range seek
// lands directly after "owner:after", so cost is O(log n + page) regardless of
// how deep into the holdings the cursor sits — unlike HoldingsOf's offset skip.
func (tok *Token) HoldingsAfter(owner address, after TokenID, limit int) ([]TokenID, []int64) {
	if !validAddr(owner) || limit <= 0 {
		return nil, nil
	}

	if limit > maxPageSize {
		limit = maxPageSize
	}

	prefix := owner.String() + ":"
	// ";" sorts immediately after ":", so [start, owner+";") selects exactly
	// this owner's "owner:tid" keys and nothing else.
	end := owner.String() + ";"

	var start string
	if after.String() == "" {
		start = prefix
	} else {
		if !validTokenID(after.String()) {
			return nil, nil
		}
		// "owner:after" itself must be excluded; appending \x00 — below every
		// valid tid byte — starts the inclusive range just past it while still
		// preceding "owner:after<anything>".
		start = prefix + after.String() + "\x00"
	}

	tids := []TokenID{}
	balances := []int64{}
	tok.ledger.balances.Iterate(start, end, func(key string, value any) bool {
		tids = append(tids, TokenID(key[len(prefix):]))
		balances = append(balances, value.(int64))

		return len(tids) >= limit
	})

	return tids, balances
}

// TokenIDs returns up to limit token ids with nonzero supply, in id order,
// skipping the first offset entries. limit is clamped to maxPageSize;
// offset < 0 counts from the first entry; limit <= 0 yields nothing.
func (tok *Token) TokenIDs(offset, limit int) []TokenID {
	if limit <= 0 {
		return nil
	}

	if offset < 0 {
		offset = 0
	}

	if limit > maxPageSize {
		limit = maxPageSize
	}

	ids := []TokenID{}
	tok.ledger.supplies.IterateByOffset(offset, limit, func(key string, value any) bool {
		ids = append(ids, TokenID(key))

		return len(ids) >= limit
	})

	return ids
}

func (tok *Token) RenderHome() string {
	str := ""
	str += "# " + tok.name + " ($" + tok.symbol + ")\n\n"
	str += "* **ID**: `" + tok.id + "`\n"
	str += "* **Token types**: " + strconv.Itoa(tok.ledger.supplies.Size()) + "\n"
	str += "* **Default URI**: " + tok.defaultURI + "\n"

	return str
}

// RegisterExtension attaches an issuer-supplied hook set. Issuer-only (holds the
// PrivateLedger), which keeps the surface from being attacker-attachable — but the
// attachment is still a privilege: per the Extension doc, an attached hook can veto
// transfers (a panic aborts the transaction before the Transfer event is emitted) and
// adds gas to every movement.
// One extension per kind; a second registration of an attached kind panics.
func (led *PrivateLedger) RegisterExtension(ext Extension) {
	if ext == nil {
		panic("grc1155: nil extension")
	}

	kind := ext.ExtensionKind()
	for _, e := range led.extensions {
		if e.ExtensionKind() == kind {
			panic("grc1155: extension kind already registered: " + kind)
		}
	}

	led.extensions = append(led.extensions, ext)
}

func (led *PrivateLedger) ReadToken() *Token { return led.token }

func (led *PrivateLedger) Mint(to address, tid TokenID, amount int64) error {
	if err := led.mint(to, []TokenID{tid}, []int64{amount}); err != nil {
		return err
	}

	// Mint emits TransferSingle from the empty address (EIP-1155); indexers
	// reconstruct supply from Transfer events alone. The ledger has no
	// spender for mints, so operator is empty.
	emitTransferSingle(led.token.id, zeroAddress, "", to, tid, amount)

	return nil
}

func (led *PrivateLedger) MintBatch(to address, tids []TokenID, amounts []int64) error {
	if err := led.mint(to, tids, amounts); err != nil {
		return err
	}

	emitTransferBatch(led.token.id, zeroAddress, "", to, tids, amounts)

	return nil
}

// mint validates the whole batch — including accumulating duplicate tids —
// before touching state, so a returned error leaves zero changes behind.
func (led *PrivateLedger) mint(to address, tids []TokenID, amounts []int64) error {
	if err := checkBatch(tids, amounts); err != nil {
		return err
	}

	if !validAddr(to) {
		return ErrInvalidAddress
	}

	totals, err := batchTotals(tids, amounts)
	if err != nil {
		return err
	}

	for i := 0; i < len(tids); i++ {
		if _, ok := overflow.Add64(led.balanceOf(to, tids[i]), totals[i]); !ok {
			return ErrOverflow
		}

		if _, ok := overflow.Add64(led.totalSupplyOf(tids[i]), totals[i]); !ok {
			return ErrOverflow
		}
	}

	for i := 0; i < len(tids); i++ {
		led.setBalance(to, tids[i], overflow.Add64p(led.balanceOf(to, tids[i]), amounts[i]))
		led.setSupply(tids[i], overflow.Add64p(led.totalSupplyOf(tids[i]), amounts[i]))
	}

	for i := 0; i < len(tids); i++ {
		for _, ext := range led.extensions {
			ext.OnMint(to, tids[i], amounts[i])
		}
	}

	return nil
}

func (led *PrivateLedger) Burn(from address, tid TokenID, amount int64) error {
	if err := led.burn(from, []TokenID{tid}, []int64{amount}); err != nil {
		return err
	}

	// Burn emits TransferSingle to the empty address (EIP-1155); operator is
	// empty for the same reason as mint.
	emitTransferSingle(led.token.id, zeroAddress, from, zeroAddress, tid, amount)

	return nil
}

func (led *PrivateLedger) BurnBatch(from address, tids []TokenID, amounts []int64) error {
	if err := led.burn(from, tids, amounts); err != nil {
		return err
	}

	emitTransferBatch(led.token.id, zeroAddress, from, zeroAddress, tids, amounts)

	return nil
}

func (led *PrivateLedger) burn(from address, tids []TokenID, amounts []int64) error {
	if err := checkBatch(tids, amounts); err != nil {
		return err
	}

	if !validAddr(from) {
		return ErrInvalidAddress
	}

	totals, err := batchTotals(tids, amounts)
	if err != nil {
		return err
	}

	for i := 0; i < len(tids); i++ {
		if led.balanceOf(from, tids[i]) < totals[i] {
			return ErrInsufficientBalance
		}

		if _, ok := overflow.Sub64(led.totalSupplyOf(tids[i]), totals[i]); !ok {
			return ErrOverflow
		}
	}

	for i := 0; i < len(tids); i++ {
		led.setBalance(from, tids[i], overflow.Sub64p(led.balanceOf(from, tids[i]), amounts[i]))
		led.setSupply(tids[i], overflow.Sub64p(led.totalSupplyOf(tids[i]), amounts[i]))
	}

	for i := 0; i < len(tids); i++ {
		for _, ext := range led.extensions {
			ext.OnBurn(from, tids[i], amounts[i])
		}
	}

	return nil
}

// spender must be from itself or an approved operator of from; callers derive
// it from a trusted per-frame identity.
func (led *PrivateLedger) TransferFrom(spender, from, to address, tid TokenID, amount int64) error {
	if !led.isAuthorized(spender, from) {
		return ErrCallerIsNotOwnerOrApproved
	}

	if err := led.transfer(from, to, []TokenID{tid}, []int64{amount}); err != nil {
		return err
	}

	emitTransferSingle(led.token.id, spender, from, to, tid, amount)

	return nil
}

func (led *PrivateLedger) BatchTransferFrom(spender, from, to address, tids []TokenID, amounts []int64) error {
	if !led.isAuthorized(spender, from) {
		return ErrCallerIsNotOwnerOrApproved
	}

	if err := led.transfer(from, to, tids, amounts); err != nil {
		return err
	}

	emitTransferBatch(led.token.id, spender, from, to, tids, amounts)

	return nil
}

// transfer validates the whole batch — including accumulating duplicate tids
// against both the sender's balance and the recipient's headroom — before
// touching state, so a returned error leaves zero changes behind.
func (led *PrivateLedger) transfer(from, to address, tids []TokenID, amounts []int64) error {
	if err := checkBatch(tids, amounts); err != nil {
		return err
	}

	if !validAddr(from) || !validAddr(to) {
		return ErrInvalidAddress
	}

	if from == to {
		return ErrCannotTransferToSelf
	}

	totals, err := batchTotals(tids, amounts)
	if err != nil {
		return err
	}

	for i := 0; i < len(tids); i++ {
		if led.balanceOf(from, tids[i]) < totals[i] {
			return ErrInsufficientBalance
		}

		if _, ok := overflow.Add64(led.balanceOf(to, tids[i]), totals[i]); !ok {
			return ErrOverflow
		}
	}

	for i := 0; i < len(tids); i++ {
		led.setBalance(from, tids[i], overflow.Sub64p(led.balanceOf(from, tids[i]), amounts[i]))
		led.setBalance(to, tids[i], overflow.Add64p(led.balanceOf(to, tids[i]), amounts[i]))
	}

	for i := 0; i < len(tids); i++ {
		for _, ext := range led.extensions {
			ext.OnTransfer(from, to, tids[i], amounts[i])
		}
	}

	return nil
}

func (led *PrivateLedger) SetApprovalForAll(owner, operator address, approved bool) error {
	if !validAddr(owner) || !validAddr(operator) {
		return ErrInvalidAddress
	}

	if owner == operator {
		return ErrApprovalToCurrentOwner
	}

	key := operatorKey(owner, operator)
	if approved {
		led.operatorApprovals.Set(key, approved)
	} else {
		led.operatorApprovals.Remove(key)
	}

	chain.Emit(
		ApprovalForAllEvent,
		"token", led.token.id,
		"owner", owner.String(),
		"to", operator.String(),
		"approved", strconv.FormatBool(approved),
	)

	return nil
}

// SetURI sets the per-token URI override for tid; an empty uri clears the
// override so URI(tid) falls back to the default template again.
func (led *PrivateLedger) SetURI(tid TokenID, uri string) error {
	if !validTokenID(tid.String()) {
		return ErrInvalidTokenID
	}

	if !validURI(uri) {
		return ErrInvalidURI
	}

	if uri == "" {
		led.uris.Remove(tid.String())
	} else {
		led.uris.Set(tid.String(), uri)
	}

	chain.Emit(
		URIEvent,
		"token", led.token.id,
		"id", tid.String(),
		"value", uri,
	)

	return nil
}

func (led *PrivateLedger) SetDefaultURI(uri string) error {
	if !validURI(uri) {
		return ErrInvalidURI
	}

	led.token.defaultURI = uri

	chain.Emit(
		URIEvent,
		"token", led.token.id,
		"value", uri,
	)

	return nil
}

// checkBatch validates the shape shared by every batch operation: equal,
// non-empty lengths within MaxBatchSize, valid token ids and positive amounts.
// It runs before any state is touched.
func checkBatch(tids []TokenID, amounts []int64) error {
	if len(tids) != len(amounts) {
		return ErrLengthMismatch
	}

	if len(tids) == 0 {
		return ErrEmptyBatch
	}

	if len(tids) > MaxBatchSize {
		return ErrBatchTooLarge
	}

	for i := 0; i < len(tids); i++ {
		if !validTokenID(tids[i].String()) {
			return ErrInvalidTokenID
		}

		if amounts[i] <= 0 {
			return ErrInvalidAmount
		}
	}

	return nil
}

// batchTotals returns, for each index i, the sum of amounts over every index
// sharing tids[i] — the per-token-id total a batch moves. Sums are
// overflow-checked; a batch asking to move more than int64 of one id is an
// ErrOverflow, not a silent wrap.
func batchTotals(tids []TokenID, amounts []int64) ([]int64, error) {
	totals := make([]int64, len(tids))
	for i := 0; i < len(tids); i++ {
		var sum int64
		for j := 0; j < len(tids); j++ {
			if tids[j] == tids[i] {
				var ok bool
				sum, ok = overflow.Add64(sum, amounts[j])
				if !ok {
					return nil, ErrOverflow
				}
			}
		}
		totals[i] = sum
	}

	return totals, nil
}

func (led *PrivateLedger) isAuthorized(spender, from address) bool {
	return spender == from || led.isApprovedForAll(from, spender)
}

func (led *PrivateLedger) balanceOf(owner address, tid TokenID) int64 {
	balance := led.balances.Get(balanceKey(owner, tid))
	if balance == nil {
		return 0
	}

	return balance.(int64)
}

func (led *PrivateLedger) setBalance(owner address, tid TokenID, balance int64) {
	key := balanceKey(owner, tid)
	if balance == 0 {
		led.balances.Remove(key)

		return
	}

	led.balances.Set(key, balance)
}

func (led *PrivateLedger) totalSupplyOf(tid TokenID) int64 {
	supply := led.supplies.Get(tid.String())
	if supply == nil {
		return 0
	}

	return supply.(int64)
}

func (led *PrivateLedger) setSupply(tid TokenID, supply int64) {
	key := tid.String()
	if supply == 0 {
		led.supplies.Remove(key)

		return
	}

	led.supplies.Set(key, supply)
}

func (led *PrivateLedger) isApprovedForAll(owner, operator address) bool {
	approved := led.operatorApprovals.Get(operatorKey(owner, operator))
	if approved == nil {
		return false
	}

	return approved.(bool)
}

// balanceKey is owner-first so every "owner:tid" key of one owner forms a
// contiguous range HoldingsOf can iterate without scanning other holders.
func balanceKey(owner address, tid TokenID) string {
	return owner.String() + ":" + tid.String()
}

func operatorKey(owner, operator address) string {
	return owner.String() + ":" + operator.String()
}

// TransferSingle/TransferBatch attribute style mirrors grc721: flat string
// attrs, "token" carrying Token.ID(), then "operator" (EIP-1155's operator —
// the spender for transfers, empty for mint/burn). Batch ids/values are
// comma-joined.
func emitTransferSingle(tokenID string, operator address, from, to address, tid TokenID, amount int64) {
	chain.Emit(
		TransferSingleEvent,
		"token", tokenID,
		"operator", operator.String(),
		"from", from.String(),
		"to", to.String(),
		"id", tid.String(),
		"value", strconv.FormatInt(amount, 10),
	)
}

func emitTransferBatch(tokenID string, operator address, from, to address, tids []TokenID, amounts []int64) {
	ids := make([]string, len(tids))
	values := make([]string, len(amounts))
	for i := 0; i < len(tids); i++ {
		ids[i] = tids[i].String()
		values[i] = strconv.FormatInt(amounts[i], 10)
	}

	chain.Emit(
		TransferBatchEvent,
		"token", tokenID,
		"operator", operator.String(),
		"from", from.String(),
		"to", to.String(),
		"ids", strings.Join(ids, ","),
		"values", strings.Join(values, ","),
	)
}
