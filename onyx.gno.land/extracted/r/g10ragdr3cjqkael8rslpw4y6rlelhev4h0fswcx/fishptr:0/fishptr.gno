package fishptr

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

func Version() string { return "ptr-1" }

func mustFish(id int) *fish {
	if id < 1 || id > minted {
		panic("fish")
	}
	return &roster[id]
}

func NameOf(id int) string { return mustFish(id).name }

func Mark(id int) {
	row := mustFish(id)
	row.on = true
	row.bite = 24
}

func Plant(caller address) int {
	if minted >= capFish {
		panic("full")
	}
	minted++
	roster[minted].owner = caller
	roster[minted].name = "Bubble"
	return minted
}
