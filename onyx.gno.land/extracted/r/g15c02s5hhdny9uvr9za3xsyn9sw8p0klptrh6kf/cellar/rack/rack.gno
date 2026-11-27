// Package rack is a Cellar challenge about who may write an object, and
// why a read-only view of a /p/ type is not read-only.
package rack

import (
	"strings"

	"gno.land/p/g15c02s5hhdny9uvr9za3xsyn9sw8p0klptrh6kf/cellar/flag"
	"gno.land/p/nt/avl/v0"
)

// Prize is the bottle nobody has ever been promised.
const Prize = "1811 Château d'Yquem"

// Rack is the reserve rack: which bottle is set aside for which guest.
type Rack struct {
	Keeper   address
	Reserved *avl.Tree // guest address -> bottle
}

// Ledger is posted on the door for every realm to read. Other realms can
// import it but cannot change it: Gno makes their view of it read-only.
var Ledger = &Rack{
	Keeper:   address("g15c02s5hhdny9uvr9za3xsyn9sw8p0klptrh6kf"),
	Reserved: avl.NewTree(),
}

// Reserve sets a bottle aside for guest. Only the keeper reserves, and the
// keeper never reserves the Prize.
func Reserve(cur realm, guest address, bottle string) {
	if cur.Previous().Address() != Ledger.Keeper {
		panic("rack: only the keeper reserves bottles")
	}
	if bottle == Prize {
		panic("rack: the keeper would never")
	}
	Ledger.Reserved.Set(guest.String(), bottle)
}

// Collect hands over the bottle reserved in your name. If it is the Prize,
// the flag is yours.
func Collect(cur realm) {
	player := flag.MustPlayer(cur.Previous())
	v := Ledger.Reserved.Get(player.String())
	if v == nil {
		panic("rack: nothing is reserved in your name")
	}
	if v.(string) != Prize {
		panic("rack: you collect a " + v.(string) + ". Pleasant, but not the flag")
	}
	captures.Record(player)
}

// Render shows the rack.
func Render(_ string) string {
	var b strings.Builder
	b.WriteString(flag.Card(info, captures))
	b.WriteString("\n**Keeper:** `" + Ledger.Keeper.String() + "`\n\n## Reserved\n\n")
	if Ledger.Reserved.Size() == 0 {
		b.WriteString("*Nothing set aside.*\n")
	}
	Ledger.Reserved.Iterate("", "", func(addr string, v any) bool {
		b.WriteString("- `" + addr + "`: " + v.(string) + "\n")
		return false
	})
	b.WriteString("\n## Captured by\n\n" + flag.Captures(captures, 5))
	return b.String()
}
