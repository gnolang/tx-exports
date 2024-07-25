package events

import (
    "std"
)

var owner std.Address

func init() {
    owner = std.PrevRealm().Addr()
}

func ChangeOwner(newOwner std.Address) {
    caller := std.PrevRealm().Addr()

    if caller != owner {
        panic("access denied")
    }
    
    owner = newOwner
    std.Emit("OwnershipChange", "newOwner", newOwner.String())
}
