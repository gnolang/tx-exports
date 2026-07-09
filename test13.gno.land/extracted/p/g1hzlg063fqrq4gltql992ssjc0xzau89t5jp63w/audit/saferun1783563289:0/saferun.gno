package saferun

type SafeRunner struct{}

func (r *SafeRunner) Run(fn func()) {
	defer func() { recover() }()
	fn()
}

var PSafe = &SafeRunner{}
