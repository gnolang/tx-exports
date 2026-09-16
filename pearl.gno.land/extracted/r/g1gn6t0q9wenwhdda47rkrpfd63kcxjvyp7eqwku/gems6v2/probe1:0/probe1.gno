package probe1

import (
	runtime "chain/runtime"
)

func Render(path string) string {
	return ufmt(runtime.ChainHeight())
}

func ufmt(h int64) string { return "" }
