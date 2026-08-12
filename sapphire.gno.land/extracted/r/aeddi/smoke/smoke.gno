// Package smoke is a throwaway realm used to prove the first user-submitted
// transaction path on a freshly reset chain: tx -> block -> tx-indexer ->
// explorer -> gnoweb render. It holds no state and grants no authority.
package smoke

import "strconv"

var deployedAt = "sapphire-1 reset smoke test"

func Render(path string) string {
	return "# sapphire smoke\n\n" +
		deployedAt + "\n\npath: " + strconv.Quote(path) + "\n"
}
