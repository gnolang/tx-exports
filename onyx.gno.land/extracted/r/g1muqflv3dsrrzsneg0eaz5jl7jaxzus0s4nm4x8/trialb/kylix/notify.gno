package kylix

import (
	"gno.land/r/nym-gfanton001/gnotif/v1"
)

const (
	// OfferSettledEvent is emitted once per owner when their offer settles in
	// a ring, so gnotif can deliver a notification directly to each owner.
	OfferSettledEvent = "OfferSettled"

	offerSettledTriggerName = "offer_settled"
)

// EnableNotifications opens Kylix's gnotif handle and registers the
// OfferSettled notification trigger.
//
// Kylix keeps no admin: gnotif itself enforces that this call is signed with
// the namespace owner's account key (not a session key) and sent straight to
// Kylix. Calling it from init is avoided because gno test runs without
// namespace ownership and a gnotif outage must never block deployment.
//
// Only settled offers trigger notifications. A "matching offer posted"
// trigger is deliberately omitted: PostIntent does not check balances or
// approvals, so an attacker could post and cancel unapproved offers at near
// zero cost to spam another trader's notifications, and every PostIntent
// would have to scan the book.
func EnableNotifications(cur realm) {
	guard(cur)
	me := cur.Sub(gnotif.Subpath)
	h := gnotif.Open(cross(me))
	h.Set(cross(me), offerSettledTriggerName, gnotif.Trigger{
		Event: OfferSettledEvent,
		Param: "owner",
		Title: "Offer settled",
		Body:  "Offer #{id}: gave {gave}, received {received}",
		Link:  webPath(),
	})
}
