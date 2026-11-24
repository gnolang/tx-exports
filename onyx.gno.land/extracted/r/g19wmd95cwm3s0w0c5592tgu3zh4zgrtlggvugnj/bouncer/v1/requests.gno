package bouncer

import (
	"chain"
	"chain/runtime"
	"strconv"
	"strings"

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
	finishRequest(v.(uint64), "cancelled", "")
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
	finishRequest(id, "closed", note)
}

func finishRequest(id uint64, status, note string) {
	rq := requests.Get(requestKey(id)).(*request)
	rq.r.Status = status
	rq.r.Note = note
	openByRequester.Remove(string(rq.r.Requester))
	openRequests.Remove(requestKey(id))
	chain.Emit("ScanRequestFinished", "id", requestKey(id), "pkgpath", rq.r.PkgPath, "status", status)
}

// closeRequestsFor marks every open request for pkgpath as attested.
func closeRequestsFor(pkgpath string) {
	var ids []uint64
	openRequests.Iterate("", "", func(k string, _ any) bool {
		r := requests.Get(k).(*request).r
		if r.PkgPath == pkgpath {
			ids = append(ids, r.ID)
		}
		return false
	})
	for _, id := range ids {
		finishRequest(id, "attested", "")
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

// LatestHashes returns "<source hash> <rule-set hash>" of pkgpath's latest
// attestation, or "" if there is none, so the bot can skip unchanged code.
func LatestHashes(pkgpath string) string {
	a, ok := Latest(pkgpath)
	if !ok {
		return ""
	}
	return a.SourceHash + " " + a.RulesetHash
}
