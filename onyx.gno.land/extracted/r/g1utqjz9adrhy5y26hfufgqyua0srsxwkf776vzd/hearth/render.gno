package hearth

// Render shows the token's distribution state for gnoweb.

import (
	"strconv"

	"gno.land/p/nt/ufmt/v0"
)

func Render(path string) string {
	return ufmt.Sprintf(`# HEARTH — HearthCouncil governance token

Fixed supply, no admin mint. The full supply was minted once into this
realm's reserve; distribution happens only through Claim (once per
address) and the demo Faucet.

- Name: %s
- Symbol: %s
- Decimals: %d
- Total supply: %s HEARTH
- Still in reserve: %s HEARTH
- One-time claim: %s HEARTH per address
- Demo faucet: %s HEARTH per call

## Get HEARTH

1. Call Claim (once per address) or Faucet (demo tap) from the gnoweb
   Actions tab.
2. Approve the DAO realm to pull your deposit (spender = the
   hearthcouncil realm address, amount = what you want to stake).
3. Call Deposit on the hearthcouncil realm, then vote on proposals.
`,
		Name(), Symbol(), Decimals(),
		strconv.Itoa(int(TotalSupply())),
		strconv.Itoa(int(Reserve())),
		strconv.Itoa(ClaimAmount),
		strconv.Itoa(FaucetAmount),
	)
}
