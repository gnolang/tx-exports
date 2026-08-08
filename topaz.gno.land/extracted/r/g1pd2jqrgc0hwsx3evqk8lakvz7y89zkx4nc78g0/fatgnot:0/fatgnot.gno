package fatgnot

var (
	owner       string = "g1pd2jqrgc0hwsx3evqk8lakvz7y89zkx4nc78g0"
	name        string = "Fat Gno.Land"
	symbol      string = "FATGNOT"
	decimals    uint8  = 6
	totalSupply uint64 = 1000000000000
	balances           = make(map[string]uint64)
	allowances         = make(map[string]map[string]uint64)
)

func init() {
	balances[owner] = totalSupply
}

func Name() string { return name }
func Symbol() string { return symbol }
func Decimals() uint8 { return decimals }
func TotalSupply() uint64 { return totalSupply }
func BalanceOf(account string) uint64 { return balances[account] }

func Allowance(ownerAddr, spender string) uint64 {
	if allocs, ok := allowances[ownerAddr]; ok {
		return allocs[spender]
	}
	return 0
}

func Transfer(caller, to string, amount uint64) string {
	if balances[caller] < amount {
		panic("insufficient balance")
	}
	balances[caller] -= amount
	balances[to] += amount
	return "Transfer successful"
}

func Approve(caller, spender string, amount uint64) string {
	if allowances[caller] == nil {
		allowances[caller] = make(map[string]uint64)
	}
	allowances[caller][spender] = amount
	return "Approve successful"
}

func TransferFrom(caller, from, to string, amount uint64) string {
	if allowances[from][caller] < amount {
		panic("insufficient allowance")
	}
	if balances[from] < amount {
		panic("insufficient balance")
	}
	allowances[from][caller] -= amount
	balances[from] -= amount
	balances[to] += amount
	return "TransferFrom successful"
}