package admin

func Render(path string) string {
	return renderHome()
}

func renderHome() string {
	operators := GetOperators()
	operatorList := ""
	for _, addr := range operators {
		operatorList += "* " + addr.String() + "\n"
	}
	if operatorList == "" {
		operatorList = "(none)\n"
	}

	output := `# AKKADIA on Gno

## Introduction

AKKADIA is a blockchain-based game like Minecraft.

this contract is managing the admin of the AKKADIA game.

## Admin

* **Address**: ` + admin.String() + `

## Operators

` + operatorList + `
## Fee Collector

* **Address**: ` + feeCollectorAddr.String() + `

## Protocol

* **Address**: ` + protocolAddr.String() + `

## Operator Faucet

* **Target Amount**: ` + int64ToString(faucetTargetAmount) + ` ugnot
`
	return output
}
