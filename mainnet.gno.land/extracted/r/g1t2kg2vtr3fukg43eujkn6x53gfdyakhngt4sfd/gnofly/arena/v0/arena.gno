package arena

import (
	"strconv"
	"time"

	"gno.land/p/nt/bptree/v0"
)

// The whole state of the realm. Everything is unexported and nothing below is
// ever returned by reference: the trees are /p/ types with mutator methods,
// so handing one out would be handing out write access to the realm.
var (
	version int64 // bumps on every admin write, see Version

	// Arenas exist from the first paid entry until their game is over, or
	// their lobby is empty. An arena nobody paid into is never stored.
	arenas bptree.BPTree // arena id -> *arena, with its lobby and its round

	// The last games played, for readers: their result, by arena id, and the
	// ids in the order they closed, oldest first.
	results bptree.BPTree // arena id -> encoded result, see results.gno
	closed  []string

	refundDelay int64 // seconds after a game's time limit before anyone may refund it

	escrowed int64 // ugnot owed to players: the stakes of every lobby and running game, and their unclaimed winnings

	// Winnings not claimed yet, see claims.gno.
	claims bptree.BPTree // player address -> encoded credits

	// What players won, see earnings.gno.
	earnings bptree.BPTree // player address -> encoded totals, allocated on a first settled game
	winners  ranking       // the top players by winnings

	webPath string // "/r/g1t2kg2vtr3fukg43eujkn6x53gfdyakhngt4sfd/gnofly/arena/v0", used to build links in Render
)

const defaultRefundDelay = 600 // seconds

// init runs once, when the package is added to the chain. Unlike the game
// realm this one has nothing to remember about its deployer: it has no role
// of its own.
func init(cur realm) {
	bootstrap(cur.PkgPath())
}

// bootstrap (re)creates the initial state. The tests call it to start from a
// clean slate.
func bootstrap(pkgPath string) {
	arenas = bptree.BPTree{}
	results = bptree.BPTree{}
	closed = nil
	refundDelay = defaultRefundDelay
	escrowed = 0
	claims = bptree.BPTree{}
	earnings = bptree.BPTree{}
	winners = ranking{}
	webPath = webPathOf(pkgPath)
	version = 1
}

// Version returns a counter that bumps on every admin write: the refund
// delay. Player and referee actions do not bump it.
func Version() int64 {
	return version
}

// now returns the block time in Unix seconds.
func now() int64 {
	return time.Now().Unix()
}

// webPathOf turns "gno.land/r/..." into "/r/...".
func webPathOf(pkgPath string) string {
	for i := 0; i < len(pkgPath); i++ {
		if pkgPath[i] == '/' {
			return pkgPath[i:]
		}
	}
	return ""
}

func itoa(n int64) string {
	return strconv.FormatInt(n, 10)
}
