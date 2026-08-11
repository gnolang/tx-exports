package ucs03_zkgm

func assertIsRlmCurrent(_ int, rlm realm) {
	if !rlm.IsCurrent() {
		panic(errSpoofedRealm)
	}
}
