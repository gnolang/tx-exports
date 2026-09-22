// Package gnodraw is a pay-per-pixel collaborative canvas: anyone can paint
// any pixel of a Width x Height grid in one of 15 colors by sending exactly
// Price() ugnot per pixel along with the call. Pixels can be repainted by
// anyone, for the same price. Payments are forwarded to the admin wallet
// as they arrive, and the admin paints for free.
//
// The grid logic lives in gno.land/p/g1v7s3j506wqul2zwt90awgjphpx4ztwga0926f7/canvas/v0; this realm adds the
// payment guard, the owner controls and the read API used by the web client.
package gnodraw

import (
	"chain"
	"chain/banker"
	"chain/runtime/unsafe"
	"strconv"
	"strings"

	"gno.land/p/g1v7s3j506wqul2zwt90awgjphpx4ztwga0926f7/canvas/v0"
	"gno.land/p/nt/ufmt/v0"
)

const (
	// Width and Height are fixed for the life of this version: changing
	// them would change the storage layout, so it means a new /vN.
	// 1250 x 800 is one million pixels in a 16:10 laptop aspect ratio.
	Width  = 1250
	Height = 800

	// DefaultMaxBatch bounds a single PaintBatch call so one tx cannot blow
	// the block gas limit or overflow the price arithmetic. The owner can
	// change it at runtime with SetMaxBatch, up to HardMaxBatch.
	DefaultMaxBatch = 5000
	HardMaxBatch    = 20000

	// DefaultPrice is the initial price per pixel, in ugnot (0.05 GNOT).
	DefaultPrice int64 = 50_000

	// DefaultAdmin receives every payment, paints for free and holds the
	// owner controls. Change it before deploying; TransferOwnership moves
	// it afterwards.
	DefaultAdmin = "g1v7s3j506wqul2zwt90awgjphpx4ztwga0926f7"

	Denom = "ugnot"
)

var (
	board    = canvas.New(Width, Height)
	price    = DefaultPrice
	maxBatch = DefaultMaxBatch
	owner    = address(DefaultAdmin)

	// Stats.
	revenue int64 // total ugnot ever paid for pixels
	paints  int64 // number of successful Paint/PaintBatch calls

	// Change tracking, so clients fetch only the rows that moved.
	// version bumps once per successful paint call; rowVersion holds the
	// version of the last paint that touched each row (0 = never painted).
	version    int64
	rowVersion = make([]int64, Height)
)

// Paint colors one pixel. Send exactly Price() ugnot (nothing for the admin).
func Paint(cur realm, x, y, color int) {
	if color <= 0 || color > int(canvas.MaxColor) {
		panic(canvas.ErrInvalidColor)
	}
	paint([]canvas.Pixel{{X: x, Y: y, Color: byte(color)}}, cur)
}

// PaintBatch colors up to MaxBatchSize() pixels in one call. The argument is
// "x,y,color;x,y,color;...". Send exactly Price() * count ugnot (nothing
// for the admin).
func PaintBatch(cur realm, pixels string) {
	px, err := canvas.ParsePixels(pixels)
	if err != nil {
		panic(err)
	}
	paint(px, cur)
}

// paint takes the realm as its LAST parameter on purpose: a realm first
// parameter would make it a crossing function and Previous() would then
// be this realm instead of the user.
func paint(px []canvas.Pixel, rlm realm) {
	if !rlm.IsCurrent() {
		panic("spoofed realm")
	}
	// Payment guard: unsafe.OriginSend() describes the coins attached to
	// the transaction, which only provably landed here when the caller is
	// a plain user call (no intermediate or ephemeral realm). Keep the two
	// checks together. unsafe is imported for OriginSend only; caller
	// identity always comes from the realm handle.
	if !rlm.Previous().IsUserCall() {
		panic("must be called directly by a user (maketx call)")
	}
	painter := rlm.Previous().Address()
	n := len(px)
	if n == 0 {
		panic("nothing to paint")
	}
	if n > maxBatch {
		panic(ufmt.Sprintf("too many pixels: %d > %d", n, maxBatch))
	}
	for _, p := range px {
		if err := board.Check(p); err != nil {
			panic(err)
		}
	}

	cost := price * int64(n)
	if painter == owner {
		cost = 0 // the admin paints for free
	}
	if sent := sentUgnot(unsafe.OriginSend()); sent != cost {
		panic(ufmt.Sprintf("must send exactly %d%s for %d pixel(s), got %d%s", cost, Denom, n, sent, Denom))
	}
	if cost > 0 {
		// Forward the payment to the admin right away, so nothing
		// accumulates in the realm. BankerTypeOriginSend can only move
		// what this very message sent, which is exactly cost.
		bnk := banker.NewBanker(banker.BankerTypeOriginSend, rlm)
		bnk.SendCoins(rlm.Address(), owner, chain.NewCoins(chain.NewCoin(Denom, cost)))
	}

	version++
	for _, p := range px {
		board.Set(p)
		rowVersion[p.Y] = version
	}
	revenue += cost
	paints++

	// The pixel list itself is not emitted: event attribute values are
	// size-capped by the node and a full batch exceeds it. Clients re-read
	// Rows() after a paint.
	chain.Emit("Paint",
		"painter", painter.String(),
		"count", strconv.Itoa(n),
		"paid", strconv.Itoa(int(cost))+Denom,
	)
}

// sentUgnot returns the ugnot amount in coins and rejects any other denom,
// so a caller cannot pay with something the realm does not price.
func sentUgnot(coins chain.Coins) int64 {
	var amount int64
	for _, c := range coins {
		if c.Denom != Denom {
			panic("only " + Denom + " is accepted")
		}
		amount += c.Amount
	}
	return amount
}

