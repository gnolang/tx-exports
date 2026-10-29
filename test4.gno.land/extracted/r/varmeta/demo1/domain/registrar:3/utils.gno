/*
This check module contains function to do the checking stuffs
*/
package registrar

import (
	"regexp"
	"std"
	"time"
)

var (
	defaultExpireTime             = time.Hour // 30 days
	reName                        = regexp.MustCompile(`^[a-zA-Z0-9]{1,124}\.gno$`)
)

// check for registering process
func isValidDomain(d string) bool {
	return reName.MatchString(d)
}

func GetExpirationDate(dName string) time.Time {
	return rootRegistry.GetExpirationDate(dName)
}
// for now, this function only let admin set
func SetExpirationDate(dName string, expDate time.Time) bool {
	std.AssertOriginCall()
	caller := std.GetCallerAt(2)
	if caller != admin {
		panic("unauthorize")
	}
	return rootRegistry.SetExpirationDate(dName, expDate)
}
