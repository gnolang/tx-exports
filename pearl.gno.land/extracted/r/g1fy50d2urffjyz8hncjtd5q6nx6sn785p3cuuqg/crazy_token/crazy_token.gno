package crazy_token

import "strconv"

type Token struct {
	Name     string
	Symbol   string
	Supply   int64
	Balances map[string]int64
}

var tk *Token

func init() {
	tk = &Token{
		Name:     "CrazyToken",
		Symbol:   "CRAZY",
		Balances: make(map[string]int64),
	}
}

func Mint(_ realm, to string, amount int64) int64 {
	if amount <= 0 {
		panic("amount must be positive")
	}
	tk.Balances[to] += amount
	tk.Supply += amount
	return tk.Balances[to]
}

func Transfer(_ realm, from, to string, amount int64) {
	if amount <= 0 {
		panic("amount must be positive")
	}
	if tk.Balances[from] < amount {
		panic("insufficient balance")
	}
	tk.Balances[from] -= amount
	tk.Balances[to] += amount
}

func BalanceOf(addr string) int64 {
	return tk.Balances[addr]
}

func TotalSupply() int64 {
	return tk.Supply
}

func Render(_ string) string {
	out := tk.Name + " (" + tk.Symbol + ")\n"
	out += "supply: " + strconv.Itoa(int(tk.Supply)) + "\n"
	out += "holders: " + strconv.Itoa(len(tk.Balances)) + "\n"
	return out
}
