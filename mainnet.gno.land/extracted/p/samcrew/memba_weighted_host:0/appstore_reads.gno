package memba_weighted_host

import "strconv"

func (h *Host) appstoreConfigJSON() string {
	if h.appstorePolicy == nil {
		return ""
	}
	return `,"appstorePolicy":{"target":` + quoteJSON(AppstorePath) + `,"successor":` + quoteJSON(string(h.appstorePolicy.Successor())) + `,"treasury":` + quoteJSON(string(h.appstorePolicy.Treasury())) + `,"maxRegistrationFee":"100000000","curatorCategory":"critical","sealCategory":"critical","moderationCategory":"routine","unpauseCategory":"financial","emergencyPause":true,"returnStagesOnly":true,"invalidatesOtherProposals":true}`
}
func appstoreListingJSON(s AppstoreListing) string {
	return `{"exists":` + strconv.FormatBool(s.Exists) + `,"contentHash":` + quoteJSON(s.ContentHash) + `,"status":` + quoteJSON(s.Status) + `,"reason":` + quoteJSON(s.Reason) + `,"credit":` + strconv.FormatBool(s.Credit) + `,"flags":` + quoteJSON(strconv.Itoa(s.Flags)) + `,"clearKeys":` + quoteJSON(s.ClearKeys) + `}`
}
func appstoreStateJSON(s AppstoreState) string {
	return `{"owner":` + quoteJSON(string(s.Owner)) + `,"pendingOwner":` + quoteJSON(string(s.PendingOwner)) + `,"treasury":` + quoteJSON(string(s.Treasury)) + `,"fee":` + quoteJSON(strconv.FormatInt(s.Fee, 10)) + `,"paused":` + strconv.FormatBool(s.Paused) + `,"sealed":` + strconv.FormatBool(s.Sealed) + `,"ownerCurator":` + strconv.FormatBool(s.OwnerCurator) + `,"daoCurator":` + strconv.FormatBool(s.DAOCurator) + `,"successorCurator":` + strconv.FormatBool(s.SuccessorCurator) + `,"subjectCurator":` + strconv.FormatBool(s.SubjectCurator) + `,"listing":` + appstoreListingJSON(s.Listing) + `}`
}
func appstoreActionJSON(a AppstoreAction, s AppstoreState) string {
	return `{"type":"appstore","target":` + quoteJSON(AppstorePath) + `,"operation":` + quoteJSON(string(a.Kind())) + `,"recipient":` + quoteJSON(string(a.Recipient())) + `,"fee":` + quoteJSON(strconv.FormatInt(a.Fee(), 10)) + `,"path":` + quoteJSON(a.Path()) + `,"reason":` + quoteJSON(a.Reason()) + `,"before":` + appstoreStateJSON(s) + `}`
}
