// GnoMoji — Unified Coin Realm
// gno.land/r/g138gdmwj6heduu3st796lw6qqdwylgaxf7ty5gz/coins
//
// Single realm managing all GnoMoji GRC20-style token balances.
// Only the authorized minter address can call Mint or Burn.
// Players can call Transfer to move coins to other addresses.
//
// Balance storage: AVL tree with key "coinId:addr" → amount string.
// Total supply: AVL tree with key "coinId" → total minted string.

package coins

import (
	"strconv"
	"strings"

	"gno.land/p/nt/avl/v0"
	"gno.land/p/nt/ufmt/v0"
)

var (
	minterAddr address  // set to minter4 realm address post-deploy via SetMinter
	adminAddr  address  // set at init to deployer
	balances   avl.Tree // key: "coinId:addr" → amount string
	supplies   avl.Tree // key: "coinId" → total supply string
)

func init(cur realm) {
	adminAddr = cur.Previous().Address()
}

// SetMinter sets the authorized minter address.
// Called once after the minter realm is deployed, by the admin.
func SetMinter(cur realm, newMinter string) {
	if cur.Previous().Address() != adminAddr {
		panic("coins: only admin can set minter")
	}
	minterAddr = address(newMinter)
}

func isMinter(cur realm) bool {
	return cur.Previous().Address() == minterAddr
}

func isAdmin(cur realm) bool {
	return cur.Previous().Address() == adminAddr
}

// ── Core operations ──────────────────────────────────────────────────────────

// Mint creates new tokens of coinId and credits them to toAddr.
// Only the authorized minter or admin can call this.
func Mint(cur realm, coinId string, toAddr string, amountStr string) {
	if !isMinter(cur) && !isAdmin(cur) {
		panic("coins: unauthorized — only minter or admin can mint")
	}
	if coinId == "" || toAddr == "" {
		panic("coins: coinId and toAddr required")
	}
	if !strings.HasPrefix(toAddr, "g1") {
		panic("coins: invalid Gno.land address")
	}
	amount, err := strconv.ParseUint(amountStr, 10, 64)
	if err != nil || amount == 0 {
		panic("coins: invalid amount")
	}

	// Credit balance
	balKey := coinId + ":" + toAddr
	existing := uint64(0)
	if balances.Has(balKey) {
		existing, _ = strconv.ParseUint(balances.Get(balKey).(string), 10, 64)
	}
	balances.Set(balKey, strconv.FormatUint(existing+amount, 10))

	// Update total supply
	supExisting := uint64(0)
	if supplies.Has(coinId) {
		supExisting, _ = strconv.ParseUint(supplies.Get(coinId).(string), 10, 64)
	}
	supplies.Set(coinId, strconv.FormatUint(supExisting+amount, 10))
}

// Burn destroys tokens of coinId from fromAddr.
// Only the minter or admin can burn.
func Burn(cur realm, coinId string, fromAddr string, amountStr string) {
	if !isMinter(cur) && !isAdmin(cur) {
		panic("coins: unauthorized — only minter or admin can burn")
	}
	amount, err := strconv.ParseUint(amountStr, 10, 64)
	if err != nil || amount == 0 {
		panic("coins: invalid amount")
	}

	balKey := coinId + ":" + fromAddr
	current := uint64(0)
	if balances.Has(balKey) {
		current, _ = strconv.ParseUint(balances.Get(balKey).(string), 10, 64)
	}
	if current < amount {
		panic("coins: insufficient balance to burn")
	}
	balances.Set(balKey, strconv.FormatUint(current-amount, 10))

	supCurrent := uint64(0)
	if supplies.Has(coinId) {
		supCurrent, _ = strconv.ParseUint(supplies.Get(coinId).(string), 10, 64)
	}
	if supCurrent >= amount {
		supplies.Set(coinId, strconv.FormatUint(supCurrent-amount, 10))
	}
}

// Transfer moves tokens from the caller to toAddr.
// Any holder can call this.
func Transfer(cur realm, coinId string, toAddr string, amountStr string) {
	caller := cur.Previous().Address().String()
	if !strings.HasPrefix(toAddr, "g1") {
		panic("coins: invalid destination address")
	}
	if caller == toAddr {
		panic("coins: cannot transfer to self")
	}
	amount, err := strconv.ParseUint(amountStr, 10, 64)
	if err != nil || amount == 0 {
		panic("coins: invalid amount")
	}

	fromKey := coinId + ":" + caller
	current := uint64(0)
	if balances.Has(fromKey) {
		current, _ = strconv.ParseUint(balances.Get(fromKey).(string), 10, 64)
	}
	if current < amount {
		panic("coins: insufficient balance")
	}

	balances.Set(fromKey, strconv.FormatUint(current-amount, 10))

	toKey := coinId + ":" + toAddr
	toExisting := uint64(0)
	if balances.Has(toKey) {
		toExisting, _ = strconv.ParseUint(balances.Get(toKey).(string), 10, 64)
	}
	balances.Set(toKey, strconv.FormatUint(toExisting+amount, 10))
}

// ── Queries ──────────────────────────────────────────────────────────────────

// BalanceOf returns the token balance of addr for coinId.
func BalanceOf(coinId string, addr string) string {
	key := coinId + ":" + addr
	if !balances.Has(key) {
		return "0"
	}
	return balances.Get(key).(string)
}

// BalancesOf returns all coin balances for a given address as a JSON object.
func BalancesOf(addr string) string {
	var parts []string
	balances.Iterate(
		"",
		"\xFF",
		func(key string, val interface{}) bool {
			// key format: "coinId:addr"
			idx := strings.LastIndex(key, ":")
			if idx < 0 {
				return false
			}
			balAddr := key[idx+1:]
			if balAddr != addr {
				return false
			}
			coinId := key[:idx]
			amt := val.(string)
			if amt != "0" {
				parts = append(parts, ufmt.Sprintf(`"%s":"%s"`, coinId, amt))
			}
			return false
		},
	)
	return "{" + strings.Join(parts, ",") + "}"
}

// TotalSupply returns the total minted supply for coinId.
func TotalSupply(coinId string) string {
	if !supplies.Has(coinId) {
		return "0"
	}
	return supplies.Get(coinId).(string)
}

// MinterAddr returns the current authorized minter address.
func MinterAddr() string {
	return minterAddr.String()
}

func Render(_ string) string {
	return ufmt.Sprintf(
		"# GnoMoji Coins\n\nAdmin: `%s`\nMinter: `%s`\n\nUnified multi-token realm for all GnoMoji coins.\nUse `BalanceOf(coinId, addr)` or `BalancesOf(addr)` to query balances.\n",
		adminAddr.String(),
		minterAddr.String(),
	)
}
