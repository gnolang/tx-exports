package fishcap

const capFish = 4

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

func Version() string { return "cap-1" }

func Plant(caller address) int {
	if minted >= capFish {
		panic("full")
	}
	minted++
	roster[minted].owner = caller
	roster[minted].name = "Bubble"
	roster[minted].rarity = "common"
	roster[minted].trait = "swift"
	roster[minted].bite = 24
	roster[minted].hpMax = 100
	roster[minted].hp = 100
	roster[minted].speed = 108
	roster[minted].pool = 0
	roster[minted].commitH = 1
	roster[minted].inSea = false
	roster[minted].revealed = true
	roster[minted].mustHeal = false
	return minted
}
