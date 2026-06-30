package acr

import (
	"strconv"

	"gno.land/p/akkadia/v0/ds/btree"
	"gno.land/p/akkadia/v0/ds/btreeset"
	"gno.land/p/demo/tokens/grc20"
)

const (
	maxInt64 = int64(9223372036854775807)

	maxHofCategoryCount = 1024
)

// ACRStore owns ACR token state, ranking indexes, request IDs, and HOF data.
//
// Data shape:
// - token: GRC-20 token state
// - ledger: private GRC-20 ledger capability
// - balanceIndex: balance(int64) -> *StringBTreeSet(account address string)
// - mintIndex: minted(int64) -> *StringBTreeSet(account address string)
// - userMintTotal: account(address string) -> minted(int64)
// - processedRequests: requestID(string) set
// - hofCategories: category(string) -> CSV rows(string)
type ACRStore struct {
	token             *grc20.Token
	ledger            *grc20.PrivateLedger
	balanceIndex      *btree.Int64BTree
	mintIndex         *btree.Int64BTree
	userMintTotal     *btree.StringBTree
	processedRequests *btreeset.StringBTreeSet
	hofCategories     *btree.StringBTree
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
		hofCategories:     btree.NewStringBTree(32),
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

func (s *ACRStore) HofCategories() *btree.StringBTree {
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

func (s *ACRStore) ListTopUsersByBalance(page int, count int) []map[string]string {
	result := []map[string]string{}
	skipped := 0
	offset := pageOffset(page, count)
	s.balanceIndex.ReverseIterate(nil, nil, func(balance int64, value any) bool {
		if len(result) >= count {
			return true
		}

		users := value.(*btreeset.StringBTreeSet)
		users.Iterate(nil, nil, func(addr string) bool {
			if skipped < offset {
				skipped++
				return false
			}
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

func (s *ACRStore) ListTopUsersByMinting(page int, count int) []map[string]string {
	result := []map[string]string{}
	skipped := 0
	offset := pageOffset(page, count)
	s.mintIndex.ReverseIterate(nil, nil, func(minted int64, value any) bool {
		if len(result) >= count {
			return true
		}

		users := value.(*btreeset.StringBTreeSet)
		users.Iterate(nil, nil, func(addr string) bool {
			if skipped < offset {
				skipped++
				return false
			}
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
	if s.hofCategories.Size() >= maxHofCategoryCount {
		panic("hof categories exceeds maxHofCategoryCount")
	}
	if s.hofCategories.Has(name) {
		panic("category already exists: " + name)
	}
	s.hofCategories.Set(name, "")
}

func (s *ACRStore) RemoveHofCategory(name string) {
	if !s.hofCategories.Has(name) {
		panic("category not found: " + name)
	}
	s.hofCategories.Remove(name)
}

func (s *ACRStore) SetHofEntries(category string, csvRows string) {
	if !s.hofCategories.Has(category) {
		panic("category not found: " + category)
	}
	s.hofCategories.Set(category, csvRows)
}

func (s *ACRStore) ListHofCategories(page int, count int) []string {
	categories := []string{}
	s.hofCategories.IterateByOffset(pageOffset(page, count), count, func(name string, _ any) bool {
		categories = append(categories, name)
		return false
	})
	return categories
}

func (s *ACRStore) GetHofEntries(category string) string {
	csv, exists := s.hofCategories.Get(category)
	if !exists {
		panic("category not found: " + category)
	}
	return csv.(string)
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
	return s.hofCategories.Size()
}

func (s *ACRStore) BalanceRankingCount() int {
	total := 0
	s.balanceIndex.Iterate(nil, nil, func(_ int64, value any) bool {
		total += value.(*btreeset.StringBTreeSet).Size()
		return false
	})
	return total
}

func (s *ACRStore) MintingRankingCount() int {
	total := 0
	s.mintIndex.Iterate(nil, nil, func(_ int64, value any) bool {
		total += value.(*btreeset.StringBTreeSet).Size()
		return false
	})
	return total
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
