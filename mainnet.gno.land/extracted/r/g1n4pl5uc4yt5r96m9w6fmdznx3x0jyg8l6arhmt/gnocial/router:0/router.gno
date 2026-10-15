// Package router is Gnocial's swap entry.
//
// A wallet approves this realm for the input token, then calls Swap.
// Swap keeps 0.01% of that input for the treasury and exact-in swaps the
// rest through GnoSwap. The output is sent back to the same wallet.
//
// The gnomi pad accepts Buy, Sell, and Transfer only from a direct wallet
// call, so a curve trade cannot be forwarded through this realm.
package router

import (
	"chain"
	"chain/runtime/unsafe"
	"strconv"
	"strings"
	"time"

	"gno.land/r/gnoswap/common"
	gsrouter "gno.land/r/gnoswap/router"
)

const (
	// FeeBps is the treasury share of the input. 1 is 0.01%.
	FeeBps int64 = 1
	// Wugnot is the wrapped-GNOT token key GnoSwap uses.
	Wugnot = "gno.land/r/gnoland/wugnot.wugnot"
)

var (
	self          address
	treasury      = address("g1n4pl5uc4yt5r96m9w6fmdznx3x0jyg8l6arhmt")
	gnoswapRouter = address("g1vc883gshu5z7ytk5cdynhc8c2dh67pdp4cszkp")
	busy          bool
)

func init() {
	self = unsafe.CurrentRealm().Address()
}

// Address is this realm's bech32 address. Approve the input token to it.
func Address() string {
	return self.String()
}

// FeeTo is the treasury that receives the input fee.
func FeeTo() string {
	return treasury.String()
}

// GnoSwapRouter is the GnoSwap router address this realm approves.
func GnoSwapRouter() string {
	return gnoswapRouter.String()
}

// Split returns the treasury fee and the amount that continues to GnoSwap.
func Split(gross int64) (int64, int64) {
	return split(gross)
}

// Quote asks GnoSwap what an exact-in route returns. It moves no tokens.
func Quote(inputToken, outputToken, amount, routeArr, quoteArr string) (string, string) {
	mustPair(inputToken, outputToken)
	if amount == "" || len(amount) > 20 || !digits(amount) {
		panic("amount is not valid")
	}
	mustRoute(routeArr, quoteArr)
	in, out, err := gsrouter.DrySwapRoute(inputToken, outputToken, amount, "EXACT_IN", routeArr, quoteArr, "1")
	if err != nil {
		panic(err.Error())
	}
	return in, out
}

// Swap pulls gross of inputToken from the calling wallet, pays the treasury
// fee, and exact-in swaps the rest. minOut is the least output the wallet
// accepts. deadline is a unix second. The wallet must already have approved
// this realm for gross. Send no coins with the call.
func Swap(cur realm, inputToken, outputToken string, gross int64, routeArr, quoteArr string, minOut, deadline int64) int64 {
	if busy {
		panic("swap is already running")
	}
	if !cur.Previous().IsUserCall() {
		panic("direct wallet call only")
	}
	if len(unsafe.OriginSend()) != 0 {
		panic("send no coins")
	}
	user := cur.Previous().Address()
	if !user.IsValid() || !self.IsValid() {
		panic("caller is not valid")
	}
	mustPair(inputToken, outputToken)
	mustRoute(routeArr, quoteArr)
	if minOut <= 0 {
		panic("minimum output must be positive")
	}
	if deadline <= time.Now().Unix() {
		panic("route expired")
	}
	fee, swapAmt := split(gross)
	busy = true
	defer func() { busy = false }()

	pullToken(cur, inputToken, user, self, gross)
	if fee > 0 {
		pushToken(cur, inputToken, treasury, fee)
	}
	allowToken(cur, inputToken, gnoswapRouter, swapAmt)
	inRaw, outRaw := runExactIn(
		cur,
		inputToken,
		outputToken,
		strconv.FormatInt(swapAmt, 10),
		routeArr,
		quoteArr,
		strconv.FormatInt(minOut, 10),
		deadline,
	)
	used := mustInt(inRaw, "swap input is not valid")
	got := mustInt(outRaw, "swap output is not valid")
	if used < 0 || used > swapAmt {
		panic("swap input is not valid")
	}
	if got < minOut {
		panic("output is below the minimum")
	}
	// GnoSwap may spend less than the approval. Drop the rest before
	// any token leaves, so a later balance cannot be pulled.
	allowToken(cur, inputToken, gnoswapRouter, 0)
	if left := swapAmt - used; left > 0 {
		pushToken(cur, inputToken, user, left)
	}
	pushToken(cur, outputToken, user, got)
	chain.Emit(
		"Swap",
		"caller", user.String(),
		"input", inputToken,
		"output", outputToken,
		"gross", strconv.FormatInt(gross, 10),
		"fee", strconv.FormatInt(fee, 10),
		"in", strconv.FormatInt(used, 10),
		"out", strconv.FormatInt(got, 10),
	)
	return got
}

// Render describes the router. Curve trades are not offered here.
func Render(path string) string {
	if path != "" {
		return "# Gnocial router\n\nThat path is not a page.\n"
	}
	return "# Gnocial router\n\n" +
		"Approve the input token to this realm, then call Swap.\n\n" +
		"The treasury keeps 0.01% of the input. GnoSwap swaps the rest.\n\n" +
		"A gnomi bonding-curve trade stays a direct wallet call. The pad does not accept this realm.\n"
}

func split(gross int64) (int64, int64) {
	if gross <= 0 {
		panic("amount must be positive")
	}
	fee := gross * FeeBps / 10_000
	swapAmt := gross - fee
	if swapAmt <= 0 {
		panic("amount is too small")
	}
	return fee, swapAmt
}

func mustPair(inputToken, outputToken string) {
	mustToken(inputToken)
	mustToken(outputToken)
	if inputToken == outputToken {
		panic("same token")
	}
}

func mustToken(token string) {
	if len(token) < len("gno.land/r/a") || len(token) > 200 || !strings.HasPrefix(token, "gno.land/r/") {
		panic("token path is not valid")
	}
	if strings.Contains(token, " ") || strings.Contains(token, "..") || strings.Contains(token, "//") {
		panic("token path is not valid")
	}
}

func mustRoute(routeArr, quoteArr string) {
	if routeArr == "" || len(routeArr) > 480 || strings.Contains(routeArr, " ") {
		panic("route is not valid")
	}
	if quoteArr == "" || len(quoteArr) > 32 || strings.Contains(quoteArr, " ") {
		panic("route is not valid")
	}
}

func digits(raw string) bool {
	for _, r := range raw {
		if r < '0' || r > '9' {
			return false
		}
	}
	return true
}

func mustInt(raw, what string) int64 {
	n, err := strconv.ParseInt(raw, 10, 64)
	if err != nil || n < 0 {
		panic(what)
	}
	return n
}

func pullToken(cur realm, token string, from, to address, amount int64) {
	if err := common.TransferFrom(0, cur, token, from, to, amount); err != nil {
		panic(err.Error())
	}
}

func pushToken(cur realm, token string, to address, amount int64) {
	common.SafeGRC20Transfer(0, cur, token, to, amount)
}

func allowToken(cur realm, token string, spender address, amount int64) {
	if err := common.Approve(0, cur, token, spender, amount); err != nil {
		panic(err.Error())
	}
}

func runExactIn(cur realm, input, output, amount, routeArr, quoteArr, minOut string, deadline int64) (string, string) {
	return gsrouter.ExactInSwapRoute(cross(cur), input, output, amount, routeArr, quoteArr, minOut, deadline, "")
}
