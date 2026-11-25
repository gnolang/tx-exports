package heirloom

import (
	"chain/runtime"
	"chain/runtime/unsafe"
	"strconv"
)

func enter(cur realm) address {
	if !cur.IsCurrent() {
		panic("unauthorized realm")
	}
	caller := cur.Previous()
	if caller.IsUserCall() && len(unsafe.OriginSend()) > 0 {
		panic("this function does not accept coins")
	}
	return caller.Address()
}

func enterWithGNOT(cur realm) (address, int64) {
	if !cur.IsCurrent() {
		panic("unauthorized realm")
	}
	caller := cur.Previous()
	if !caller.IsUserCall() {
		panic("coins must be sent with a direct call (gnokey maketx call or a wallet)")
	}
	sent := unsafe.OriginSend()
	if len(sent) != 1 || sent[0].Denom != gnot || sent[0].Amount <= 0 {
		panic("attach the GNOT to deposit")
	}
	return caller.Address(), sent[0].Amount
}

func touchOwnWill(caller address, id int) *Will {
	w := mustGetWill(id)
	if w.Owner != caller {
		panic("only the owner can change will " + strconv.Itoa(id))
	}
	if w.isReleased() {
		panic("will " + strconv.Itoa(id) + " is already released")
	}
	mustUseMasterKey()
	w.touch()
	return w
}

func enterAsOutsider(cur realm, id int) (*Will, address) {
	caller := enter(cur)
	signer := unsafe.OriginCaller()
	w := mustGetWill(id)
	if (signer == w.Owner || caller == w.Owner) && !w.isReleased() {
		panic("you own this will: call Ping to show a sign of life")
	}
	markAlive(signer)
	return w, signer
}

func mustUseMasterKey() {
	if signedWithSessionKey() {
		panic("sign with your master key: a session key cannot create, change or ping a will")
	}
}

func markAlive(addr address) {
	if signedWithSessionKey() {
		return
	}
	if w := getActiveWill(addr); w != nil {
		w.touch()
	}
}

func signedWithSessionKey() bool {
	_, _, _, isSession := runtime.GetSessionInfo()
	return isSession
}

func mustGetWill(id int) *Will {
	w := getWill(id)
	if w == nil {
		panic("no such will")
	}
	return w
}
