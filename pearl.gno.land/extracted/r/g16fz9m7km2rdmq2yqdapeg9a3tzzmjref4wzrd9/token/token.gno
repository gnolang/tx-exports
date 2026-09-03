package token

import "strconv"

type Token struct {
	Name     string
	Symbol   string
	Decimals int
	Supply   int64
	Balances map[string]int64
}

var token *Token

func init() {
	token = &Token{
		Name:     "PearlToken",
		Symbol:   "PRL",
		Decimals: 6,
		Balances: make(map[string]int64),
	}
}

func Mint(to string, amount int64) {
	if amount <= 0 {
		panic("amount must be positive")
	}
	token.Balances[to] += amount
	token.Supply += amount
}

func Burn(from string, amount int64) {
	if amount <= 0 {
		panic("amount must be positive")
	}
	if token.Balances[from] < amount {
		panic("insufficient balance")
	}
	token.Balances[from] -= amount
	token.Supply -= amount
}

func Transfer(from, to string, amount int64) {
	if amount <= 0 {
		panic("amount must be positive")
	}
	if token.Balances[from] < amount {
		panic("insufficient balance")
	}
	token.Balances[from] -= amount
	token.Balances[to] += amount
}

func BalanceOf(addr string) int64 {
	return token.Balances[addr]
}

func TotalSupply() int64 {
	return token.Supply
}

func Render(_ string) string {
	return token.Name + " (" + token.Symbol + ") supply: " + strconv.Itoa(int(token.Supply)) + "\n"
}
