package memba_weighted_host

import "strconv"

func (h *Host) badgesConfigJSON() string {
	if h.badgesPolicy == nil {
		return ""
	}
	return `,"badgesPolicy":{"target":` + quoteJSON(BadgesPath) + `,"successor":` + quoteJSON(string(h.badgesPolicy.Successor())) + `,"adminCategory":"critical","unpauseCategory":"financial","emergencyPause":true,"returnStagesOnly":true,"invalidatesOtherProposals":true}`
}
func badgesStateJSON(s BadgesState) string {
	return `{"owner":` + quoteJSON(string(s.Owner)) + `,"pendingOwner":` + quoteJSON(string(s.PendingOwner)) + `,"paused":` + strconv.FormatBool(s.Paused) + `,"adminCount":` + quoteJSON(strconv.Itoa(s.AdminCount)) + `,"ownerAdmin":` + strconv.FormatBool(s.OwnerAdmin) + `,"daoAdmin":` + strconv.FormatBool(s.DAOAdmin) + `,"successorAdmin":` + strconv.FormatBool(s.SuccessorAdmin) + `,"subjectAdmin":` + strconv.FormatBool(s.SubjectAdmin) + `}`
}
func badgesActionJSON(a BadgesAction, s BadgesState) string {
	return `{"type":"badges","target":` + quoteJSON(BadgesPath) + `,"operation":` + quoteJSON(string(a.Kind())) + `,"recipient":` + quoteJSON(string(a.Recipient())) + `,"subject":` + quoteJSON(string(a.Subject())) + `,"before":` + badgesStateJSON(s) + `}`
}
