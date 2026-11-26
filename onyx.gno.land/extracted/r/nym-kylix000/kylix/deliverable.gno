package kylix

import (
	"chain/runtime"
	"strconv"
	"strings"
)

// MaxDeliverableBatch bounds one Deliverable query. A token offer costs two
// ledger reads; an item offer calls its collection's OwnerFn and, if
// registered, ApprovedFn, which is foreign code of unknown cost.
const MaxDeliverableBatch = 50

// Deliverable reports, for each of up to MaxDeliverableBatch comma-separated
// offer ids, whether its owner could deliver it right now and, if not, why.
// It runs the same check as SettleRing's preflight, so a
// solver can screen candidates in one query instead of one or two per offer:
//
//	{"height":123,"offers":[
//	  {"id":7,"deliverable":true,"reason":""},
//	  {"id":9,"deliverable":false,"reason":"slot g1... may spend 0 of ..., offer gives 10"},
//	  {"id":12,"deliverable":false,"reason":"not open"}]}
//
// An expired offer is reported as not deliverable with reason "expired".
// It writes nothing to Kylix, but for an item it calls the collection's
// registered functions, which may write to their own realm's storage (see
// SettleRing); as a query that costs nothing. Bridged hops need a pool too;
// that is not checked here.
func Deliverable(ids string) string {
	assertNotSettling()
	parts := strings.Split(ids, ",")
	if strings.TrimSpace(ids) == "" || len(parts) > MaxDeliverableBatch {
		panic("kylix: Deliverable takes 1 to " + strconv.Itoa(MaxDeliverableBatch) + " offer ids")
	}
	h := runtime.ChainHeight()
	var sb strings.Builder
	sb.WriteString(`{"height":`)
	sb.WriteString(strconv.FormatInt(h, 10))
	sb.WriteString(`,"offers":[`)
	for i, p := range parts {
		id, err := strconv.ParseUint(strings.TrimSpace(p), 10, 64)
		if err != nil || id == 0 {
			panic("kylix: bad offer id " + strconv.Quote(strings.TrimSpace(p)))
		}
		reason := "not open"
		if o := loadOffer(id); o != nil {
			if expired(o, h) {
				reason = "expired"
			} else {
				reason = undeliverable(o)
			}
		}
		if i > 0 {
			sb.WriteByte(',')
		}
		sb.WriteString(`{"id":`)
		sb.WriteString(u64(id))
		sb.WriteString(`,"deliverable":`)
		sb.WriteString(strconv.FormatBool(reason == ""))
		sb.WriteString(`,"reason":`)
		sb.WriteString(jsonString(reason))
		sb.WriteByte('}')
	}
	sb.WriteString(`]}`)
	return sb.String()
}