// --- owner controls ---

// assertOwner panics unless the verified caller behind rlm is the owner.
// The realm is deliberately not the first parameter (see paint); the
// leading blank int is the same idiom gno.land/p/nt/ownable uses.
func assertOwner(_ int, rlm realm) {
	if !rlm.IsCurrent() {
		panic("spoofed realm")
	}
	if rlm.Previous().Address() != owner {
		panic("owner only")
	}
}

// SetPrice changes the price per pixel, in ugnot. Zero makes painting free
// for everyone.
func SetPrice(cur realm, ugnot int64) {
	assertOwner(0, cur)
	if ugnot < 0 {
		panic("price must not be negative")
	}
	price = ugnot
}

// SetMaxBatch changes the maximum pixels per PaintBatch call, 1..HardMaxBatch.
func SetMaxBatch(cur realm, n int) {
	assertOwner(0, cur)
	if n < 1 || n > HardMaxBatch {
		panic(ufmt.Sprintf("max batch must be between 1 and %d", HardMaxBatch))
	}
	maxBatch = n
}

// Withdraw sends amount ugnot held by the realm to the given address.
// Payments are forwarded on arrival, so this only matters for coins sent
// to the realm outside of a paint call.
func Withdraw(cur realm, to address, amount int64) {
	assertOwner(0, cur)
	if !to.IsValid() {
		panic("invalid address")
	}
	if amount <= 0 {
		panic("amount must be positive")
	}
	bnk := banker.NewBanker(banker.BankerTypeRealmSend, cur)
	bnk.SendCoins(cur.Address(), to, chain.NewCoins(chain.NewCoin(Denom, amount)))
}

// TransferOwnership hands the admin role (payments, free painting and the
// owner controls) to newOwner.
func TransferOwnership(cur realm, newOwner address) {
	assertOwner(0, cur)
	if !newOwner.IsValid() {
		panic("invalid address")
	}
	owner = newOwner
}

// --- read API (used by the web client through vm/qeval) ---

func GetWidth() int    { return Width }
func GetHeight() int   { return Height }
func Price() int64     { return price }
func Owner() address   { return owner }
func Painted() int     { return board.Painted() }
func Revenue() int64   { return revenue }
func Paints() int64    { return paints }
func MaxBatchSize() int { return maxBatch }

// Pixel returns the color index at (x, y); 0 means never painted.
func Pixel(x, y int) int { return int(board.Get(x, y)) }

// Rows returns rows [from, to) as one hex digit per pixel, Width digits per
// row, with no separators. Clients page through the grid with it.
func Rows(from, to int) string { return board.Rows(from, to) }

// Version is the number of successful paint calls so far. Clients remember
// it and ask DirtyRows for what changed since.
func Version() int64 { return version }

// DirtyRows lists the rows painted after version `since`, as "y,y,y" in
// ascending order. DirtyRows(0) is every row that was ever painted, which
// is all a fresh client needs to load: the others are blank.
func DirtyRows(since int64) string {
	if since < 0 {
		since = 0
	}
	var sb strings.Builder
	for y, v := range rowVersion {
		if v <= since {
			continue
		}
		if sb.Len() > 0 {
			sb.WriteByte(',')
		}
		sb.WriteString(strconv.Itoa(y))
	}
	return sb.String()
}

// Palette returns the 16 palette colors as comma-separated CSS hex values,
// index 0 being the blank color.
func Palette() string {
	return strings.Join(canvas.Palette[:], ",")
}

// Render shows the game stats on gnoweb. The path is ignored.
func Render(_ string) string {
	var sb strings.Builder
	sb.WriteString("# Million Gno\n\n")
	sb.WriteString("A pay-per-pixel canvas. Pick a color, pay the price, own the pixel until someone repaints it. Payments go to the admin wallet, which paints for free.\n\n")
	sb.WriteString("| | |\n|---|---|\n")
	sb.WriteString(ufmt.Sprintf("| Size | %d x %d |\n", Width, Height))
	sb.WriteString(ufmt.Sprintf("| Price per pixel | %d%s |\n", price, Denom))
	sb.WriteString(ufmt.Sprintf("| Pixels painted | %d / %d |\n", board.Painted(), Width*Height))
	sb.WriteString(ufmt.Sprintf("| Paint calls | %d |\n", paints))
	sb.WriteString(ufmt.Sprintf("| Version | %d |\n", version))
	sb.WriteString(ufmt.Sprintf("| Revenue | %d%s |\n", revenue, Denom))
	sb.WriteString(ufmt.Sprintf("| Admin | %s |\n", owner.String()))
	sb.WriteString("\n## Palette\n\n")
	for i := 1; i <= int(canvas.MaxColor); i++ {
		sb.WriteString(ufmt.Sprintf("- %d: `%s`\n", i, canvas.Palette[i]))
	}
	sb.WriteString("\n## Paint\n\n")
	sb.WriteString("- [Paint one pixel](" + Realm + "$help&func=Paint): `Paint(x, y, color)` with `-send <price>ugnot`\n")
	sb.WriteString("- [Paint a batch](" + Realm + "$help&func=PaintBatch): `PaintBatch(\"x,y,color;x,y,color\")` with `-send <price*count>ugnot`\n")
	return sb.String()
}

// Realm is this realm's gnoweb path.
const Realm = "/r/g1v7s3j506wqul2zwt90awgjphpx4ztwga0926f7/gnodraw/v0"
