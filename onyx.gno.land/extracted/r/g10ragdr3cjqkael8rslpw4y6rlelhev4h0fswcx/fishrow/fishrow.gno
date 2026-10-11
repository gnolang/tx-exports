package fishrow

import (
	"crypto/sha256"
	"strconv"
)

const capFish = 128

var (
	hpBase   = [6]int{100, 122, 148, 178, 214, 256}
	biteBase = [6]int{24, 30, 37, 45, 54, 66}
	spdBase  = [6]int{108, 104, 100, 96, 92, 88}
	species  = [6]string{"Bubble", "Tideblade", "Abysswing", "Embermaw", "Aurelion", "Astravex"}
	rarities = [6]string{"common", "uncommon", "rare", "epic", "legendary", "mythic"}
	traits   = [3]string{"swift", "fang", "hide"}
)

type fish struct {
	owner    address
	name     string
	rarity   string
	trait    string
	bite     int
	hpMax    int
	hp       int
	speed    int
	pool     int64
	bouts    int
	commitH  int64
	touched  int64
	inSea    bool
	revealed bool
	mustHeal bool
}

var (
	minted int
	roster [capFish + 1]fish
)

func Version() string { return "row-1" }

func Roll(caller address, commitH int64, entropyH int64, id int) (rarity string, trait string, bite int, hp int, speed int) {
	if id < 1 || commitH < 1 || entropyH != commitH+2 {
		panic("roll")
	}
	raw := caller.String() + "|" + strconv.FormatInt(commitH, 10) + "|" + strconv.FormatInt(entropyH, 10) + "|" + strconv.Itoa(id)
	sum := sha256.Sum256([]byte(raw))
	n := (int(sum[0])<<8 | int(sum[1])) % 10000
	tier := 0
	if n == 0 {
		tier = 5
	} else if n < 4 {
		tier = 4
	} else if n < 14 {
		tier = 3
	} else if n < 54 {
		tier = 2
	} else if n < 254 {
		tier = 1
	}
	kind := int(sum[2]) % 3
	bite = biteBase[tier]
	hp = hpBase[tier]
	speed = spdBase[tier]
	if kind == 0 {
		speed = (speed*112 + 50) / 100
	} else if kind == 1 {
		bite = (bite*112 + 50) / 100
	} else {
		hp = (hp*112 + 50) / 100
	}
	return rarities[tier], traits[kind], bite, hp, speed
}

func mustFish(id int) *fish {
	if id < 1 || id > minted {
		panic("fish")
	}
	return &roster[id]
}

func TraitOf(id int) string { return mustFish(id).trait }

func Plant(caller address) int {
	if minted >= capFish {
		panic("full")
	}
	minted++
	roster[minted].owner = caller
	roster[minted].commitH = 1
	return minted
}
