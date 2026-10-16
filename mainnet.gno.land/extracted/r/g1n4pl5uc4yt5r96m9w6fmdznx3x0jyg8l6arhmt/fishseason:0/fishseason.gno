// Package fishseason is the Season 1 paying board.
// The open is 2026-10-16 00:00:00 UTC. The deploy wallet sets the end, posts
// up to 20 winners, and seals the board. Pay then pulls FISH from the season
// wallet to those addresses. This realm does not watch the sea and does not
// treat a fishlive Settle as a win. fishlive is not called.
// The stage script rewrites the fishtoken import to the deploy wallet's package.
// A kill still pays no FISH by itself. fishseason-1.
package fishseason

import (
	"chain"
	"chain/runtime/unsafe"
	"strconv"
	"time"

	fish "gno.land/r/g1n4pl5uc4yt5r96m9w6fmdznx3x0jyg8l6arhmt/fishtoken"
)

const (
	unit      int64 = 1_000_000
	places          = 20
	startUnix int64 = 1_792_108_800
)

var seasonAddr = address("g1m6z3l9q577dltj73ym8fu0068peupqg468r5xe")

// Whole FISH for places 1 through 20. The sum is 100,000.
var prizeWhole = [places]int64{
	16_000, 12_500, 10_000, 8_000, 7_000,
	6_000, 5_500, 5_000, 4_500, 4_000,
	3_500, 3_000, 2_800, 2_500, 2_200,
	2_000, 1_800, 1_500, 1_200, 1_000,
}

var (
	inited  bool
	admin   address
	self    address
	endUnix int64
	sealed bool
	winner [places]address
	paid   [places]bool
)

// clockUnix stays 0 on chain. The test in this package sets it. No call writes it.
var clockUnix int64

// Init records the deploy wallet as admin. It does not move FISH. No coins.
func Init(cur realm) {
	caller := requireUser(cur)
	takeExact(0)
	if inited {
		panic("fishseason: init")
	}
	admin = caller
	self = cur.Address()
	inited = true
	chain.Emit("Init", "admin", admin.String())
}

// SetEnd stores the close, as Unix seconds. The deploy wallet only, and only before seal. No coins.
func SetEnd(cur realm, unix int64) {
	caller := requireUser(cur)
	takeExact(0)
	requireReady()
	requireAdmin(caller)
	if sealed || unix <= startUnix {
		panic("fishseason: end")
	}
	endUnix = unix
	chain.Emit("End", "unix", strconv.FormatInt(unix, 10))
}

// SetPlace posts one winner. Places are 1 through 20. The same address cannot take two places. No coins.
func SetPlace(cur realm, place int, who address) {
	caller := requireUser(cur)
	takeExact(0)
	requireReady()
	requireAdmin(caller)
	if sealed {
		panic("fishseason: seal")
	}
	slot := slotOf(place)
	if !who.IsValid() || who == seasonAddr || who == cur.Address() {
		panic("fishseason: addr")
	}
	for i := 0; i < places; i++ {
		if i != slot && winner[i] == who {
			panic("fishseason: dup")
		}
	}
	winner[slot] = who
	chain.Emit("Place", "place", strconv.Itoa(place), "who", who.String())
}

// ClearPlace removes one unsealed place. No coins.
func ClearPlace(cur realm, place int) {
	caller := requireUser(cur)
	takeExact(0)
	requireReady()
	requireAdmin(caller)
	if sealed {
		panic("fishseason: seal")
	}
	winner[slotOf(place)] = address("")
	chain.Emit("Clear", "place", strconv.Itoa(place))
}

// Seal freezes the end and the places. At least one place must be posted. No coins.
func Seal(cur realm) {
	caller := requireUser(cur)
	takeExact(0)
	requireReady()
	requireAdmin(caller)
	if sealed || endUnix == 0 || filled() < 1 {
		panic("fishseason: seal")
	}
	sealed = true
	chain.Emit("Seal", "end", strconv.FormatInt(endUnix, 10))
}

