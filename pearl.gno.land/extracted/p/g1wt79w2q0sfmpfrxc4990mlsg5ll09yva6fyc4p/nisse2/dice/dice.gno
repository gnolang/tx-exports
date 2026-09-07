package dice

import "strconv"

func Mix(source string) uint64 {
	sum := uint64(0)
	for i := 0; i < len(source); i++ {
		sum += uint64(source[i]) * uint64(i+3)
	}
	return sum
}

func PlayerSeed(name string, x uint64, y uint64, turns uint64, companionCount uint64) string {
	return name +
		":" + strconv.Itoa(int(x)) +
		":" + strconv.Itoa(int(y)) +
		":" + strconv.Itoa(int(turns)) +
		":" + strconv.Itoa(int(companionCount))
}

func Roll(seed string, salt string, mod uint64) uint64 {
	n := Mix(seed + ":" + salt)
	if mod == 0 {
		return n
	}
	return n % mod
}

func Percent(seed string, salt string) uint64 {
	return Roll(seed, salt, 100)
}

func Dice(seed string, salt string, sides uint64) uint64 {
	if sides == 0 {
		panic("dice must have at least one side")
	}
	return Roll(seed, salt, sides) + 1
}

func D20(seed string, salt string) uint64 {
	return Dice(seed, salt, 20)
}

func D10(seed string, salt string) uint64 {
	return Dice(seed, salt, 10)
}
