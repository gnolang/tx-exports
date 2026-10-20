// Package adtreasury is the ad station's own treasury (jae, his terminal, 2026-10-14: "it goes to a treasury
// specifically for the ad station with its own controls/governance" → "just me for now but make it upgradeable").
//
// It holds GNOT: what the ad station's weekly auctions earn (r/…/adstation sends each settled week's winning bids
// here), and whatever anyone sends to its address. One controller spends it, each spend on the record with its memo.
// The controller is Jae's cold key at first; the role moves by a two-step hand-off (SetController names, AcceptController
// takes), and the one named may be a realm — a council or a vote later calls AcceptController and Spend through a
// crossing call, so the governance can be upgraded without moving the money.
//
// Immutable, not private (gnomod.toml).
package adtreasury

import (
	"chain"
	"chain/banker"
	"strconv"
	"strings"
	"time"
)

const (
	pkgPath = "gno.land/r/g1leu8d2vsplhehcfkjg50mwgdpxdkt8tztu95wr/adtreasury" // must match gnomod.toml
	GNOT    = "ugnot"
	maxMemo = 120
	listMax = 50 // spends the page lists
)

// Payment is one spend out of the treasury, on the record for good.
type Payment struct {
	ID     int64
	To     address
	Amount int64 // ugnot
	Memo   string
	By     address // the controller that sent it
	At     int64   // unix seconds
}

var (
	controller     = address("g1ecsuj0q572jr0dhu29q9njtnmw03hyu7tyyvv6") // Jae's cold key (the realm ownership rule)
	nextController address
	spends         []Payment
	spent          int64
)

func init(cur realm) {
	if cur.Address() != chain.PackageAddress(pkgPath) {
		panic("adtreasury: deployed at a path other than pkgPath")
	}
}

// ---------------------------------------------------------------- reading --

// Address is where the treasury receives: send GNOT here.
func Address() address { return chain.PackageAddress(pkgPath) }

// Balance is the GNOT the treasury holds, in ugnot.
func Balance() int64 {
	return banker.NewReadonlyBanker().GetCoin(Address(), GNOT)
}

func Controller() address     { return controller }
func NextController() address { return nextController }
func Spent() int64            { return spent }
func Count() int              { return len(spends) }

// Get is a copy of spend id (1-based).
func Get(id int64) Payment {
	if id < 1 || id > int64(len(spends)) {
		panic("adtreasury: no such spend")
	}
	return spends[id-1]
}

// ---------------------------------------------------------------- writing --

func caller(cur realm) address {
	if !cur.IsCurrent() {
		panic("adtreasury: spoofed realm")
	}
	return cur.Previous().Address()
}

func mustControl(cur realm) address {
	who := caller(cur)
	if who != controller {
		panic("adtreasury: only the controller")
	}
	return who
}

// Spend pays ugnot to an address, by the controller, with a memo kept on the record (plain text, at most 120
// characters). Returns the spend's id.
func Spend(cur realm, to address, ugnot int64, memo string) int64 {
	by := mustControl(cur)
	if !to.IsValid() {
		panic("adtreasury: not an address")
	}
	if to == Address() {
		panic("adtreasury: the treasury cannot pay itself")
	}
	if ugnot <= 0 {
		panic("adtreasury: the amount must be positive")
	}
	if ugnot > Balance() {
		panic("adtreasury: the treasury holds only " + strconv.FormatInt(Balance(), 10) + " ugnot")
	}
	plain(memo)
	banker.NewBanker(banker.BankerTypeRealmSend, cur).SendCoins(Address(), to, chain.Coins{{GNOT, ugnot}})
	spent += ugnot
	id := int64(len(spends)) + 1
	spends = append(spends, Payment{ID: id, To: to, Amount: ugnot, Memo: memo, By: by, At: time.Now().Unix()})
	chain.Emit("Spent", "id", strconv.FormatInt(id, 10), "to", to.String(), "ugnot", strconv.FormatInt(ugnot, 10), "by", by.String())
	return id
}

// SetController names the next controller; nothing changes until they AcceptController. "" withdraws the offer.
func SetController(cur realm, to address) {
	mustControl(cur)
	if to != "" && !to.IsValid() {
		panic("adtreasury: not an address")
	}
	nextController = to
	chain.Emit("ControllerNamed", "next", to.String())
}

// AcceptController takes the controller role, by the one named (a user or a realm).
func AcceptController(cur realm) {
	who := caller(cur)
	if nextController == "" || who != nextController {
		panic("adtreasury: not the one named")
	}
	prev := controller
	controller, nextController = who, ""
	chain.Emit("ControllerChanged", "from", prev.String(), "to", who.String())
}

// plain refuses text the page would render as markup.
func plain(s string) {
	if len(s) > maxMemo {
		panic("adtreasury: the memo is at most " + strconv.Itoa(maxMemo) + " characters")
	}
	for i := 0; i < len(s); i++ {
		if s[i] < 0x20 || s[i] == 0x7f || strings.IndexByte("[]()<>`*_#|\\!~", s[i]) >= 0 {
			panic("adtreasury: the memo is plain text without markup")
		}
	}
}

// ---------------------------------------------------------------- pages --

// Render: "" the treasury and its last spends; "json" its figures.
func Render(path string) string {
	switch path {
	case "":
		return home()
	case "json":
		return `{"address":"` + Address().String() + `","balance":` + strconv.FormatInt(Balance(), 10) + `,"spent":` + strconv.FormatInt(spent, 10) +
			`,"controller":"` + controller.String() + `","next":"` + nextController.String() + `","spends":` + strconv.Itoa(len(spends)) + `}`
	}
	return "404"
}

func home() string {
	var b strings.Builder
	b.WriteString("# The ad station's treasury\n\n")
	b.WriteString("What gno.world's ad station earns: each week's winning bids, from the station's auction. One controller spends it, every spend on the record below.\n\n")
	b.WriteString("- holds: " + gnot(Balance()) + "\n")
	b.WriteString("- spent so far: " + gnot(spent) + "\n")
	b.WriteString("- controller: " + controller.String() + "\n")
	if nextController != "" {
		b.WriteString("- named to take over: " + nextController.String() + "\n")
	}
	b.WriteString("- address: " + Address().String() + "\n\n")
	if len(spends) == 0 {
		b.WriteString("_Nothing spent yet._\n")
		return b.String()
	}
	b.WriteString("## Spends\n\n")
	for i, n := len(spends)-1, 0; i >= 0 && n < listMax; i, n = i-1, n+1 {
		s := spends[i]
		b.WriteString("- #" + strconv.FormatInt(s.ID, 10) + " " + time.Unix(s.At, 0).UTC().Format("2006-01-02") + " · " + gnot(s.Amount) + " to " + s.To.String())
		if s.Memo != "" {
			b.WriteString(" · " + s.Memo)
		}
		b.WriteString("\n")
	}
	return b.String()
}

// gnot formats ugnot as GNOT, the trailing zeros trimmed.
func gnot(ugnot int64) string {
	whole, frac := ugnot/1_000_000, ugnot%1_000_000
	if frac == 0 {
		return strconv.FormatInt(whole, 10) + " GNOT"
	}
	f := strconv.FormatInt(1_000_000+frac, 10)[1:]
	return strconv.FormatInt(whole, 10) + "." + strings.TrimRight(f, "0") + " GNOT"
}
