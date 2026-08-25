package accesscontrol

import "chain/runtime/unsafe"

var owner address = "g1tlljkncyxtwmfdl9vpm38uq2mq55mdesek2ttr"

func OwnerOnly(_ realm, message string) string {
    if unsafe.PreviousRealm().Address() != owner {
        panic("permission denied")
    }

    return message
}
