package nisse

type PearlPurse struct {
	Holdings map[string]uint64
}

var pearls map[string]*PearlPurse
var latestPearlTransfer map[string]string

func init() {
	pearls = make(map[string]*PearlPurse)
	latestPearlTransfer = make(map[string]string)
}

func pearlOriginMark(playerKey string) string { return "p:" + playerKey }

func ensurePearlPouch(playerKey string) *PearlPurse {
	if pearls[playerKey] == nil {
		pearls[playerKey] = &PearlPurse{Holdings: make(map[string]uint64)}
	}
	return pearls[playerKey]
}

func totalPearls(playerKey string) uint64 {
	total := uint64(0)
	for _, v := range ensurePearlPouch(playerKey).Holdings {
		total += v
	}
	return total
}

func recordPearlTransfer(playerKey string, description string) {
	latestPearlTransfer[playerKey] = description
}

func mintInitialPearls(playerKey string, amount uint64) {
	if amount == 0 {
		return
	}
	ensurePearlPouch(playerKey).Holdings[pearlOriginMark(playerKey)] += amount
}

func spendPearls(playerKey string, amount uint64, note string) {
	if amount == 0 {
		return
	}
	pouch := ensurePearlPouch(playerKey)
	remaining := amount
	for k, v := range pouch.Holdings {
		if remaining == 0 {
			break
		}
		use := v
		if use > remaining {
			use = remaining
		}
		pouch.Holdings[k] -= use
		if pouch.Holdings[k] == 0 {
			delete(pouch.Holdings, k)
		}
		remaining -= use
	}
	if remaining > 0 {
		panic("not enough pearls")
	}
	if note != "" {
		recordPearlTransfer(playerKey, note)
	}
}



