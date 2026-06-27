// Render — public read-only view + audit surface for the fee config.
package memba_market_config

import (
	"strings"

	"gno.land/p/nt/ufmt/v0"
)

func Render(path string) string {
	var sb strings.Builder
	sb.WriteString("# Memba Marketplace — Fee Config\n\n")
	sb.WriteString("DAO-owned per-lane protocol fee + treasury. Engines read this at settlement.\n\n")
	sb.WriteString(ufmt.Sprintf("**Admin:** %s\n", admin.String()))
	if pendingAdmin != "" {
		sb.WriteString(ufmt.Sprintf("**Pending admin:** %s\n", pendingAdmin.String()))
	}
	sb.WriteString(ufmt.Sprintf("**Treasury:** %s\n", treasury.String()))
	sb.WriteString(ufmt.Sprintf("**Fee ceiling:** %d bps (5%%)\n\n", MaxFeeBPS))

	sb.WriteString("| Lane | Fee (bps) |\n|------|-----------|\n")
	feeByLane.Iterate("", "", func(key string, val interface{}) bool {
		sb.WriteString(ufmt.Sprintf("| %s | %d |\n", key, val.(int64)))
		return false
	})
	sb.WriteString(ufmt.Sprintf("\n*Unset lanes default to %d bps.*\n", DefaultFeeBPS))
	return sb.String()
}
