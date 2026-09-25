// Fixed badges administration and authority return. Operational badge minting
// remains with explicitly appointed admins; no arbitrary mint route is exposed.
package memba_dao

import (
	"gno.land/p/samcrew/memba_weighted_host"
	"gno.land/r/samcrew/gnobuilders_badges_v2"
)

func badgesState(a memba_weighted_host.BadgesAction) memba_weighted_host.BadgesState {
	owner := gnobuilders_badges_v2.GetOwner()
	subject := false
	if a.Subject() != "" { subject = gnobuilders_badges_v2.IsAdmin(a.Subject()) }
	return memba_weighted_host.BadgesState{
		Owner: owner, PendingOwner: gnobuilders_badges_v2.GetPendingOwner(),
		Paused: gnobuilders_badges_v2.IsPaused(), AdminCount: gnobuilders_badges_v2.GetAdminCount(),
		OwnerAdmin: gnobuilders_badges_v2.IsAdmin(owner), DAOAdmin: gnobuilders_badges_v2.IsAdmin(badgesPolicy.DAO()),
		SuccessorAdmin: gnobuilders_badges_v2.IsAdmin(badgesPolicy.Successor()), SubjectAdmin: subject,
	}
}
func proposeBadges(cur realm, a memba_weighted_host.BadgesAction) uint64 { return host.ProposeBadges(a, badgesState(a), cur) }
func ProposeBadgesAccept(cur realm) uint64 { return proposeBadges(cur, badgesPolicy.Accept()) }
func ProposeBadgesReturn(cur realm) uint64 { return proposeBadges(cur, badgesPolicy.Return()) }
func ProposeBadgesAbortReturn(cur realm) uint64 { return proposeBadges(cur, badgesPolicy.AbortReturn()) }
func ProposeBadgesAddAdmin(cur realm, who address) uint64 { return proposeBadges(cur, badgesPolicy.AddAdmin(who)) }
func ProposeBadgesRemoveAdmin(cur realm, who address) uint64 { return proposeBadges(cur, memba_weighted_host.BadgesRevokeAdmin(who)) }
func ProposeBadgesUnpause(cur realm) uint64 { return proposeBadges(cur, memba_weighted_host.BadgesResume()) }
func EmergencyPauseBadges(cur realm) {
	a := memba_weighted_host.BadgesResume()
	before := badgesState(a)
	host.PrepareBadgesEmergencyPause(before, cur)
	expected := before
	expected.Paused = true
	gnobuilders_badges_v2.Pause(cross(cur))
	if badgesState(a) != expected { panic("badges pause postcondition mismatch") }
}
func executeBadges(cur realm, id uint64) {
	proposed := host.Proposal(id).BadgesAction
	before := badgesState(proposed)
	a := host.ConsumeBadges(id, before, cur)
	expected := before
	switch a.Kind() {
	case memba_weighted_host.BadgesAcceptOwner:
		expected.Owner = badgesPolicy.DAO()
		expected.PendingOwner = ""
		expected.OwnerAdmin = true
		expected.DAOAdmin = true
		if !before.DAOAdmin { expected.AdminCount++ }
		if before.OwnerAdmin { expected.AdminCount-- }
		if before.Owner == badgesPolicy.Successor() { expected.SuccessorAdmin = false }
		gnobuilders_badges_v2.AcceptOwnership(cross(cur))
	case memba_weighted_host.BadgesReturnOwner:
		expected.PendingOwner = a.Recipient()
		gnobuilders_badges_v2.TransferOwnership(cross(cur), a.Recipient())
	case memba_weighted_host.BadgesAbortReturn:
		expected.PendingOwner = ""
		gnobuilders_badges_v2.CancelOwnershipTransfer(cross(cur))
	case memba_weighted_host.BadgesUnpause:
		expected.Paused = false
		gnobuilders_badges_v2.Unpause(cross(cur))
	case memba_weighted_host.BadgesAddAdmin, memba_weighted_host.BadgesRemoveAdmin:
		grant := a.Kind() == memba_weighted_host.BadgesAddAdmin
		expected.SubjectAdmin = grant
		if grant { expected.AdminCount++ } else { expected.AdminCount-- }
		if a.Subject() == badgesPolicy.Successor() { expected.SuccessorAdmin = grant }
		if grant { gnobuilders_badges_v2.AddAdmin(cross(cur), a.Subject()) } else { gnobuilders_badges_v2.RemoveAdmin(cross(cur), a.Subject()) }
	default:
		panic("unsupported badges action")
	}
	if badgesState(a) != expected { panic("badges postcondition mismatch") }
	if a.Kind() == memba_weighted_host.BadgesAcceptOwner && gnobuilders_badges_v2.IsAdmin(before.Owner) { panic("badges previous owner admin retained") }
}
