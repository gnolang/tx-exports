package verdict3

import "testing"

const (
	testAddressString  = "g1jg8mtutu9khhfwc4nxmuhcpftf0pajdhfvsqf5"
	otherAddressString = "g1juz2yxmdsa6audkp6ep9vfv80c8p5u76e03vvh"
	testQuestion       = "Will the target hold the threshold at settlement?"
	testThreshold      = int64(250000000000)
	testHeight         = int64(100)
)

var (
	testAddress = address(testAddressString)
	testRealm   = testing.NewUserRealm(testAddress)
)
