package gasprobe_fastprng_caller

import (
	gemsart "gno.land/r/g1y4u4erj77mrz40gj0wc55k5q32ueywp6l788ha/gemsart2trimmedfast1789459000"
)

var lastLen int

func RenderRound(cur realm) {
	svg, _, _, _ := gemsart.RenderTokenSVG("Sapphire-1", "Gold", 0, 2, true, "0000099")
	lastLen = len(svg)
}

func RenderEmerald(cur realm) {
	svg, _, _, _ := gemsart.RenderTokenSVG("Sapphire-1", "Gold", 1, 2, true, "0000099")
	lastLen = len(svg)
}

func RenderRawActive(cur realm) {
	svg, _, _, _ := gemsart.RenderTokenSVG("Sapphire-1", "Gold", 3, 2, true, "0000099")
	lastLen = len(svg)
}

func LastLen() int { return lastLen }
