package gasprobe1789457600

import (
	gemsart "gno.land/p/g17cjym5e9hhws46lt6329pv2gtx2ay0503hgems/gemsart2"
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

func LastLen() int { return lastLen }