// Pay sends each unpaid posted prize from the season wallet to that winner.
// The board must be sealed and the close must have passed. No coins.
// fishtoken must list this realm as a distributor, and the season wallet must
// have approved this realm for the FISH. A second pay of the same place does nothing.
func Pay(cur realm) {
	requireUser(cur)
	takeExact(0)
	requireReady()
	if !sealed {
		panic("fishseason: seal")
	}
	if nowUnix() < endUnix {
		panic("fishseason: early")
	}
	due := Due()
	if due == 0 {
		panic("fishseason: paid")
	}
	if !fish.IsDistributor(cur.Address()) {
		panic("fishseason: grant")
	}
	if fish.Allowance(seasonAddr, cur.Address()) < due {
		panic("fishseason: allowance")
	}
	n := 0
	for i := 0; i < places; i++ {
		if paid[i] || !winner[i].IsValid() {
			continue
		}
		who := winner[i]
		amt := prizeWhole[i] * unit
		paid[i] = true
		n++
		fish.TransferFrom(cross(cur), seasonAddr, who, amt)
		chain.Emit("Pay", "place", strconv.Itoa(i+1), "who", who.String(), "amount", strconv.FormatInt(amt, 10))
	}
	if n == 0 {
		panic("fishseason: paid")
	}
}

// TransferAdmin hands the board to next. Posted places stay. No coins.
func TransferAdmin(cur realm, next address) {
	caller := requireUser(cur)
	takeExact(0)
	requireReady()
	requireAdmin(caller)
	if !next.IsValid() || next == admin {
		panic("fishseason: admin")
	}
	admin = next
	chain.Emit("Admin", "next", next.String())
}

func Version() string { return "fishseason-1" }

func Admin() address { return admin }

func Realm() address { return self }

func Start() int64 { return startUnix }

func End() int64 { return endUnix }

func Sealed() bool { return sealed }

func SeasonWallet() address { return seasonAddr }

func PlaceOf(place int) address { return winner[slotOf(place)] }

func PrizeOf(place int) int64 { return prizeWhole[slotOf(place)] * unit }

func PaidOf(place int) bool { return paid[slotOf(place)] }

func Due() int64 {
	var sum int64
	for i := 0; i < places; i++ {
		if !paid[i] && winner[i].IsValid() {
			sum += prizeWhole[i] * unit
		}
	}
	return sum
}

func Render(path string) string {
	if path != "" {
		return "# Season 1\n\nUnknown path.\n"
	}
	if !inited {
		return "# Season 1\n\nNot opened.\n"
	}
	state := "open"
	if sealed {
		state = "sealed"
	}
	return "# Season 1\n\nStart " + strconv.FormatInt(startUnix, 10) +
		". End " + strconv.FormatInt(endUnix, 10) +
		". Board " + state +
		". Due " + strconv.FormatInt(Due(), 10) + " base units.\n"
}

func nowUnix() int64 {
	if clockUnix != 0 {
		return clockUnix
	}
	return time.Now().Unix()
}

func slotOf(place int) int {
	if place < 1 || place > places {
		panic("fishseason: place")
	}
	return place - 1
}

func filled() int {
	n := 0
	for i := 0; i < places; i++ {
		if winner[i].IsValid() {
			n++
		}
	}
	return n
}

func requireReady() {
	if !inited {
		panic("fishseason: init")
	}
}

func requireAdmin(caller address) {
	if caller != admin {
		panic("fishseason: admin")
	}
}

func requireUser(cur realm) address {
	if !cur.Previous().IsUserCall() {
		panic("fishseason: eoa")
	}
	return cur.Previous().Address()
}

func takeExact(n int64) {
	sent := unsafe.OriginSend()
	if n == 0 {
		if len(sent) != 0 {
			panic("fishseason: payment")
		}
		return
	}
	panic("fishseason: payment")
}
