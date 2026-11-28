package bouncer

import (
	"chain"
	"chain/runtime"
	"strconv"
	"strings"

	"gno.land/p/nt/avl/v0"
	"gno.land/p/nt/seqid/v0"
)

// Request is a scan request, as returned by reads.
type Request struct {
	ID        uint64
	PkgPath   string
	Requester address
	Height    int64
	// Status is "open", "attested", "cancelled" or "closed".
	Status string
	// Note explains a closed request.
	Note string
	// Attestation is the attestation that answered the request: the new one
	// for "attested", the package's latest one (0 if none) for "closed",
	// such as an unchanged package. Added in API 3; appended so readers of
	// the older struct still parse it.
	Attestation uint64
}

type request struct {
	r Request
}

func requestKey(id uint64) string { return seqid.ID(id).String() }

// RequestScan asks the scanner bot to scan pkgpath. Each address may have
// one open request at a time.
func RequestScan(cur realm, pkgpath string) uint64 {
	if !cur.IsCurrent() {
		panic("invalid realm")
	}
	if !validPkgPath(pkgpath) {
		panic("invalid package path")
	}
	caller := cur.Previous().Address()
	if openByRequester.Has(string(caller)) {
		panic("you already have an open scan request")
	}
	id := uint64(requestID.Next())
	requests.Set(requestKey(id), &request{r: Request{
		ID:        id,
		PkgPath:   pkgpath,
		Requester: caller,
		Height:    runtime.ChainHeight(),
		Status:    "open",
	}})
	openByRequester.Set(string(caller), id)
	openRequests.Set(requestKey(id), true)
	setIn(openByPkg, pkgpath, requestKey(id))
	chain.Emit("ScanRequested", "id", requestKey(id), "pkgpath", pkgpath, "requester", caller.String())
	return id
}

// CancelRequest withdraws the caller's open request.
func CancelRequest(cur realm) {
	if !cur.IsCurrent() {
		panic("invalid realm")
	}
	caller := cur.Previous().Address()
	v := openByRequester.Get(string(caller))
	if v == nil {
		panic("no open scan request")
	}
	finishRequest(v.(uint64), "cancelled", "", 0)
}

// CloseRequest lets an attester close a request it cannot serve, such as a
// package that does not exist.
func CloseRequest(cur realm, id uint64, note string) {
	assertAttester(cur)
	if len(note) > maxNoteLen {
		panic("note too long")
	}
	v := requests.Get(requestKey(id))
	if v == nil || v.(*request).r.Status != "open" {
		panic("no open request with that id")
	}
	var att uint64
	if a, ok := Latest(v.(*request).r.PkgPath); ok {
		att = a.ID
	}
	finishRequest(id, "closed", note, att)
}

func finishRequest(id uint64, status, note string, attestation uint64) {
	rq := requests.Get(requestKey(id)).(*request)
	rq.r.Status = status
	rq.r.Note = note
	rq.r.Attestation = attestation
	openByRequester.Remove(string(rq.r.Requester))
	openRequests.Remove(requestKey(id))
	removeIn(openByPkg, rq.r.PkgPath, requestKey(id))
	chain.Emit("ScanRequestFinished", "id", requestKey(id), "pkgpath", rq.r.PkgPath, "status", status)
}

// closeRequestsFor marks every open request for pkgpath as answered by
// attestation att and returns how many there were. It
// reads only pkgpath's own open requests: open requests for other packages,
// which anyone can create, must not make Attest more expensive.
func closeRequestsFor(pkgpath string, att uint64) int {
	var ids []uint64
	if v := openByPkg.Get(pkgpath); v != nil {
		v.(*avl.Tree).Iterate("", "", func(k string, _ any) bool {
			ids = append(ids, uint64(requests.Get(k).(*request).r.ID))
			return false
		})
	}
	for _, id := range ids {
		finishRequest(id, "attested", "", att)
	}
	return len(ids)
}

// setIn sets key in the subtree of index stored under group.
func setIn(index *avl.Tree, group, key string) {
	var t *avl.Tree
	if v := index.Get(group); v != nil {
		t = v.(*avl.Tree)
	} else {
		t = avl.NewTree()
		index.Set(group, t)
	}
	t.Set(key, true)
}

// removeIn removes key from group's subtree, and the subtree once empty.
func removeIn(index *avl.Tree, group, key string) {
	v := index.Get(group)
	if v == nil {
		return
	}
	t := v.(*avl.Tree)
	t.Remove(key)
	if t.Size() == 0 {
		index.Remove(group)
	}
}

// GetRequest returns a copy of request id.
func GetRequest(id uint64) (Request, bool) {
	v := requests.Get(requestKey(id))
	if v == nil {
		return Request{}, false
	}
	return v.(*request).r, true
}

// OpenRequests returns up to limit open requests, oldest first, for the
// scanner bot.
func OpenRequests(limit int) []Request {
	out := []Request{}
	if limit <= 0 {
		return out
	}
	// seqid keys sort in ID order.
	openRequests.Iterate("", "", func(k string, _ any) bool {
		out = append(out, requests.Get(k).(*request).r)
		return len(out) >= limit
	})
	return out
}

// OpenRequestsText is OpenRequests for the scanner bot, as plain text: one
// "id pkgpath" line per open request, oldest first. Package paths never
// contain spaces or newlines.
func OpenRequestsText(limit int) string {
	var b strings.Builder
	for _, r := range OpenRequests(limit) {
		b.WriteString(strconv.FormatUint(r.ID, 10) + " " + r.PkgPath + "\n")
	}
	return b.String()
}

// LatestHashes returns "<source hash> <rule-set hash> <scanner version>" of
// pkgpath's latest attestation, or "" if there is none, so the bot can skip
// code it already scanned with the same rules and prover.
func LatestHashes(pkgpath string) string {
	a, ok := Latest(pkgpath)
	if !ok {
		return ""
	}
	return a.SourceHash + " " + a.RulesetHash + " " + a.ScannerVersion
}

// APIVersion is the registry's interface version, so the bot can tell what
// Attest takes. 2: Attest takes the dependency list (deps.gno);
// LatestHashes includes the scanner version. 3: disputes are settled by a
// re-scan (OpenDisputesText, SettleDispute); a request records the
// attestation that answered it.
func APIVersion() int { return 3 }
