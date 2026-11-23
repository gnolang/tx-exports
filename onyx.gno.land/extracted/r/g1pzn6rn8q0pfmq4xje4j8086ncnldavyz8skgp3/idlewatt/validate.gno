package idlewatt

import "strconv"

// Input limits.
const (
	minNameLen     = 3
	maxNameLen     = 48
	maxHardwareLen = 80
	minRegionLen   = 2
	maxRegionLen   = 40
	maxWorkloadLen = 60
	maxNoteLen     = 60
	maxRateCents   = 100000 // $1,000/hour sanity cap
	maxJobMinutes  = 24 * 60
)

// isSafeChar is the character whitelist for every free-text field. It keeps
// operator-supplied strings from injecting markdown, HTML, gnoweb tags or
// table pipes into Render output, and keeps them single-line.
func isSafeChar(c rune) bool {
	switch {
	case c >= 'a' && c <= 'z', c >= 'A' && c <= 'Z', c >= '0' && c <= '9':
		return true
	}
	switch c {
	case ' ', '-', '.', ',', '(', ')', '\'', '/', '+', ':', '@', '#', '%', '&', '=':
		return true
	}
	return false
}

// checkText validates a free-text field and panics with a readable message.
func checkText(field, s string, minLen, maxLen int) {
	if len(s) < minLen || len(s) > maxLen {
		panic(field + " must be " + strconv.Itoa(minLen) + "-" + strconv.Itoa(maxLen) + " characters")
	}
	if s[0] == ' ' || s[len(s)-1] == ' ' {
		panic(field + " must not start or end with a space")
	}
	for _, c := range s {
		if !isSafeChar(c) {
			panic(field + " contains an unsupported character: only letters, digits, spaces and - . , ( ) ' / + : @ # % & = are allowed")
		}
	}
}

func checkKind(kind string) {
	switch kind {
	case KindHomeGPU, KindVehicle, KindCPU:
		return
	}
	panic("kind must be one of: home-gpu, vehicle, cpu")
}

func checkPower(power string) {
	switch power {
	case PowerGrid, PowerSolar, PowerPowershare:
		return
	}
	panic("power must be one of: grid, solar, powershare-backup")
}

func checkRate(rate int64) {
	if rate < 1 || rate > maxRateCents {
		panic("rate must be between 1 and " + strconv.Itoa(maxRateCents) + " US cents per hour")
	}
}

func checkMode(kind, mode string) {
	switch mode {
	case ModeAvailable, ModePaused:
		return
	case ModeDriving:
		if kind != KindVehicle {
			panic("only vehicle nodes can be set to driving")
		}
		return
	}
	panic("mode must be one of: available, driving, paused")
}
