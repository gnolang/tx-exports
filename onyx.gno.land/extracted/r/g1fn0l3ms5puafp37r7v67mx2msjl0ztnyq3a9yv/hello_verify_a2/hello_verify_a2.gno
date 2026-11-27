package hello_verify_a2

import (
	"chain/banker"
	"chain/runtime/unsafe"
	"strconv"
	"strings"

	"gno.land/r/g1fn0l3ms5puafp37r7v67mx2msjl0ztnyq3a9yv/hello_verify_b2"
)

var (
	realmAddr     address
	blobs         = map[string]string{}
	counterA      int64
	recoveredMsg  string
	revivedMsg    string
)

func init(cur realm) {
	realmAddr = cur.Address()
}

// WriteBlob stores a payload of `size` bytes under `key` (Test B1: storage deposit charge).
// Enforces non-payable check: OriginSend must be empty.
func WriteBlob(cur realm, key string, size int) int {
	if !cur.Previous().IsUserCall() {
		panic("must be direct EOA call")
	}
	if len(unsafe.OriginSend()) != 0 {
		panic("non-payable function: do not send coins")
	}
	if size <= 0 || size > 10000 {
		panic("size must be 1..10000")
	}
	blobs[key] = strings.Repeat("X", size)
	return len(blobs[key])
}

// DeleteBlob deletes `key` from `blobs` (Test B1: storage refund test with a 2nd account).
// Intentionally callable by any EOA in this scratch realm so we can test Account A writing
// and Account B deleting, observing who receives the storage deposit refund.
func DeleteBlob(cur realm, key string) bool {
	if !cur.Previous().IsUserCall() {
		panic("must be direct EOA call")
	}
	if len(unsafe.OriginSend()) != 0 {
		panic("non-payable function: do not send coins")
	}
	if _, ok := blobs[key]; !ok {
		panic("key not found: " + key)
	}
	delete(blobs, key)
	return true
}

// DepositMutateAndCallPanicB receives coins (-send), mutates state in A, and calls
// hello_verify_b2.MutateAndPanic (Test B2: full cross-realm rollback check).
func DepositMutateAndCallPanicB(cur realm, note string) {
	if !cur.Previous().IsUserCall() {
		panic("must be direct EOA call")
	}
	sent := unsafe.OriginSend()
	if len(sent) != 1 || sent[0].Denom != "ugnot" || sent[0].Amount <= 0 {
		panic("send single positive ugnot coin")
	}
	counterA++
	hello_verify_b2.MutateAndPanic(cross(cur), "b2:"+note)
}

// DepositMutateAndTryRecoverB receives coins (-send), mutates state in A, installs a
// standard Go defer/recover(), and calls hello_verify_b2.MutateAndPanic (Test B3a).
func DepositMutateAndTryRecoverB(cur realm, note string) (result string) {
	if !cur.Previous().IsUserCall() {
		panic("must be direct EOA call")
	}
	sent := unsafe.OriginSend()
	if len(sent) != 1 || sent[0].Denom != "ugnot" || sent[0].Amount <= 0 {
		panic("send single positive ugnot coin")
	}
	counterA++
	defer func() {
		if r := recover(); r != nil {
			recoveredMsg = "RECOVERED"
			result = "recovered"
		}
	}()
	hello_verify_b2.MutateAndPanic(cross(cur), "b3-recover:"+note)
	return "no-panic"
}

// DepositMutateAndTryReviveB receives coins (-send), mutates state in A, and tries
// Gno builtin revive() around a cross-realm call to hello_verify_b2.MutateAndPanic (Test B3b).
func DepositMutateAndTryReviveB(cur realm, note string) string {
	if !cur.Previous().IsUserCall() {
		panic("must be direct EOA call")
	}
	sent := unsafe.OriginSend()
	if len(sent) != 1 || sent[0].Denom != "ugnot" || sent[0].Amount <= 0 {
		panic("send single positive ugnot coin")
	}
	counterA++
	r := revive(func() {
		hello_verify_b2.MutateAndPanic(cross(cur), "b3-revive:"+note)
	})
	if r != nil {
		revivedMsg = "REVIVED"
		return "revived"
	}
	return "no-abort"
}

func Render(path string) string {
	bal := banker.NewReadonlyBanker().GetCoin(realmAddr, "ugnot")
	if path == "json/state" {
		return `{"realm":"hello_verify_a2","addr":"` + realmAddr.String() +
			`","realmUgnotBal":` + strconv.FormatInt(bal, 10) +
			`,"blobCount":` + strconv.Itoa(len(blobs)) +
			`,"counterA":` + strconv.FormatInt(counterA, 10) +
			`,"recoveredMsg":"` + recoveredMsg +
			`","revivedMsg":"` + revivedMsg + `"}`
	}
	return "# hello_verify_a2\n\n" +
		"- Realm Addr: `" + realmAddr.String() + "`\n" +
		"- Realm `ugnot` Balance: `" + strconv.FormatInt(bal, 10) + "`\n" +
		"- Blob Count: `" + strconv.Itoa(len(blobs)) + "`\n" +
		"- counterA: `" + strconv.FormatInt(counterA, 10) + "`\n" +
		"- recoveredMsg: `" + recoveredMsg + "`\n" +
		"- revivedMsg: `" + revivedMsg + "`\n"
}
