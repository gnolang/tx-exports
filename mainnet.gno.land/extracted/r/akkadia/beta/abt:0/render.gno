package abt

import (
	"strconv"
	"strings"
)

func Render(path string) string {
	if path == "" {
		return token.RenderHome() + "* **Frozen**: " + strconv.FormatBool(frozen) + "\n"
	}
	if strings.HasPrefix(path, "balance/") {
		owner := address(strings.TrimPrefix(path, "balance/"))
		if owner.IsValid() {
			return strconv.FormatInt(BalanceOf(owner), 10)
		}
	}
	return "404"
}
