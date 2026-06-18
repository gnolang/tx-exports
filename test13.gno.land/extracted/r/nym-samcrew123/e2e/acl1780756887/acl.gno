package acl

var locked = false
var callCount = 0

func AdminOnly(cur realm) {
	if locked {
		panic("unauthorized")
	}
	callCount++
}

func Lock(cur realm) {
	if locked {
		panic("already locked")
	}
	locked = true
}

func GetCallCount() int { return callCount }
func IsLocked() bool    { return locked }
