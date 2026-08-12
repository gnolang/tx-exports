package pixelbadgetest1

import (
	"encoding/base64"
	"strconv"
	"strings"

	"gno.land/p/nt/avl/v0"
	"gno.land/p/nt/ufmt/v0"
)

const (
	iconUnit = 12
	iconW    = 15
	iconH    = 25

	captionH = 74
	margin   = 12
)

var palette = []string{
	"#000000", "#ffffff", "#808080", "#ef4444",
	"#fb923c", "#facc15", "#4ade80", "#3b82f6", "#a855f7",
}
var colorNames = []string{
	"Black", "White", "Gray", "Red", "Orange", "Yellow", "Green", "Blue", "Purple",
}

var (
	badges       avl.Tree
	mintedByAddr avl.Tree
	nextID       int64
)

type badgeEntry struct {
	X, Y, ColorIndex, HatColorIndex, BlockHeight int64
	Owner                                        address
}

func resolveHatColor(colorIndex int64) int64 {
	if colorIndex == 0 || colorIndex == 2 {
		return 1
	}
	return colorIndex
}

type iconRow struct{ x, w, y int64 }

var hatRows = []iconRow{
	{7, 6, 1}, {6, 7, 2}, {5, 7, 3}, {4, 7, 4}, {4, 7, 5},
	{3, 9, 6}, {3, 9, 7}, {2, 11, 8}, {2, 11, 9}, {2, 11, 10},
	{1, 13, 11}, {1, 3, 12}, {11, 3, 12},
}

var beardRows = []iconRow{
	{1, 2, 15}, {5, 5, 15}, {12, 2, 15}, {1, 13, 16}, {1, 13, 17},
	{1, 13, 18}, {1, 13, 19}, {2, 11, 20}, {4, 8, 21}, {5, 5, 22}, {6, 3, 23},
}

func badgeSVG(b badgeEntry) string {
	w := int64(iconW)*iconUnit + margin*2
	h := int64(iconH)*iconUnit + margin*2 + captionH

	var svg strings.Builder
	svg.WriteString(ufmt.Sprintf(
		`<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 %d %d" shape-rendering="crispEdges">`,
		w, h,
	))
	svg.WriteString(ufmt.Sprintf(`<rect width="100%%" height="100%%" fill="%s"/>`, palette[0]))

	hatColor := palette[b.HatColorIndex]
	for _, r := range hatRows {
		svg.WriteString(ufmt.Sprintf(
			`<rect x="%d" y="%d" width="%d" height="%d" fill="%s"/>`,
			margin+r.x*iconUnit, margin+r.y*iconUnit, r.w*iconUnit, iconUnit, hatColor,
		))
	}
	for _, r := range beardRows {
		svg.WriteString(ufmt.Sprintf(
			`<rect x="%d" y="%d" width="%d" height="%d" fill="%s"/>`,
			margin+r.x*iconUnit, margin+r.y*iconUnit, r.w*iconUnit, iconUnit, palette[2],
		))
	}

	captionY := margin + int64(iconH)*iconUnit + 26
	colorName := "Unknown"
	if b.ColorIndex >= 0 && int(b.ColorIndex) < len(colorNames) {
		colorName = colorNames[b.ColorIndex]
	}
	svg.WriteString(ufmt.Sprintf(
		`<text x="%d" y="%d" font-family="monospace" font-size="20" fill="#ecebf5">X=%d Y=%d</text>`,
		margin, captionY, b.X, b.Y,
	))
	svg.WriteString(ufmt.Sprintf(
		`<text x="%d" y="%d" font-family="monospace" font-size="20" fill="#ecebf5">COLOR=%s</text>`,
		margin, captionY+26, colorName,
	))
	svg.WriteString(ufmt.Sprintf(
		`<text x="%d" y="%d" font-family="monospace" font-size="20" fill="#ecebf5">BLOCK=%d</text>`,
		margin, captionY+52, b.BlockHeight,
	))
	svg.WriteString("</svg>")
	return svg.String()
}

func badgeDataURI(b badgeEntry) string {
	return "data:image/svg+xml;base64," + base64.StdEncoding.EncodeToString([]byte(badgeSVG(b)))
}

func MintBadge(cur realm, to address, x, y, colorIndex, blockHeight int64) string {
	key := to.String()
	if existing, ok := mintedByAddr.Get(key).(string); ok {
		return existing
	}
	tid := strconv.FormatInt(nextID, 10)
	nextID++
	badges.Set(tid, badgeEntry{
		X: x, Y: y, ColorIndex: colorIndex,
		HatColorIndex: resolveHatColor(colorIndex),
		BlockHeight:   blockHeight, Owner: to,
	})
	mintedByAddr.Set(key, tid)
	return tid
}

func HasBadge(addr address) bool {
	_, ok := mintedByAddr.Get(addr.String()).(string)
	return ok
}

func BadgeIDOf(addr address) string {
	tid, _ := mintedByAddr.Get(addr.String()).(string)
	return tid
}

func BadgeImageURI(tid string) string {
	b, ok := badges.Get(tid).(badgeEntry)
	if !ok {
		return ""
	}
	return badgeDataURI(b)
}

func TotalBadges() int64 { return nextID }

func Render(path string) string {
	var b strings.Builder
	b.WriteString("# Pixel Badges\n\n")
	b.WriteString(ufmt.Sprintf("**%d badges minted so far.**\n\n", nextID))
	if path != "" {
		entry, ok := badges.Get(path).(badgeEntry)
		if ok {
			b.WriteString(ufmt.Sprintf("## Badge #%s\n\n", path))
			b.WriteString(ufmt.Sprintf("![badge](%s)\n\n", badgeDataURI(entry)))
			return b.String()
		}
	}
	badges.Iterate("", "", func(k string, v any) bool {
		entry := v.(badgeEntry)
		b.WriteString(ufmt.Sprintf("### #%s\n\n![badge](%s)\n\n", k, badgeDataURI(entry)))
		return false
	})
	return b.String()
}
