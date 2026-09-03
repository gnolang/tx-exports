package crazy_voting

import "strconv"

type Proposal struct {
	Title  string
	Yes    int
	No     int
	Voters map[string]bool
}

var proposals map[int]*Proposal
var nextID int

func init() {
	proposals = make(map[int]*Proposal)
	nextID = 1
}

func Create(_ realm, title string) int {
	id := nextID
	nextID++
	proposals[id] = &Proposal{Title: title, Voters: make(map[string]bool)}
	return id
}

func Vote(_ realm, id int, voter string, support bool) {
	p, ok := proposals[id]
	if !ok {
		panic("proposal not found")
	}
	if p.Voters[voter] {
		panic("already voted: " + voter)
	}
	p.Voters[voter] = true
	if support {
		p.Yes++
	} else {
		p.No++
	}
}

func Render(_ string) string {
	out := "CRAZY VOTING\n"
	for id, p := range proposals {
		out += "  #" + strconv.Itoa(id) + " " + p.Title +
			" (yes=" + strconv.Itoa(p.Yes) + " no=" + strconv.Itoa(p.No) + ")\n"
	}
	return out
}
