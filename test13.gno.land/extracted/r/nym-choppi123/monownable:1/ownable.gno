package monownable

import (
	"std"
	"gno.land/p/demo/ownable"
	"gno.land/p/demo/ufmt"
)

var owner = ownable.NewWithAddress("g1p4r3esnxhahp307gh5kplvnjxdgy8kguvf9znu")
var secretData string

func GetOwner() string {
	return owner.Owner().String()
}

func SetSecret(data string) {
	owner.AssertCallerIsOwner()
	secretData = data
}

func GetSecret() string {
	return secretData
}

func TransferOwnership(newOwner std.Address) {
	owner.AssertCallerIsOwner()
	owner.Transfer(newOwner)
}

func Render(_ string) string {
	output := ufmt.Sprintf("Owner: %s\n", owner.Owner().String())
	output += ufmt.Sprintf("Secret Data: %s", secretData)
	return output
}
