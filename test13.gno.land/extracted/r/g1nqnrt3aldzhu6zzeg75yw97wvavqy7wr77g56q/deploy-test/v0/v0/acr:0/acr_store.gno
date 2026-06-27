package acr

import (
	"strconv"
	"strings"

	"gno.land/p/g1nqnrt3aldzhu6zzeg75yw97wvavqy7wr77g56q/deploy-test/v0/v0/ds/btree"
	"gno.land/p/g1nqnrt3aldzhu6zzeg75yw97wvavqy7wr77g56q/deploy-test/v0/v0/ds/btreeset"
	"gno.land/p/demo/tokens/grc20"
)

const (
	maxInt64 = int64(9223372036854775807)

	maxHofCategoryNameLength = 128
	maxHofCategoryCount      = 1024
	maxHofEntriesBytes       = 256 * 1024
	maxHofEntriesRows        = 100
	maxHofColumns            = 32
)

type ACRStore struct {
	token             *grc20.Token
	ledger            *grc20.PrivateLedger
	balanceIndex      *btree.Int64BTree
	mintIndex         *btree.Int64BTree
	userMintTotal     *btree.StringBTree
	processedRequests *btreeset.StringBTreeSet
	hofCategories     map[string]string
}

func newACRStore(cur realm) *ACRStore {
	token, ledger := grc20.NewToken(0, cur, "Akkadia Community Rune", "ACR", 6)
	return &ACRStore{
		token:             token,
		ledger:            ledger,
		balanceIndex:      btree.NewInt64BTree(32),
		mintIndex:         btree.NewInt64BTree(32),
		userMintTotal:     btree.NewStringBTree(32),
		processedRequests: btreeset.NewStringBTreeSet(32),
		hofCategories:     map[string]string{},
	}
}

// ==================== DANGER: MUTABLE MIGRATION CAPABILITIES ====================
//
// The getters in this section expose mutable token/store internals.
// Only authorized migration exporter paths may depend on these capabilities.
// Runtime reads and test setup must use copy-returning methods or total helpers.
func (s *ACRStore) Token() *grc20.Token {
	return s.token
}

func (s *ACRStore) Ledger() *grc20.PrivateLedger {
	return s.ledger
}

func (s *ACRStore) BalanceIndex() *btree.Int64BTree {
	return s.balanceIndex
}

func (s *ACRStore) MintIndex() *btree.Int64BTree {
	return s.mintIndex
}

func (s *ACRStore) UserMintTotal() *btree.StringBTree {
	return s.userMintTotal
}

func (s *ACRStore) ProcessedRequests() *btreeset.StringBTreeSet {
	return s.processedRequests
}

func (s *ACRStore) HofCategories() map[string]string {
	return s.hofCategories
}

// ================= END DANGER: MUTABLE MIGRATION CAPABILITIES ==================

func (s *ACRStore) GetName() string {
	return s.token.GetName()
}

func (s *ACRStore) GetSymbol() string {
	return s.token.GetSymbol()
}

func (s *ACRStore) GetDecimals() int {
	return s.token.GetDecimals()
}

func (s *ACRStore) KnownAccounts() int {
	return s.token.KnownAccounts()
}

func (s *ACRStore) TotalSupply() int64 {
	return s.token.TotalSupply()
}

func (s *ACRStore) BalanceOf(account address) int64 {
	return s.token.BalanceOf(account)
}

func (s *ACRStore) Allowance(owner, spender address) int64 {
	return s.token.Allowance(owner, spender)
}

func (s *ACRStore) Transfer(from, to address, amount int64) {
	oldFromBalance := s.BalanceOf(from)
	oldToBalance := s.BalanceOf(to)

	err := s.ledger.Transfer(from, to, amount)
	if err != nil {
		panic("transfer failed: " + err.Error())
	}

	s.updateBalanceIndex(from, oldFromBalance, s.BalanceOf(from))
	s.updateBalanceIndex(to, oldToBalance, s.BalanceOf(to))
}

func (s *ACRStore) Approve(owner, spender address, amount int64) {
	currentAllowance := s.Allowance(owner, spender)
	if amount != 0 && currentAllowance != 0 {
		panic("approve failed: must reset allowance to 0 before setting a new non-zero allowance")
	}

	err := s.ledger.Approve(owner, spender, amount)
	if err != nil {
		panic("approve failed: " + err.Error())
	}
}

