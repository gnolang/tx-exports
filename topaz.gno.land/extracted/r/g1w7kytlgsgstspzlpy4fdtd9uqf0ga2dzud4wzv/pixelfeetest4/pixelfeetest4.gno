package pixelfeetest4

import (
	"strconv"
	"strings"

	"chain"
	"chain/banker"
	runtime "chain/runtime"
	unsaferealm "chain/runtime/unsafe"

	"gno.land/p/nt/avl/v0"
	"gno.land/p/nt/ufmt/v0"
)

const (
	InitialMinX, InitialMaxX = int64(0), int64(63)
	InitialMinY, InitialMaxY = int64(0), int64(63)

	MaxBoardDim = 128
	ExpandStep  = 8

	ExpandThresholdPercent = 80

	CooldownBlocks = 1

	FeePerPixelUgnot = 100_000
	VandalismFeeUgnot = 1_000_000

	MaxBulkPixels = 10
)

var palette = []string{
	"#000000", "#ffffff", "#808080", "#ef4444",
	"#fb923c", "#facc15", "#4ade80", "#3b82f6", "#a855f7",
}

const collectionOwner address = "g1w7kytlgsgstspzlpy4fdtd9uqf0ga2dzud4wzv"

var (
	minX, maxX = InitialMinX, InitialMaxX
	minY, maxY = InitialMinY, InitialMaxY

	grid            avl.Tree
	placedBy        avl.Tree
	placedAtHeight  avl.Tree
	lastPlacedBlock avl.Tree
	placementCounts avl.Tree
	officialTarget  avl.Tree

	totalPlacements int64
	occupiedCells   int64
	expansionsCount int64

	migrationOpen = true
)

func key(x, y int64) string {
	return strconv.FormatInt(x, 10) + "," + strconv.FormatInt(y, 10)
}

func callerAddress() address {
	return unsaferealm.PreviousRealm().Address()
}

func assertOwner() {
	if callerAddress() != collectionOwner {
		panic("owner-only")
	}
}

func getPixel(x, y int64) int64 {
	if c, ok := grid.Get(key(x, y)).(int64); ok {
		return c
	}
	return 0
}

func boardArea() int64  { return (maxX - minX + 1) * (maxY - minY + 1) }
func boardWidth() int64 { return maxX - minX + 1 }

func maybeExpand() {
	if boardWidth() >= MaxBoardDim {
		return
	}
	if occupiedCells*100 < boardArea()*ExpandThresholdPercent {
		return
	}
	expand()
}

func expand() {
	step := int64(ExpandStep)
	if boardWidth()+2*step > MaxBoardDim {
		step = (MaxBoardDim - boardWidth()) / 2
	}
	if step <= 0 {
		return
	}
	minX -= step
	maxX += step
	minY -= step
	maxY += step
	expansionsCount++
}

func ForceExpand(cur realm) {
	assertOwner()
	if boardWidth() >= MaxBoardDim {
		panic("already at max board size")
	}
	expand()
}

func inBounds(x, y int64) bool {
	return x >= minX && x <= maxX && y >= minY && y <= maxY
}

func recordPlacement(x, y, colorIndex int64, placer address, height int64) {
	k := key(x, y)
	wasDefault := grid.Get(k) == nil
	if colorIndex == 0 {
		grid.Remove(k)
		if !wasDefault {
			occupiedCells--
		}
	} else {
		grid.Set(k, colorIndex)
		if wasDefault {
			occupiedCells++
		}
	}
	placedBy.Set(k, placer.String())
	placedAtHeight.Set(k, height)
	bumpPlacementCount(placer)
}

func bumpPlacementCount(placer address) {
	k := placer.String()
	count, _ := placementCounts.Get(k).(int64)
	placementCounts.Set(k, count+1)
}

func isOfficialTarget(x, y, colorIndex int64) bool {
	c, ok := officialTarget.Get(key(x, y)).(int64)
	return ok && c == colorIndex
}

func inOfficialTargetArea(x, y int64) bool {
	_, ok := officialTarget.Get(key(x, y)).(int64)
	return ok
}

func IsOfficialTarget(x, y, colorIndex int64) bool { return isOfficialTarget(x, y, colorIndex) }
func InOfficialTargetArea(x, y int64) bool         { return inOfficialTargetArea(x, y) }

func pixelFee(x, y, colorIndex int64) int64 {
	if isOfficialTarget(x, y, colorIndex) {
		return 0
	}
	if inOfficialTargetArea(x, y) {
		return VandalismFeeUgnot
	}
	return FeePerPixelUgnot
}

