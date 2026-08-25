// Package pixels is the real, permanent GNO Pixels realm -- gno.land/r/pixelsandbox
// (this project's earlier scratch deployment, never redeployable in
// place once live) was always the deliberately generic placeholder
// name described in this project's own README, kept around exactly so
// the design could keep changing without colliding with whatever this
// real deployment ended up being called.
//
// Expandable bounds instead of a fixed size, per-pixel provenance (who
// placed it, at what block), and an owner-gated import hook for
// migrating the scratch realm's already-placed pixels into this one.
package pixels

import (
	"encoding/base64"
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
	// Starts at the full MaxBoardDim from genesis rather than the
	// original 64x64-then-auto-expand design -- with real community
	// placements landing right at the logo's edges as it neared
	// completion, waiting for the 80%-occupancy trigger would mean
	// people cramming free-form art tight against it first. Centered on
	// (31.5, 31.5), the original 64-wide board's own center, so every
	// existing target_pattern.js / migrated-pixel coordinate keeps
	// exactly the same (x, y) and lands in the same place relative to
	// the logo, just with far more breathing room around it.
	InitialMinX, InitialMaxX = int64(-32), int64(95)
	InitialMinY, InitialMaxY = int64(-32), int64(95)

	MaxBoardDim = 128
	ExpandStep  = 8

	ExpandThresholdPercent = 80

	CooldownBlocks = 1
	cellPx         = 8

	// FeePerPixelUgnot is charged for any placement that doesn't match
	// the current owner-curated official target (see officialTarget) --
	// placing toward the official design stays free, everything else
	// (free-form painting, or bulk-helping finish someone else's custom
	// canvas) costs this per cell, paid to collectionOwner.
	FeePerPixelUgnot = 100_000 // 0.1 GNOT

	// VandalismFeeUgnot applies instead of FeePerPixelUgnot when a cell
	// IS part of the official target area but the caller paints it a
	// different color than the design calls for -- overwriting/defacing
	// an in-progress logo cell costs more than painting blank free-form
	// space, so griefing the logo is strictly more expensive than
	// helping (free) or painting elsewhere (the normal rate).
	VandalismFeeUgnot = 1_000_000 // 1 GNOT

	// MaxBulkPixels bounds SetPixels' batch size -- keeps a single
	// transaction's gas/arg-size reasonable and bounds the worst-case
	// payment amount a caller has to attach.
	MaxBulkPixels = 10

	// MaxCommunityDesignPixels bounds a single submitted design -- the
	// per-byte storage deposit already prices submission naturally, this
	// is just a hard ceiling against one submission dominating the
	// realm's storage.
	MaxCommunityDesignPixels = 4000
	MaxCommunityDesignNameLen = 60
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
	placementCounts avl.Tree // address.String() -> int64, total successful placements (leaderboard)
	officialTarget  avl.Tree // key(x,y) -> int64 colorIndex, owner-curated free-to-place design

	// communityDesigns holds every community-submitted design (image trace
	// or typed text, already positioned in absolute board coordinates by
	// whoever submitted it) -- unlike officialTarget these are NOT free;
	// placing into one costs the normal FeePerPixelUgnot like anywhere
	// else, submission just makes the design visible to everyone as a
	// "help fill this in" target instead of only the submitter's own
	// browser knowing its shape.
	communityDesigns     avl.Tree // designID -> encoded "x,y,c;x,y,c;..." string
	communityDesignNames avl.Tree // designID -> display name
	communityDesignCount int64

	// firstPlacement (see the commented-out block below recordPlacement)
	// would have snapshotted each address's first placement on-chain for
	// a future airdrop -- deliberately left disabled: it's an extra write
	// bundled into a placer's own transaction, so it's an extra cost to
	// them for a snapshot that only benefits a future project they don't
	// get anything from today. Decided to build that snapshot by scanning
	// transaction history off-chain instead, whenever the airdrop
	// actually happens -- zero cost to placers now, at the price of that
	// scan needing to be built later (and needing sapphire-1 indexer
	// support confirmed at that point, which hasn't been checked yet).

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
	// recordFirstPlacementIfNeeded(placer, x, y, colorIndex, height) -- see below
}

