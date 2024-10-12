package raffle_username_a_lot

import "gno.land/r/gc24/raffle"

func init() {
	for i := 0; i < 1000; i++ {
		raffle.RegisterUsername("charlysotelo")
	}

}
