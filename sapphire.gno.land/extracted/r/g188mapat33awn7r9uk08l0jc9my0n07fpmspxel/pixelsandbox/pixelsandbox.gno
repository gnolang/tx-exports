// Package pixelsandbox is a deliberately generic/throwaway practice
// deployment of the GNO Pixels design -- not the final intended realm
// name, so redeploying while the design is still changing (which it
// will be, more than once, on the way to something we're satisfied
// with) never collides with whatever the real, permanent realm ends
// up being called.
//
// Design itself matches this project's local pixelgame3 iteration:
// expandable bounds instead of a fixed size, per-pixel provenance (who
// placed it, at what block), and an owner-gated import hook for a
// possible future migration to a fresh, permanently-named deployment.
package pixelsandbox

import (
	"encoding/base64"
	"strconv"
	"strings"

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
	cellPx         = 8
)

var palette = []string{
	"#000000", "#ffffff", "#808080", "#ef4444",
	"#fb923c", "#facc15", "#4ade80", "#3b82f6", "#a855f7",
}

// collectionOwner is the address given for this project -- deploying
// account (whoever signs the addpkg transaction) and owner don't have
// to be the same address; this constant is what actually gates
// ForceExpand/ImportHistoricalPixel/CloseMigrationWindow regardless of
// who pays for the deploy itself.
const collectionOwner address = "g188mapat33awn7r9uk08l0jc9my0n07fpmspxel"

var (
	minX, maxX = InitialMinX, InitialMaxX
	minY, maxY = InitialMinY, InitialMaxY

	grid            avl.Tree
	placedBy        avl.Tree
	placedAtHeight  avl.Tree
	lastPlacedBlock avl.Tree

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
}

func SetPixel(cur realm, x, y, colorIndex int64) {
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

func Snapshot() string {
	var b strings.Builder
	for y := minY; y <= maxY; y++ {
		for x := minX; x <= maxX; x++ {
			b.WriteString(strconv.FormatInt(getPixel(x, y), 10))
		}
	}
	return b.String()
}

func canvasDataURI() string {
	w := (maxX - minX + 1) * cellPx
	h := (maxY - minY + 1) * cellPx
	var svg strings.Builder
	svg.WriteString(ufmt.Sprintf(
		`<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 %d %d" shape-rendering="crispEdges">`,
		w, h,
	))
	svg.WriteString(ufmt.Sprintf(`<rect width="100%%" height="100%%" fill="%s"/>`, palette[0]))
	grid.Iterate("", "", func(k string, v any) bool {
		parts := strings.SplitN(k, ",", 2)
		x, _ := strconv.ParseInt(parts[0], 10, 64)
		y, _ := strconv.ParseInt(parts[1], 10, 64)
		c := v.(int64)
		svg.WriteString(ufmt.Sprintf(
			`<rect x="%d" y="%d" width="%d" height="%d" fill="%s"/>`,
			(x-minX)*cellPx, (y-minY)*cellPx, cellPx, cellPx, palette[c],
		))
		return false
	})
	svg.WriteString("</svg>")
	return "data:image/svg+xml;base64," + base64.StdEncoding.EncodeToString([]byte(svg.String()))
}

func Render(path string) string {
	var b strings.Builder
	b.WriteString("# GNO Pixels (sandbox)\n\n")
	b.WriteString(ufmt.Sprintf(
		"A %dx%d collaborative on-chain canvas (grows toward a %dx%d max as it fills). `SetPixel(x, y, colorIndex)` takes no address -- the pixel always belongs to whoever signs, and there's a %d-block cooldown per address between placements.\n\n",
		boardWidth(), maxY-minY+1, MaxBoardDim, MaxBoardDim, CooldownBlocks,
	))
	b.WriteString(ufmt.Sprintf(
		"**Total placements:** %d | **Cells painted:** %d / %d | **Expansions so far:** %d\n\n",
		totalPlacements, occupiedCells, boardArea(), expansionsCount,
	))
	b.WriteString(ufmt.Sprintf("![canvas](%s)\n\n", canvasDataURI()))
	b.WriteString("## Palette\n\n")
	b.WriteString("| Index | Color |\n|---|---|\n")
	for i, hex := range palette {
		b.WriteString(ufmt.Sprintf("| %d | %s |\n", i, hex))
	}
	return b.String()
}
