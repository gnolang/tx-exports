package event_emitter

import "std"

func Event01(key, value string) string {
    std.Emit("Event01", key, value)

    return "Event01-" + key + "-" + "value"
}

func Event02(key, value string) string {
    std.Emit("Event02", key, value)

    return "Event02-" + key + "-" + "value"
}

func Event03(key, value string) string {
    std.Emit("Event03", key, value)

    return "Event03-" + key + "-" + "value"
}
