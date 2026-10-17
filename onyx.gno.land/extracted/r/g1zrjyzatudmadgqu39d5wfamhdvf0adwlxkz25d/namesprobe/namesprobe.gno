// Package namesprobe checks whether a realm importing r/sys/names goes live.
package namesprobe

import "gno.land/r/sys/names"

func Check(addr address, ns string) bool {
	return names.IsAuthorizedAddressForNamespace(addr, ns)
}
