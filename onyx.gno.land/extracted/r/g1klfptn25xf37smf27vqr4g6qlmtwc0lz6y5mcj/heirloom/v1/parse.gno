package heirloom

import (
	"strconv"
	"strings"
	"time"

	"gno.land/p/nt/ufmt/v0"
)

func parseHeirs(list string, owner address) []*Heir {
	var heirs []*Heir
	total := 0
	for _, item := range strings.Split(list, ",") {
		addr, pct, ok := strings.Cut(strings.TrimSpace(item), ":")
		percent, err := strconv.Atoi(strings.TrimSpace(pct))
		heir := normalize(addr)
		switch {
		case !ok || err != nil:
			panic("heirs must look like g1...:70, g1...:30")
		case !heir.IsValid():
			panic("invalid heir address: " + addr)
		case heir == owner:
			panic("you cannot be your own heir")
		case heir == selfAddr:
			panic("this realm cannot be an heir")
		case percent < 1 || percent > 100:
			panic("each heir's percent must be between 1 and 100")
		}
		if len(heirs) == MaxHeirs {
			panic(ufmt.Sprintf("a will can have at most %d heirs", MaxHeirs))
		}
		for _, h := range heirs {
			if h.Addr == heir {
				panic("heir listed twice: " + heir.String())
			}
		}
		heirs = append(heirs, &Heir{Addr: heir, Percent: percent})
		total += percent
	}
	if total != 100 {
		panic(ufmt.Sprintf("heir percentages add up to %d, not 100", total))
	}
	return heirs
}

func parseSuccessor(raw address, owner address) address {
	successor := normalize(raw.String())
	switch {
	case successor == "":
		return ""
	case !successor.IsValid():
		panic("invalid successor address: " + raw.String())
	case successor == owner:
		panic("you cannot be your own successor")
	case successor == selfAddr:
		panic("this realm cannot be a successor")
	case hasDeclined(owner, successor):
		panic(successor.String() + " declined to be your successor")
	}
	return successor
}

func parseSilence(s string) time.Duration {
	digits, _ := strings.CutSuffix(strings.TrimSpace(s), "d")
	n, err := strconv.Atoi(digits)
	if err != nil || n < int(MinSilence/day) || n > int(MaxSilence/day) {
		panic(ufmt.Sprintf("silence must be a number of days from %d to %d, e.g. 180", int(MinSilence/day), int(MaxSilence/day)))
	}
	return time.Duration(n) * day
}

func normalize(addr string) address {
	return address(strings.ToLower(strings.TrimSpace(addr)))
}
