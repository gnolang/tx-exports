package memba_notes_v1

import (
	"chain/runtime"
	"gno.land/p/samcrew/avl"
	keys "gno.land/r/samcrew/enckeys_v1"
	"strconv"
	"strings"
)

const MaxAccessRequests = 256
const RequestTTLBlocks int64 = 10000

type accessRequest struct {
	Who     address
	Expires int64
	Active  bool
	Status  string
	Last    receipt
}

var requests = avl.NewTree()

func requestKey(id [16]byte, who address) string { return idText(id) + ":" + string(who) }
func RequestAccess(cur realm, id [16]byte, opID [16]byte) {
	who := enter(cur, false)
	defer leave()
	n := live(id)
	if !cur.Previous().IsUserCall() || !encrypted(n.Mode) || who == n.Owner || contains(n.Readers, who) {
		panic("notes: request not applicable")
	}
	if opID == ([16]byte{}) {
		panic("notes: empty operation id")
	}
	h := runtime.ChainHeight()
	if h > int64(9223372036854775807)-RequestTTLBlocks {
		panic("notes: request height overflow")
	}
	key := requestKey(id, who)
	if v, ok := requests.Get(key); ok {
		r := v.(*accessRequest)
		if r.Last.Operation == opID {
			panic("notes: operation id reused")
		}
		if !r.Active && r.Status == "rejected" && r.Expires > h {
			panic("notes: request rejected recently")
		}
		if r.Active {
			if r.Expires > h {
				panic("notes: request pending")
			}
			n.RequestCount--
		}
	}
	if n.RequestCount >= MaxAccessRequests {
		panic("notes: request capacity; purge expired requests")
	}
	n.RequestCount++
	requests.Set(key, &accessRequest{who, h + RequestTTLBlocks, true, "pending", receipt{opID, who, h}})
}
func closeRequest(n *note, who address, status string, actor address, opID [16]byte) {
	v, ok := requests.Get(requestKey(n.ID, who))
	if !ok {
		panic("notes: request missing")
	}
	r := v.(*accessRequest)
	if !r.Active {
		panic("notes: request already closed")
	}
	if opID == ([16]byte{}) || opID == r.Last.Operation {
		panic("notes: invalid request operation")
	}
	h := runtime.ChainHeight()
	r.Active = false
	r.Status = status
	r.Last = receipt{opID, actor, h}
	n.RequestCount--
	// A rejection keeps the record until one full TTL after it, so neither the
	// requester nor PurgeExpiredRequests can end the re-request cooldown early.
	if status == "rejected" {
		if h > int64(9223372036854775807)-RequestTTLBlocks {
			panic("notes: request height overflow")
		}
		r.Expires = h + RequestTTLBlocks
	}
}
func CancelAccessRequest(cur realm, id [16]byte, opID [16]byte) {
	who := enter(cur, false)
	defer leave()
	n := find(id)
	closeRequest(n, who, "cancelled", who, opID)
}
func RejectAccessRequest(cur realm, id [16]byte, to address, opID [16]byte) {
	who := enter(cur, false)
	defer leave()
	mutateRejectAccessRequest(cur, who, id, to, opID)
}
func mutateRejectAccessRequest(cur realm, who address, id [16]byte, to address, opID [16]byte) {
	n := live(id)
	owner(n, who)
	closeRequest(n, keys.CanonicalAddress(to), "rejected", who, opID)
}
func acknowledgeRequests(n *note, actor address, opID [16]byte) {
	for _, who := range n.Readers {
		if v, ok := requests.Get(requestKey(n.ID, who)); ok {
			r := v.(*accessRequest)
			if r.Active {
				r.Active = false
				r.Status = "granted"
				r.Last = receipt{opID, actor, runtime.ChainHeight()}
				n.RequestCount--
			}
		}
	}
}
func requestJSON(r *accessRequest) string {
	return `{"address":` + q(string(r.Who)) + `,"expires_height":` + q(strconv.FormatInt(r.Expires, 10)) + `,"active":` + strconv.FormatBool(r.Active) + `,"status":` + q(r.Status) + `,"op_id":` + q(idText(r.Last.Operation)) + `,"actor":` + q(string(r.Last.Actor)) + `,"height":` + q(strconv.FormatInt(r.Last.Height, 10)) + `}`
}
func AccessRequestJSON(idHex string, who address) string {
	v, ok := requests.Get(requestKey(readID(idHex), keys.CanonicalAddress(who)))
	if !ok {
		return "null"
	}
	return requestJSON(v.(*accessRequest))
}
func requestStart(id [16]byte, cursor string) string {
	if cursor != "" && string(keys.CanonicalAddress(address(cursor))) != cursor {
		panic("notes: bad request cursor")
	}
	return idText(id) + ":" + cursor
}
func AccessRequestsJSON(idHex, cursor string, limit int) string {
	id := readID(idHex)
	n := find(id)
	if limit < 1 || limit > MaxPage {
		panic("notes: page limit")
	}
	start := requestStart(id, cursor)
	prefix := idText(id) + ":"
	items := []string{}
	next := ""
	requests.Iterate(start, prefix+"\xff", func(k string, v interface{}) bool {
		if cursor != "" && k == start {
			return false
		}
		items = append(items, requestJSON(v.(*accessRequest)))
		next = strings.TrimPrefix(k, prefix)
		return len(items) == limit
	})
	if len(items) < limit {
		next = ""
	}
	return `{"items":[` + strings.Join(items, ",") + `],"next_cursor":` + q(next) + `,"active_count":` + u(uint64(n.RequestCount)) + `}`
}

// At most limit records are inspected, not just removed. The returned cursor
// lets a caller sweep the full request set without an unbounded scan.
func PurgeExpiredRequests(cur realm, id [16]byte, cursor string, limit int) string {
	enter(cur, false)
	defer leave()
	n := find(id)
	if limit < 1 || limit > MaxPage {
		panic("notes: purge limit")
	}
	start := requestStart(id, cursor)
	prefix := idText(id) + ":"
	doomed := []string{}
	next := ""
	inspected := 0
	h := runtime.ChainHeight()
	requests.Iterate(start, prefix+"\xff", func(k string, v interface{}) bool {
		if cursor != "" && k == start {
			return false
		}
		r := v.(*accessRequest)
		if r.Expires <= h {
			doomed = append(doomed, k)
			if r.Active {
				n.RequestCount--
			}
		}
		inspected++
		next = strings.TrimPrefix(k, prefix)
		return inspected == limit
	})
	for _, key := range doomed {
		requests.Remove(key)
	}
	if inspected < limit {
		next = ""
	}
	return next
}

func purgeRequests(n *note, limit int) int {
	if limit == 0 {
		return 0
	}
	prefix := idText(n.ID) + ":"
	doomed := []string{}
	requests.Iterate(prefix, prefix+"\xff", func(k string, v interface{}) bool {
		r := v.(*accessRequest)
		if r.Active {
			n.RequestCount--
		}
		doomed = append(doomed, k)
		return len(doomed) == limit
	})
	for _, k := range doomed {
		requests.Remove(k)
	}
	return len(doomed)
}
