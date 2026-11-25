package slotswitch_smoke

import (
	"chain/runtime"
	"chain/runtime/unsafe"
	"strconv"
	"time"
)

type checkIn struct {
	height int64
	at     int64
}

var checkIns = make(map[address]checkIn)
var total int

// CheckIn records one test action per signer.
func CheckIn(cur realm) {
	runtime.AssertOriginCall()
	if !cur.Previous().IsUserCall() || len(unsafe.OriginSend()) != 0 {
		panic("use a direct wallet call with no attached funds")
	}
	caller := cur.Previous().Address()
	if _, exists := checkIns[caller]; exists {
		return
	}
	checkIns[caller] = checkIn{height: runtime.ChainHeight(), at: time.Now().Unix()}
	total++
}

func Total() int {
	return total
}

func SignedAt(signer address) int64 {
	return checkIns[signer].height
}

func SignedTime(signer address) int64 {
	return checkIns[signer].at
}

func Render(path string) string {
	return "# SlotSwitch testnet smoke test\n\n" +
		"Confirmed wallet check-ins: **" + strconv.Itoa(total) + "**.\n\n" +
		"Use the Actions tab to call CheckIn with an Onyx test wallet."
}
