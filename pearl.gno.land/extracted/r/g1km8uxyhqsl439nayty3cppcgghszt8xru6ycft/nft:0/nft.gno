package nft

import "strconv"

type Token struct {
	ID    int
	Owner string
	URI   string
}

var tokens map[int]*Token
var owners map[string][]int
var nextID int

func init() {
	tokens = make(map[int]*Token)
	owners = make(map[string][]int)
	nextID = 1
}

func Mint(to, uri string) int {
	id := nextID
	nextID++
	tokens[id] = &Token{ID: id, Owner: to, URI: uri}
	owners[to] = append(owners[to], id)
	return id
}

func Transfer(from, to string, id int) {
	t, ok := tokens[id]
	if !ok {
		panic("token not found")
	}
	if t.Owner != from {
		panic("not owner")
	}
	t.Owner = to
	owners[to] = append(owners[to], id)
	newList := make([]int, 0)
	for _, tid := range owners[from] {
		if tid != id {
			newList = append(newList, tid)
		}
	}
	owners[from] = newList
}

func OwnerOf(id int) string {
	return tokens[id].Owner
}

func TokensOf(addr string) []int {
	return owners[addr]
}

func Render(_ string) string {
	return "nft realm - " + strconv.Itoa(len(tokens)) + " tokens minted\n"
}
