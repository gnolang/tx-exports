package incentives

import "gno.land/p/nt/ufmt/v0"

func Version() string {
	return protoVersion
}

func DexPkg() string {
	return dexPkg
}

func Admin() address {
	return admin
}

func Paused() bool {
	return paused
}

// GaugeSnapshot is id;acc;totalFunded;on;paused (on/paused are 0/1).
func GaugeSnapshot(poolID string) string {
	acc, funded, on := int64(0), int64(0), int64(0)
	if g := tryGauge(poolID); g != nil {
		acc = g.Acc
		funded = g.TotalFunded
		on = btoi(g.On)
	}
	return ufmt.Sprintf("%s;%d;%d;%d;%d", poolID, acc, funded, on, btoi(paused))
}

func GaugeList() string {
	out := ""
	gauges.Iterate("", "", func(k string, _ any) bool {
		if out != "" {
			out += "\n"
		}
		out += k
		return false
	})
	return out
}

func Claimable(poolID string, owner address) int64 {
	return pendingOf(poolID, owner)
}