// --- disabled: on-chain first-placement snapshot for a future airdrop ---
//
// Built and verified live on topaz-1 (pixelparttest1): correctly captured
// each address's first (x, y, colorIndex, blockHeight) exactly once,
// including through ImportHistoricalPixel's migration-replay path, and
// never overwritten by that address's later placements. Left here,
// commented out, in case the off-chain-scan approach turns out not to
// work for sapphire-1 and this needs to come back.
//
// type firstPlacementEntry struct {
// 	X, Y, ColorIndex, BlockHeight int64
// }
//
// func recordFirstPlacementIfNeeded(placer address, x, y, colorIndex, height int64) {
// 	key := placer.String()
// 	if _, ok := firstPlacement.Get(key).(firstPlacementEntry); ok {
// 		return
// 	}
// 	firstPlacement.Set(key, firstPlacementEntry{X: x, Y: y, ColorIndex: colorIndex, BlockHeight: height})
// }

// bumpPlacementCount counts every successful placement action (including
// recolors and erasures of an existing cell) toward the leaderboard --
// simpler and more transparent than trying to track "cells currently
// attributed to this address", which is a fuzzy concept on a canvas
// anyone can recolor.
func bumpPlacementCount(placer address) {
	k := placer.String()
	count, _ := placementCounts.Get(k).(int64)
	placementCounts.Set(k, count+1)
}

func isOfficialTarget(x, y, colorIndex int64) bool {
	c, ok := officialTarget.Get(key(x, y)).(int64)
	return ok && c == colorIndex
}

// inOfficialTargetArea reports whether (x, y) has ANY owner-curated
// target color registered, regardless of what colorIndex is being
// proposed -- used to tell "wrong color on a logo cell" (vandalism,
// charged VandalismFeeUgnot) apart from "cell outside the design
// entirely" (charged the normal FeePerPixelUgnot).
func inOfficialTargetArea(x, y int64) bool {
	_, ok := officialTarget.Get(key(x, y)).(int64)
	return ok
}

func IsOfficialTarget(x, y, colorIndex int64) bool { return isOfficialTarget(x, y, colorIndex) }
func InOfficialTargetArea(x, y int64) bool         { return inOfficialTargetArea(x, y) }

// pixelFee returns what a single (x, y, colorIndex) placement costs:
// free if it matches the official target exactly, VandalismFeeUgnot if
// the cell is part of the target area but the color is wrong, or the
// normal FeePerPixelUgnot for anywhere else on the board.
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