func FeePerPixel() int64          { return FeePerPixelUgnot }
func VandalismFeePerPixel() int64 { return VandalismFeeUgnot }
func MaxBulkPixelsPerTx() int64   { return MaxBulkPixels }

func SetOfficialTarget(cur realm, encoded string) {
	assertOwner()
	officialTarget = avl.Tree{}
	if encoded == "" {
		return
	}
	for _, entry := range strings.Split(encoded, ";") {
		parts := strings.SplitN(entry, ",", 3)
		if len(parts) != 3 {
			panic("malformed entry: " + entry)
		}
		x, err1 := strconv.ParseInt(parts[0], 10, 64)
		y, err2 := strconv.ParseInt(parts[1], 10, 64)
		c, err3 := strconv.ParseInt(parts[2], 10, 64)
		if err1 != nil || err2 != nil || err3 != nil {
			panic("malformed entry: " + entry)
		}
		officialTarget.Set(key(x, y), c)
	}
}

func collectPayment(cur realm, feeUgnot int64) {
	if !unsaferealm.PreviousRealm().IsUserCall() {
		panic("payment must come from a direct user call")
	}
	sent := unsaferealm.OriginSend()
	var total int64
	for _, c := range sent {
		if c.Denom == "ugnot" {
			total += c.Amount
		}
	}
	if total < feeUgnot {
		panic(ufmt.Sprintf("insufficient payment: this placement costs %d ugnot, got %d", feeUgnot, total))
	}
	banker_ := banker.NewBanker(banker.BankerTypeRealmSend, cur)
	banker_.SendCoins(cur.Address(), collectionOwner, chain.Coins{chain.NewCoin("ugnot", feeUgnot)})
}

func SetPixel(cur realm, x, y, colorIndex int64) {
	runtime.AssertOriginCall()
	maybeExpand()
	if !inBounds(x, y) {
		panic("out of bounds")
	}
	if colorIndex < 0 || colorIndex >= int64(len(palette)) {
		panic("invalid color index")
	}
	caller := callerAddress()
	callerKey := caller.String()
	if last, ok := lastPlacedBlock.Get(callerKey).(int64); ok {
		elapsed := runtime.ChainHeight() - last
		if elapsed < CooldownBlocks {
			panic(ufmt.Sprintf("cooldown active: %d more block(s) to wait", CooldownBlocks-elapsed))
		}
	}
	if fee := pixelFee(x, y, colorIndex); fee > 0 {
		collectPayment(cur, fee)
	}
	recordPlacement(x, y, colorIndex, caller, runtime.ChainHeight())
	lastPlacedBlock.Set(callerKey, runtime.ChainHeight())
	totalPlacements++
}

func ImportHistoricalPixel(cur realm, x, y, colorIndex int64, originalPlacer address, originalHeight int64) {
	assertOwner()
	if !migrationOpen {
		panic("migration window is closed")
	}
	if colorIndex < 0 || colorIndex >= int64(len(palette)) {
		panic("invalid color index")
	}
	for x < minX || x > maxX || y < minY || y > maxY {
		if boardWidth() >= MaxBoardDim {
			panic("historical coordinate exceeds MaxBoardDim -- cannot import")
		}
		expand()
	}
	recordPlacement(x, y, colorIndex, originalPlacer, originalHeight)
	totalPlacements++
}

func CloseMigrationWindow(cur realm) {
	assertOwner()
	migrationOpen = false
}

func MigrationOpen() bool { return migrationOpen }

func GetPixel(x, y int64) int64 { return getPixel(x, y) }

func PlacedBy(x, y int64) (address, int64) {
	k := key(x, y)
	addr, _ := placedBy.Get(k).(string)
	height, _ := placedAtHeight.Get(k).(int64)
	return address(addr), height
}

func Bounds() (int64, int64, int64, int64) { return minX, maxX, minY, maxY }

func BoardWidth() int64  { return boardWidth() }
func BoardHeight() int64 { return maxY - minY + 1 }

func TotalPlacements() int64 { return totalPlacements }
func OccupiedCells() int64   { return occupiedCells }
func ExpansionsCount() int64 { return expansionsCount }

func PaletteCSV() string { return strings.Join(palette, ",") }

func CooldownRemaining(addr address) int64 {
	last, ok := lastPlacedBlock.Get(addr.String()).(int64)
	if !ok {
		return 0
	}
	elapsed := runtime.ChainHeight() - last
	if elapsed >= CooldownBlocks {
		return 0
	}
	return CooldownBlocks - elapsed
}

func Render(path string) string { return "ok" }