func (s *ACRStore) TransferFrom(from, spender, to address, amount int64) {
	oldFromBalance := s.BalanceOf(from)
	oldToBalance := s.BalanceOf(to)

	err := s.ledger.TransferFrom(from, spender, to, amount)
	if err != nil {
		panic("transferFrom failed: " + err.Error())
	}

	s.updateBalanceIndex(from, oldFromBalance, s.BalanceOf(from))
	s.updateBalanceIndex(to, oldToBalance, s.BalanceOf(to))
}

func (s *ACRStore) Mint(requestID string, to address, amount int64) {
	if requestID == "" {
		panic("requestID is required")
	}
	if s.processedRequests.Has(requestID) {
		panic("requestID already processed")
	}
	if amount <= 0 {
		panic("amount must be positive")
	}

	oldBalance := s.BalanceOf(to)
	oldMintTotal := s.MintedOf(to)
	newMintTotal := calculateMintTotal(oldMintTotal, amount)

	err := s.ledger.Mint(to, amount)
	if err != nil {
		panic("mint failed: " + err.Error())
	}

	s.processedRequests.Set(requestID)
	s.updateBalanceIndex(to, oldBalance, s.BalanceOf(to))
	s.updateMintIndex(to, oldMintTotal, newMintTotal)
}

func (s *ACRStore) Burn(caller address, amount int64) {
	if amount <= 0 {
		panic("amount must be positive")
	}

	oldBalance := s.BalanceOf(caller)

	err := s.ledger.Burn(caller, amount)
	if err != nil {
		panic("burn failed: " + err.Error())
	}

	s.updateBalanceIndex(caller, oldBalance, s.BalanceOf(caller))
}

func (s *ACRStore) IsRequestProcessed(requestID string) bool {
	return s.processedRequests.Has(requestID)
}

func (s *ACRStore) ListRequestProcessed(requestIDs ...string) map[string]bool {
	result := make(map[string]bool)
	for _, id := range requestIDs {
		result[id] = s.processedRequests.Has(id)
	}
	return result
}

func (s *ACRStore) MintedOf(account address) int64 {
	value, found := s.userMintTotal.Get(account.String())
	if !found {
		return 0
	}
	return value.(int64)
}

func (s *ACRStore) ListTopUsersByBalance(count int) []map[string]string {
	var result []map[string]string
	s.balanceIndex.ReverseIterate(nil, nil, func(balance int64, value any) bool {
		if len(result) >= count {
			return true
		}

		users := value.(*btreeset.StringBTreeSet)
		users.Iterate(nil, nil, func(addr string) bool {
			result = append(result, map[string]string{
				"user":    addr,
				"balance": strconv.FormatInt(balance, 10),
			})
			return len(result) >= count
		})

		return false
	})
	return result
}

func (s *ACRStore) ListTopUsersByMinting(count int) []map[string]string {
	var result []map[string]string
	s.mintIndex.ReverseIterate(nil, nil, func(minted int64, value any) bool {
		if len(result) >= count {
			return true
		}

		users := value.(*btreeset.StringBTreeSet)
		users.Iterate(nil, nil, func(addr string) bool {
			result = append(result, map[string]string{
				"user":   addr,
				"minted": strconv.FormatInt(minted, 10),
			})
			return len(result) >= count
		})

		return false
	})
	return result
}

func (s *ACRStore) CreateHofCategory(name string) {
	validateHofCategoryName(name)
	if len(s.hofCategories) >= maxHofCategoryCount {
		panic("hof categories exceeds maxHofCategoryCount")
	}
	if _, exists := s.hofCategories[name]; exists {
		panic("category already exists: " + name)
	}
	s.hofCategories[name] = ""
}

func (s *ACRStore) RemoveHofCategory(name string) {
	if _, exists := s.hofCategories[name]; !exists {
		panic("category not found: " + name)
	}
	delete(s.hofCategories, name)
}

func (s *ACRStore) SetHofEntries(category string, csvRows string) {
	if _, exists := s.hofCategories[category]; !exists {
		panic("category not found: " + category)
	}
	s.hofCategories[category] = validateHofEntries(csvRows)
}

func (s *ACRStore) ListHofCategories() []string {
	var categories []string
	for name := range s.hofCategories {
		categories = append(categories, name)
	}
	return categories
}

func (s *ACRStore) GetHofEntries(category string) string {
	csv, exists := s.hofCategories[category]
	if !exists {
		panic("category not found: " + category)
	}
	return csv
}

