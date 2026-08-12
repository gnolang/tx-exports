package ucs03_zkgm

import (
	"chain"
	"strconv"
	"strings"

	u256 "gno.land/p/onbloc/math/uint256"
	"gno.land/r/demo/defi/grc20reg"
)

// ibcDenomPrefix is the prefix of wrapped IBC voucher denoms (mirrors
// z.PredictWrappedToken*). Used to detect and trim wrapped denoms.
const ibcDenomPrefix = "ibc/"

const (
	// IBC_TOKEN is a zkgm-issued ibc/ voucher. Supply is minted on recv and
	// burned on send-side UNESCROW or maker burn-address ack; custody moves via
	// transferVoucher between holders and the proxy escrow.
	IBC_TOKEN = iota
	// GRC20_TOKEN is a locally registered grc20 (not a zkgm voucher). Custody
	// moves via Teller TransferFrom/Transfer; this realm cannot burn its supply.
	GRC20_TOKEN
	// NATIVE_COIN is a banker coin attached with tx -send. Escrow consumes the
	// attached funds budget; unescrow releases from the proxy banker balance.
	NATIVE_COIN
)

func isIBCTokenDenom(denom string) bool {
	return strings.HasPrefix(denom, ibcDenomPrefix)
}

func getTokenType(denom string) int {
	if isIBCTokenDenom(denom) {
		return IBC_TOKEN
	}

	if token := grc20reg.Get(denom); token != nil {
		return GRC20_TOKEN
	}

	return NATIVE_COIN
}

// parseCoins parses a comma-separated <amount><denom> string into Coins.
func parseCoins(s string) chain.Coins {
	if s == "" {
		return nil
	}

	parts := strings.Split(s, ",")
	coins := make([]chain.Coin, 0, len(parts))

	for _, part := range parts {
		if part == "" {
			continue
		}

		i := 0
		for i < len(part) && part[i] >= '0' && part[i] <= '9' {
			i++
		}

		if i == 0 || i == len(part) {
			panic("zkgm/coins: invalid coin " + part)
		}

		amount, err := strconv.ParseInt(part[:i], 10, 64)
		if err != nil {
			panic(err)
		}

		coins = append(coins, chain.NewCoin(part[i:], amount))
	}

	return chain.NewCoins(coins...)
}

// funds is the gno analog of the reference contract's threaded `funds: &mut Coins`
// (the message's attached coins). It is decremented as each token order consumes
// its BaseAmount during verification.
type funds struct {
	coins map[string]chain.Coin
}

// newFunds snapshots the attached coins into a mutable spend budget.
func newFunds(sent chain.Coins) *funds {
	f := &funds{coins: make(map[string]chain.Coin)}

	for _, coin := range sent {
		f.coins[coin.Denom] = coin
	}

	return f
}

// sub deducts amount of denom from the attached funds, mirroring funds.sub(coin)
// in the reference contract. It errors when the funds do not cover the amount.
func (f *funds) sub(denom string, amount *u256.Uint) error {
	want, err := amountInt64(amount)
	if err != nil {
		return err
	}

	coin, ok := f.coins[denom]
	if !ok {
		return makeError(errCoinMismatch)
	}

	if coin.Amount < want {
		return makeError(errCoinMismatch)
	}

	coin.Amount -= want
	f.coins[denom] = coin

	return nil
}

// isEmpty reports whether every attached coin has been fully consumed.
func (f *funds) isEmpty() bool {
	for _, coin := range f.coins {
		if coin.Amount != 0 {
			return false
		}
	}

	return true
}

// assertEmpty errors when any attached coin is left unconsumed.
func (f *funds) assertEmpty() error {
	if !f.isEmpty() {
		return makeError(errCoinMismatch)
	}

	return nil
}
