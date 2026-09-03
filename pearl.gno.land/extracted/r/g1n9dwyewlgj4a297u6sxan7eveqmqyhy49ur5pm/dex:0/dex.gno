// dex — Decentralized Exchange (mini DEX)
// Features: Add liquidity, swap tokens, price discovery via x*y=k
// 10 wallets can be liquidity providers
package dex

import (
	"strconv"
	"strings"

)

// Pool represents a liquidity pool for token A / token B
type Pool struct {
	ReserveA     int64
	ReserveB     int64
	TotalLP      int64           // total liquidity provider shares
	LPShares     map[string]int64 // LP shares per address
}

// SwapResult represents the result of a swap
type SwapResult struct {
	AmountOut   int64
	NewReserveA int64
	NewReserveB int64
}

var pool *Pool

// Fee in basis points (0.3% = 30 bps)
const feeBps = 30

func init() {
	pool = &Pool{
		LPShares: make(map[string]int64),
	}
}

// === Liquidity ===

// AddLiquidity adds token A and B to the pool, returns LP shares
func AddLiquidity(cur realm, amountA, amountB int64) int64 {
	caller := cur.Previous().Address().String()
	if amountA <= 0 || amountB <= 0 {
		panic("amounts must be positive")
	}

	var shares int64
	if pool.TotalLP == 0 {
		// First liquidity: shares = sqrt(amountA * amountB)
		shares = sqrtApprox(amountA * amountB)
	} else {
		// Subsequent: shares = min(amountA * TotalLP / ReserveA, amountB * TotalLP / ReserveB)
		sharesA := amountA * pool.TotalLP / pool.ReserveA
		sharesB := amountB * pool.TotalLP / pool.ReserveB
		if sharesA < sharesB {
			shares = sharesA
		} else {
			shares = sharesB
		}
	}

	pool.ReserveA += amountA
	pool.ReserveB += amountB
	pool.TotalLP += shares
	pool.LPShares[caller] += shares

	return shares
}

// RemoveLiquidity removes liquidity and returns token amounts
func RemoveLiquidity(cur realm, shares int64) (int64, int64) {
	caller := cur.Previous().Address().String()
	if shares <= 0 {
		panic("shares must be positive")
	}
	if pool.LPShares[caller] < shares {
		panic("insufficient shares")
	}

	amountA := shares * pool.ReserveA / pool.TotalLP
	amountB := shares * pool.ReserveB / pool.TotalLP

	pool.ReserveA -= amountA
	pool.ReserveB -= amountB
	pool.TotalLP -= shares
	pool.LPShares[caller] -= shares

	return amountA, amountB
}

// === Swap ===

// SwapAForB swaps token A for token B
func SwapAForB(cur realm, amountIn int64) int64 {
	if amountIn <= 0 {
		panic("amount must be positive")
	}
	if pool.ReserveA == 0 || pool.ReserveB == 0 {
		panic("pool empty")
	}

	// Apply fee: amountInWithFee = amountIn * (10000 - feeBps)
	amountInWithFee := amountIn * (10000 - feeBps)

	// amountOut = amountInWithFee * ReserveB / (ReserveA * 10000 + amountInWithFee)
	amountOut := amountInWithFee * pool.ReserveB / (pool.ReserveA*10000 + amountInWithFee)

	if amountOut >= pool.ReserveB {
		panic("insufficient liquidity")
	}

	pool.ReserveA += amountIn
	pool.ReserveB -= amountOut

	return amountOut
}

// SwapBForA swaps token B for token A
func SwapBForA(cur realm, amountIn int64) int64 {
	if amountIn <= 0 {
		panic("amount must be positive")
	}
	if pool.ReserveA == 0 || pool.ReserveB == 0 {
		panic("pool empty")
	}

	amountInWithFee := amountIn * (10000 - feeBps)
	amountOut := amountInWithFee * pool.ReserveA / (pool.ReserveB*10000 + amountInWithFee)

	if amountOut >= pool.ReserveA {
		panic("insufficient liquidity")
	}

	pool.ReserveB += amountIn
	pool.ReserveA -= amountOut

	return amountOut
}

// === Query Functions ===

// GetReserves returns current pool reserves
func GetReserves() (int64, int64) {
	return pool.ReserveA, pool.ReserveB
}

// GetPrice returns the price of A in terms of B
func GetPrice() string {
	if pool.ReserveA == 0 {
		return "0"
	}
	price := pool.ReserveB * 1000000 / pool.ReserveA
	return strconv.FormatInt(price, 10)
}

// GetLPShares returns LP shares for an address
func GetLPShares(addr string) int64 {
	return pool.LPShares[addr]
}

// TotalLiquidity returns total LP shares
func TotalLiquidity() int64 {
	return pool.TotalLP
}

// GetAmountOut calculates expected output for a given input (read-only)
func GetAmountOut(amountIn int64, isAForB bool) int64 {
	if amountIn <= 0 {
		return 0
	}
	amountInWithFee := amountIn * (10000 - feeBps)
	if isAForB {
		if pool.ReserveA == 0 {
			return 0
		}
		return amountInWithFee * pool.ReserveB / (pool.ReserveA*10000 + amountInWithFee)
	}
	if pool.ReserveB == 0 {
		return 0
	}
	return amountInWithFee * pool.ReserveA / (pool.ReserveB*10000 + amountInWithFee)
}

// === Render ===

func Render(_ string) string {
	b := strings.Builder{}
	b.WriteString("# DEX Mini\n\n")
	b.WriteString("## Pool\n")
	b.WriteString("- Reserve A: " + strconv.FormatInt(pool.ReserveA, 10) + "\n")
	b.WriteString("- Reserve B: " + strconv.FormatInt(pool.ReserveB, 10) + "\n")
	b.WriteString("- Total LP: " + strconv.FormatInt(pool.TotalLP, 10) + "\n")
	b.WriteString("- Price (A→B): " + GetPrice() + "\n")
	b.WriteString("- Fee: 0.3%\n\n")
	b.WriteString("## Functions\n")
	b.WriteString("- `AddLiquidity(amountA, amountB)` — add liquidity\n")
	b.WriteString("- `RemoveLiquidity(shares)` — remove liquidity\n")
	b.WriteString("- `SwapAForB(amountIn)` — swap A for B\n")
	b.WriteString("- `SwapBForA(amountIn)` — swap B for A\n")
	b.WriteString("- `GetReserves()` — check pool reserves\n")
	b.WriteString("- `GetAmountOut(amountIn, isAForB)` — calculate output\n")
	return b.String()
}

// === Helpers ===

// sqrtApprox returns an approximate square root using Newton's method
func sqrtApprox(n int64) int64 {
	if n <= 0 {
		return 0
	}
	x := n
	y := (x + 1) / 2
	for y < x {
		x = y
		y = (x + n/x) / 2
	}
	return x
}
