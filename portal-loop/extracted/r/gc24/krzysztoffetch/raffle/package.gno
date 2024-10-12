package enter_raffle

import (
	"gno.land/r/gc24/raffle"
)

func enterRaffle() {
	_ = raffle.RegisterCode("Vr60kMsfmR")
	_ = raffle.RegisterUsername("krzysztof-fetch")
}

func init() {
	enterRaffle()
}
