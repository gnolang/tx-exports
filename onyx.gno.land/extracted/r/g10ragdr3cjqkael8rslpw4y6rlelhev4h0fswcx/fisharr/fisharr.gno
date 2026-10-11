package fisharr

const capFish = 128

type fish struct {
	owner address
	name  string
	bite  int
	on    bool
}

var (
	minted int
	roster [capFish + 1]fish
)

func Version() string { return "arr-1" }

func Plant(caller address) int {
	if minted >= capFish {
		panic("full")
	}
	minted++
	roster[minted].owner = caller
	roster[minted].name = "Bubble"
	roster[minted].bite = 24
	roster[minted].on = true
	return minted
}
