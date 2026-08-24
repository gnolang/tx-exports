package eventemitter

import "chain"

func EmitEvent(message string) {
    chain.Emit("EventEmitter", "message", message)
}
