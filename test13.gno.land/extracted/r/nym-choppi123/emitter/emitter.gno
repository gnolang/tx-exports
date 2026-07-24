package emitter

import "chain"

func Transfer(from string, to string, amount string) {
    chain.Emit(
        "Transfer",
        "from", from,
        "to", to,
        "amount", amount,
    )
}

func Update(key string, oldValue string, newValue string) {
    chain.Emit(
        "Update",
        "key", key,
        "oldValue", oldValue,
        "newValue", newValue,
    )
}

func UserAction(user string, action string) {
    chain.Emit(
        "UserAction",
        "user", user,
        "action", action,
    )
}
