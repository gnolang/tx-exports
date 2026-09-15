package gasprobe1789457288

import (
	gemsart "gno.land/p/g17cjym5e9hhws46lt6329pv2gtx2ay0503hgems/gemsart2"
)

var lastLen int

func RenderOnce(cur realm) {
	svg, _, _, _ := gemsart.RenderTokenSVG("Sapphire-1", "Gold", 3, 2, true, "0000099")
	lastLen = len(svg)
}

func LastLen() int { return lastLen }
