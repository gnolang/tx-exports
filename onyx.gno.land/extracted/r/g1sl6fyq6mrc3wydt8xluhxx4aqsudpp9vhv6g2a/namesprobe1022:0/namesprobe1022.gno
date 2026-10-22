package namesprobe1022

import "gno.land/r/sys/names"

func Authorized(addr address, ns string) bool {
	return names.IsAuthorizedAddressForNamespace(addr, ns)
}
