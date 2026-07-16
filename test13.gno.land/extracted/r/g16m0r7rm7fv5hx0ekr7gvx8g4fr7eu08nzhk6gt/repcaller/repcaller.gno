package repcaller

import (
	"gno.land/r/g16m0r7rm7fv5hx0ekr7gvx8g4fr7eu08nzhk6gt/reputation"
)

func GivePoints(cur realm, target address, category string, points int64) {
	reputation.AddPoints(cross(cur), target, category, points)
}
