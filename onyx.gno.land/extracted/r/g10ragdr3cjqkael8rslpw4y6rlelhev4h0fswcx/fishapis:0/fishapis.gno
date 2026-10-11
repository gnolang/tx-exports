package fishapis

import (
	"chain"
	"chain/banker"
	"chain/runtime"
	"chain/runtime/unsafe"
	"crypto/sha256"
	"strconv"
	"time"
)

func Version() string { return "apis-1" }

func Touch(cur realm) string {
	if !cur.Previous().IsUserCall() {
		panic("eoa")
	}
	if len(unsafe.OriginSend()) != 0 {
		panic("payment")
	}
	sum := sha256.Sum256([]byte("x"))
	ms := time.Now().UnixMilli()
	chain.Emit("Touch", "h", strconv.FormatInt(runtime.ChainHeight(), 10), "ms", strconv.FormatInt(ms, 10))
	return strconv.Itoa(int(sum[0]))
}

func send(to address, amt int64, rlm realm) {
	if !rlm.IsCurrent() {
		panic("realm")
	}
	if amt == 0 {
		return
	}
	bk := banker.NewBanker(banker.BankerTypeRealmSend, rlm)
	bk.SendCoins(rlm.Address(), to, chain.Coins{{Denom: "ugnot", Amount: amt}})
}
