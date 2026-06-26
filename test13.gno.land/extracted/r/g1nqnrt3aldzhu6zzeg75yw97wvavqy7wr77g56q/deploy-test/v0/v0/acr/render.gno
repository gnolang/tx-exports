package acr

import (
	"net/url"
	"strconv"
	"strings"

	"gno.land/r/g1nqnrt3aldzhu6zzeg75yw97wvavqy7wr77g56q/deploy-test/v0/v0/admin"
)

const pageSize = 20

// Render handles RESTful routing and returns Markdown responses
func Render(iUrl string) string {
	assertMigrationStateAvailable()
	u, err := url.Parse(iUrl)
	if err != nil {
		return renderError("Invalid URL")
	}

	query := u.Query()

	switch u.Path {
	case "":
		return renderHome()
	case "top/balance":
		return renderTopByBalance(iUrl)
	case "top/minted":
		return renderTopByMinted(iUrl)
	case "hof":
		return renderHof()
	case "account":
		addr := query.Get("address")
		if addr == "" {
			return renderError("Address required")
		}
		return renderAccount(addr)
	default:
		// hof/{categoryName} routing
		if len(u.Path) > 4 && u.Path[:4] == "hof/" {
			name, err := url.PathUnescape(u.Path[4:])
			if err != nil {
				return renderError("Invalid category name")
			}
			return renderHofCategory(name)
		}
		return renderError("Page not found")
	}
}

// renderHome renders the home page with stats, description, and links
func renderHome() string {
	output := "# " + acrStore.GetName() + " (" + acrStore.GetSymbol() + ")\n\n"

	output += `## Introduction

**Akkadia Community Rune (ACR)** is the utility token of the Akkadia ecosystem.
Users earn ACR through in-game activities and community participation.

`
	output += "## Token Info\n\n"
	output += "* **Decimals**: " + strconv.Itoa(int(acrStore.GetDecimals())) + "\n"
	output += "* **Total Supply**: " + formatAmount(acrStore.TotalSupply()) + "\n"
	output += "* **Known Accounts**: " + strconv.Itoa(acrStore.KnownAccounts()) + "\n"

	output += `
## Quick Links

* [Top Holders by Balance](./acr:top/balance)
* [Top Holders by Minted](./acr:top/minted)
* [Hall of Fame](./acr:hof)

## Account Lookup

<gno-form path="account">
  <gno-input name="address" placeholder="Enter wallet address (g1...)" />
</gno-form>
`
	return output
}

// renderTopByBalance renders paginated list of top holders by balance
func renderTopByBalance(iUrl string) string {
	output := "# Top Holders by Balance\n\n"
	output += "[← Home](../acr:)\n\n"

	totalAccounts := acrStore.KnownAccounts()
	if totalAccounts == 0 {
		output += "*No accounts yet.*\n"
		return output
	}

	users := ListTopUsersByBalance(100)

	if len(users) == 0 {
		output += "*No data available.*\n"
		return output
	}

	output += "| Rank | Address | Balance |\n"
	output += "|------|---------|--------|\n"

	startRank := 1
	for i, u := range users {
		addr := u["user"]
		balance, _ := strconv.ParseInt(u["balance"], 10, 64)
		addrLink := addr + " [[View on Explorer](" + admin.GetExplorerURL() + "/m/explorer/player?address=" + addr + ")]"
		output += "| " + strconv.Itoa(startRank+i) + " | " + addrLink + " | " + formatAmount(balance) + " |\n"
	}

	return output
}

