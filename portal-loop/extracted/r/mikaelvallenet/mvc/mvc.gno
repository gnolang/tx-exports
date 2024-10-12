package mvc

import (
	"std"
	"strings"

	"gno.land/p/demo/grc/grc20"
	"gno.land/p/demo/ufmt"
)

var (
	banker *grc20.Banker
	token grc20.Token
)

func init() {
	banker = grc20.NewBanker("MikaelVallenetCoin", "MVC", 0)
	token = banker.Token()
}

func Faucet() string {
	txSender := std.GetOrigCaller()
	if err := banker.Mint(txSender, 5); err != nil {
		return err.Error()
	}
	return "5 MVC minted to " + txSender.String() + "! 🎉"
}

func Render(path string) string {
	parts := strings.Split(path, "/")
	if len(parts) != 2 && parts[0] != "balance" {
		return "Invalid path, try /balance/<address>"
	}

	addr := std.Address(parts[1])
	balance := token.BalanceOf(addr)
	return ufmt.Sprintf("Balance of %s: %d", addr.String(), balance)
}