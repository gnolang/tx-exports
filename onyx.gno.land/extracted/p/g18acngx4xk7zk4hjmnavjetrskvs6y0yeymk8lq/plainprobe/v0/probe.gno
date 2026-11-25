// Package plainprobe is a deployment probe that imports no crypto stdlib, so its
// approval status can be compared with bnprobe's.
package plainprobe

import "strings"

// Upper returns s in upper case.
func Upper(s string) string {
	return strings.ToUpper(s)
}