// renderTopByMinted renders paginated list of top holders by minted amount
func renderTopByMinted(iUrl string) string {
	output := "# Top Holders by Minted Amount\n\n"
	output += "[← Home](../acr:)\n\n"

	totalAccounts := acrStore.KnownAccounts()
	if totalAccounts == 0 {
		output += "*No accounts yet.*\n"
		return output
	}

	users := ListTopUsersByMinting(100)

	if len(users) == 0 {
		output += "*No data available.*\n"
		return output
	}

	output += "| Rank | Address | Total Minted |\n"
	output += "|------|---------|-------------|\n"

	startRank := 1
	for i, u := range users {
		addr := u["user"]
		minted, _ := strconv.ParseInt(u["minted"], 10, 64)
		addrLink := addr + " [[View on Explorer](" + admin.GetExplorerURL() + "/m/explorer/player?address=" + addr + ")]"
		output += "| " + strconv.Itoa(startRank+i) + " | " + addrLink + " | " + formatAmount(minted) + " |\n"
	}

	return output
}

// renderAccount renders a single account's ACR details
func renderAccount(addrStr string) string {
	addr := address(addrStr)
	if !addr.IsValid() {
		return renderError("Invalid address")
	}

	balance := BalanceOf(addr)
	minted := MintedOf(addr)

	output := "# Account Details\n\n"
	output += "[← Home](./acr:)\n\n"

	output += "* **Address**: " + addrStr + " [[View on Explorer](" + admin.GetExplorerURL() + "/m/explorer/player?address=" + addrStr + ")]\n"
	output += "* **Balance**: " + formatAmount(balance) + " " + acrStore.GetSymbol() + "\n"
	output += "* **Total Minted**: " + formatAmount(minted) + " " + acrStore.GetSymbol() + "\n"

	return output
}

// renderHof renders the Hall of Fame overview page with all categories
func renderHof() string {
	output := "# Hall of Fame\n\n"
	output += "[← Home](./acr:)\n\n"

	categories := ListHofCategories()
	if len(categories) == 0 {
		output += "*No categories yet.*\n"
		return output
	}

	for _, name := range categories {
		csv := GetHofEntries(name)
		rowCount := 0
		if csv != "" {
			rows := strings.Split(csv, "\n")
			if len(rows) > 1 {
				rowCount = len(rows) - 1 // exclude header
			}
		}
		output += "* [" + name + "](./acr:hof/" + url.PathEscape(name) + ") (" + strconv.Itoa(rowCount) + " entries)\n"
	}

	return output
}

// renderHofCategory renders entries for a specific Hall of Fame category
func renderHofCategory(name string) string {
	output := "# Hall of Fame: " + name + "\n\n"
	output += "[← Hall of Fame](../acr:hof)\n\n"

	csv := GetHofEntries(name)
	if csv == "" {
		output += "*No entries yet.*\n"
		return output
	}

	rows := strings.Split(csv, "\n")
	if len(rows) == 0 {
		output += "*No entries yet.*\n"
		return output
	}

	// First row = header
	headers := strings.Split(rows[0], ",")
	output += "|"
	for _, h := range headers {
		output += " " + h + " |"
	}
	output += "\n|"
	for range headers {
		output += "------|"
	}
	output += "\n"

	// Data rows
	for i := 1; i < len(rows); i++ {
		cols := strings.SplitN(rows[i], ",", len(headers))
		output += "|"
		for _, c := range cols {
			output += " " + c + " |"
		}
		output += "\n"
	}

	return output
}

// renderError renders an error page
func renderError(message string) string {
	output := "# Error\n\n"
	output += "> " + message + "\n\n"
	output += "[← Back to Home](./acr:)\n"
	return output
}

// formatAmount formats token amount with proper decimal places
func formatAmount(amount int64) string {
	decimals := acrStore.GetDecimals()
	if decimals == 0 {
		return strconv.FormatInt(amount, 10)
	}

	// Calculate divisor (10^decimals)
	divisor := int64(1)
	for i := 0; i < decimals; i++ {
		divisor *= 10
	}

	intPart := amount / divisor
	fracPart := amount % divisor

	return strconv.FormatInt(intPart, 10) + "." + leftPadZeros(strconv.FormatInt(fracPart, 10), int(decimals))
}

func leftPadZeros(value string, width int) string {
	for len(value) < width {
		value = "0" + value
	}
	return value
}