func (s *ACRStore) BalanceIndexCount() int {
	return s.balanceIndex.Size()
}

func (s *ACRStore) MintIndexCount() int {
	return s.mintIndex.Size()
}

func (s *ACRStore) UserMintTotalCount() int {
	return s.userMintTotal.Size()
}

func (s *ACRStore) ProcessedRequestCount() int {
	return s.processedRequests.Size()
}

func (s *ACRStore) HofCategoryCount() int {
	return len(s.hofCategories)
}

func (s *ACRStore) addToBalanceIndex(addr address, balance int64) {
	value, found := s.balanceIndex.Get(balance)
	var users *btreeset.StringBTreeSet
	if !found {
		users = btreeset.NewStringBTreeSet(32)
		s.balanceIndex.Set(balance, users)
	} else {
		users = value.(*btreeset.StringBTreeSet)
	}
	users.Set(addr.String())
}

func (s *ACRStore) removeFromBalanceIndex(addr address, balance int64) {
	value, found := s.balanceIndex.Get(balance)
	if !found {
		return
	}

	users := value.(*btreeset.StringBTreeSet)
	users.Remove(addr.String())
	if users.Size() == 0 {
		s.balanceIndex.Remove(balance)
	}
}

func (s *ACRStore) updateBalanceIndex(addr address, oldBalance, newBalance int64) {
	if oldBalance > 0 {
		s.removeFromBalanceIndex(addr, oldBalance)
	}
	if newBalance > 0 {
		s.addToBalanceIndex(addr, newBalance)
	}
}

func (s *ACRStore) addToMintIndex(addr address, mintTotal int64) {
	value, found := s.mintIndex.Get(mintTotal)
	var users *btreeset.StringBTreeSet
	if !found {
		users = btreeset.NewStringBTreeSet(32)
		s.mintIndex.Set(mintTotal, users)
	} else {
		users = value.(*btreeset.StringBTreeSet)
	}
	users.Set(addr.String())
}

func (s *ACRStore) removeFromMintIndex(addr address, mintTotal int64) {
	value, found := s.mintIndex.Get(mintTotal)
	if !found {
		return
	}

	users := value.(*btreeset.StringBTreeSet)
	users.Remove(addr.String())
	if users.Size() == 0 {
		s.mintIndex.Remove(mintTotal)
	}
}

func (s *ACRStore) updateMintIndex(addr address, oldMintTotal, newMintTotal int64) {
	s.userMintTotal.Set(addr.String(), newMintTotal)
	if oldMintTotal > 0 {
		s.removeFromMintIndex(addr, oldMintTotal)
	}
	s.addToMintIndex(addr, newMintTotal)
}

func calculateMintTotal(oldMintTotal, amount int64) int64 {
	if oldMintTotal < 0 || amount > maxInt64-oldMintTotal {
		panic("mint total overflow")
	}
	return oldMintTotal + amount
}

func validateHofCategoryName(name string) {
	if name == "" {
		panic("invalid name: ")
	}
	if len(name) > maxHofCategoryNameLength {
		panic("category name exceeds maxHofCategoryNameLength")
	}
}

func validateHofEntries(csvRows string) string {
	csvRows = strings.TrimRight(csvRows, "\n")
	if csvRows == "" {
		return ""
	}
	if len(csvRows) > maxHofEntriesBytes {
		panic("hof entries exceeds maxHofEntriesBytes")
	}

	rows := strings.Split(csvRows, "\n")
	if len(rows) > maxHofEntriesRows {
		panic("hof entries rows exceeds maxHofEntriesRows")
	}

	headers := strings.Split(rows[0], ",")
	validateHofColumns(headers, true)

	for i := 1; i < len(rows); i++ {
		if rows[i] == "" {
			panic("invalid hof csv: empty row")
		}
		cols := strings.Split(rows[i], ",")
		validateHofColumns(cols, false)
		if len(cols) != len(headers) {
			panic("invalid hof csv: inconsistent column count")
		}
	}

	return csvRows
}

func validateHofColumns(cols []string, header bool) {
	if len(cols) > maxHofColumns {
		panic("hof entries columns exceeds maxHofColumns")
	}
	if !header {
		return
	}
	for _, col := range cols {
		if strings.TrimSpace(col) == "" {
			panic("invalid hof csv: empty header")
		}
	}
}
