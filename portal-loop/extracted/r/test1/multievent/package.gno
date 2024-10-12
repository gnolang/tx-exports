package multievent

import "std"

func TwoEvent() string {
	std.Emit("TwoEvent", "key1", "value1")
	std.Emit("TwoEvent", "key2", "value2")

	return "ok"
}
