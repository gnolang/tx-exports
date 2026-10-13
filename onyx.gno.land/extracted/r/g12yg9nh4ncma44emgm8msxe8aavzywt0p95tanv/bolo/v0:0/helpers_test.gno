package bolo

// panicsWith reports whether f panics with err.
func panicsWith(f func(), err Error) (ok bool) {
	defer func() {
		r := recover()
		e, isErr := r.(Error)
		ok = isErr && e == err
	}()
	f()
	return false
}