// SetOfficialTarget merges entries into the free-to-place design --
// owner-only, additive rather than replacing. Registering the full
// ~800-cell logo costs real storage deposit (measured ~0.19 GNOT/cell
// on testnet), enough that doing it in one transaction risks needing
// the whole amount upfront in a single call; additive means it can be
// split across as many affordable calls as needed, called repeatedly
// over time. encoded is "x,y,c;x,y,c;...", matching the CSV-ish
// convention already used by TopPlacers. Calling this with a
// coordinate already in the target just overwrites that one entry's
// color, same as you'd expect.
func SetOfficialTarget(cur realm, encoded string) {
	assertOwner()
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

// ClearOfficialTarget wipes the entire free-to-place design -- owner-
// only. Split out from SetOfficialTarget now that registration is
// additive, so "start over from nothing" is still possible but isn't
// the default behavior of every registration call.
func ClearOfficialTarget(cur realm) {
	assertOwner()
	officialTarget = avl.Tree{}
}

// SubmitCommunityDesign registers a new community-submitted design --
// anyone can call this, not just the owner. encoded is
// "x,y,c;x,y,c;...", already in absolute board coordinates (the
// submitter positions it client-side before submitting). Placing any
// of these cells still costs the normal FeePerPixelUgnot, same as any
// other free-form cell -- this just makes the design's shape and
// position visible on-chain so other visitors' browsers can render a
// progress bar for it and help fill it in, the same way everyone
// already helps finish the owner-curated logo.
func SubmitCommunityDesign(cur realm, name string, encoded string) string {
	runtime.AssertOriginCall()
	if len(name) > MaxCommunityDesignNameLen {
		panic(ufmt.Sprintf("name too long: max %d characters", MaxCommunityDesignNameLen))
	}
	if encoded == "" {
		panic("empty design")
	}
	entries := strings.Split(encoded, ";")
	if len(entries) > MaxCommunityDesignPixels {
		panic(ufmt.Sprintf("design too large: %d pixels, max %d", len(entries), MaxCommunityDesignPixels))
	}
	for _, entry := range entries {
		parts := strings.SplitN(entry, ",", 3)
		if len(parts) != 3 {
			panic("malformed entry: " + entry)
		}
		_, err1 := strconv.ParseInt(parts[0], 10, 64)
		_, err2 := strconv.ParseInt(parts[1], 10, 64)
		c, err3 := strconv.ParseInt(parts[2], 10, 64)
		if err1 != nil || err2 != nil || err3 != nil {
			panic("malformed entry: " + entry)
		}
		if c < 0 || c >= int64(len(palette)) {
			panic("invalid color index in design")
		}
	}
	id := "d" + strconv.FormatInt(communityDesignCount, 10)
	communityDesignCount++
	communityDesigns.Set(id, encoded)
	communityDesignNames.Set(id, name)
	return id
}

// ListCommunityDesigns returns "id,name,pixelCount;id,name,pixelCount;..."
// for every submitted design, in submission order.
func ListCommunityDesigns() string {
	var b strings.Builder
	for i := int64(0); i < communityDesignCount; i++ {
		id := "d" + strconv.FormatInt(i, 10)
		encoded, ok := communityDesigns.Get(id).(string)
		if !ok {
			continue
		}
		name, _ := communityDesignNames.Get(id).(string)
		count := len(strings.Split(encoded, ";"))
		if i > 0 {
			b.WriteString(";")
		}
		b.WriteString(id + "," + name + "," + strconv.FormatInt(int64(count), 10))
	}
	return b.String()
}

// GetCommunityDesign returns the raw "x,y,c;x,y,c;..." for one design,
// or "" if id doesn't exist.
func GetCommunityDesign(id string) string {
	encoded, _ := communityDesigns.Get(id).(string)
	return encoded
}

// RemoveCommunityDesign lets the owner delist a design (offensive name,
// spam, abuse of the free-submission path) -- owner-only moderation
// hook. Pixels already placed toward it stay exactly as painted (this
// only removes it from ListCommunityDesigns/GetCommunityDesign, it
// doesn't touch the grid), and the id is never reused.
func RemoveCommunityDesign(cur realm, id string) {
	assertOwner()
	communityDesigns.Remove(id)
	communityDesignNames.Remove(id)
}

// collectPayment verifies at least feeUgnot of ugnot was attached to
// this call (via the standard "send" field on /vm.m_call) and forwards
// exactly that much from the realm's own balance to collectionOwner,
// leaving any overpayment sitting in the realm's balance rather than
// dealing with refund complexity -- callers control how much they
// attach, so overpaying is their own choice, not something to protect
// against.
//
// chain/runtime/unsafe's own doc on OriginSend warns the envelope is
// shared across the whole call chain, so a malicious intermediate
// realm could consume it after a naive check passes (TOCTOU) -- the
// doc recommends pairing OriginSend with AssertOriginCall AND
// IsUserCall. AssertOriginCall specifically panics if invoked from
// anywhere but a top-level entry point (its own doc: "panic... when
// invoked by another method, even from the same realm or package"),
// so callers (SetPixel, SetPixels) call it themselves before reaching
// here rather than this helper calling it on their behalf.
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

// SetPixels places up to MaxBulkPixels pixels in one transaction.
// encoded is "x,y,c;x,y,c;...". Cooldown is checked and updated once
// for the whole batch rather than per pixel -- SetPixel's own per-call
// cooldown would otherwise reject every entry after the first within
// the same block, since they all execute in the same transaction/
// height. Fee is the sum of pixelFee(x, y, c) across every entry,
// collected as one payment.
func SetPixels(cur realm, encoded string) {
	runtime.AssertOriginCall()
	entries := strings.Split(encoded, ";")
	if len(entries) == 0 || len(entries) > MaxBulkPixels {
		panic(ufmt.Sprintf("SetPixels accepts 1 to %d pixels per call", MaxBulkPixels))
	}
	maybeExpand()
	caller := callerAddress()
	callerKey := caller.String()
	if last, ok := lastPlacedBlock.Get(callerKey).(int64); ok {
		elapsed := runtime.ChainHeight() - last
		if elapsed < CooldownBlocks {
			panic(ufmt.Sprintf("cooldown active: %d more block(s) to wait", CooldownBlocks-elapsed))
		}
	}

	xs := make([]int64, len(entries))
	ys := make([]int64, len(entries))
	cs := make([]int64, len(entries))
	var feeTotal int64
	for i, entry := range entries {
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
		if !inBounds(x, y) {
			panic("out of bounds")
		}
		if c < 0 || c >= int64(len(palette)) {
			panic("invalid color index")
		}
		feeTotal += pixelFee(x, y, c)
		xs[i], ys[i], cs[i] = x, y, c
	}

	if feeTotal > 0 {
		collectPayment(cur, feeTotal)
	}

	height := runtime.ChainHeight()
	for i := range xs {
		recordPlacement(xs[i], ys[i], cs[i], caller, height)
		totalPlacements++
	}
	lastPlacedBlock.Set(callerKey, height)
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

type placerCount struct {
	addr  string
	count int64
}

// TopPlacers returns up to n "address,count" pairs, semicolon-separated,
// sorted by count descending -- the leaderboard. Iterated fresh on every
// call rather than kept pre-sorted, since contributor counts are small
// enough (real participants, not per-pixel) for a plain insertion sort
// to be cheap regardless of how large the canvas itself grows. Gno's
// "sort" package predates Go's generics-based sort.Slice, so this is
// hand-rolled rather than using sort.Interface for a one-off local type.
func TopPlacers(n int64) string {
	var entries []placerCount
	placementCounts.Iterate("", "", func(k string, v any) bool {
		entries = append(entries, placerCount{k, v.(int64)})
		return false
	})
	for i := 1; i < len(entries); i++ {
		cur := entries[i]
		j := i - 1
		for j >= 0 && entries[j].count < cur.count {
			entries[j+1] = entries[j]
			j--
		}
		entries[j+1] = cur
	}
	if n >= 0 && int64(len(entries)) > n {
		entries = entries[:n]
	}
	var b strings.Builder
	for i, e := range entries {
		if i > 0 {
			b.WriteString(";")
		}
		b.WriteString(e.addr + "," + strconv.FormatInt(e.count, 10))
	}
	return b.String()
}

// FirstPlacementOf/ListParticipants/ParticipantCount -- disabled along
// with firstPlacement/recordFirstPlacementIfNeeded above. See that
// comment for why. Query shapes kept here for reference in case the
// off-chain scan doesn't pan out for sapphire-1 and this needs reviving.
//
// func FirstPlacementOf(addr address) (x, y, colorIndex, blockHeight int64, found bool) {
// 	entry, ok := firstPlacement.Get(addr.String()).(firstPlacementEntry)
// 	if !ok {
// 		return 0, 0, 0, 0, false
// 	}
// 	return entry.X, entry.Y, entry.ColorIndex, entry.BlockHeight, true
// }
//
// func ListParticipants() string {
// 	var b strings.Builder
// 	first := true
// 	firstPlacement.Iterate("", "", func(k string, v any) bool {
// 		entry := v.(firstPlacementEntry)
// 		if !first {
// 			b.WriteString(";")
// 		}
// 		first = false
// 		b.WriteString(k + "," +
// 			strconv.FormatInt(entry.X, 10) + "," +
// 			strconv.FormatInt(entry.Y, 10) + "," +
// 			strconv.FormatInt(entry.ColorIndex, 10) + "," +
// 			strconv.FormatInt(entry.BlockHeight, 10))
// 		return false
// 	})
// 	return b.String()
// }
//
// func ParticipantCount() int64 {
// 	n := int64(0)
// 	firstPlacement.Iterate("", "", func(k string, v any) bool {
// 		n++
// 		return false
// 	})
// 	return n
// }

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
	b.WriteString("# GNO Pixels\n\n")
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
