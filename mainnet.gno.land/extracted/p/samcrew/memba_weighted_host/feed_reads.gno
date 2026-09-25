package memba_weighted_host

import "strconv"

func (h *Host) feedConfigJSON() string {
	if h.feedPolicy == nil {
		return ""
	}
	return `,"feedPolicy":{"target":` + quoteJSON(FeedPath) + `,"successor":` + quoteJSON(string(h.feedPolicy.Successor())) + `,"moderatorCategory":"critical","unpauseCategory":"financial","emergencyPause":true,"returnStagesOnly":true,"invalidatesOtherProposals":true}`
}
func feedStateJSON(s FeedState) string {
	return `{"owner":` + quoteJSON(string(s.Owner)) + `,"pendingOwner":` + quoteJSON(string(s.PendingOwner)) + `,"paused":` + strconv.FormatBool(s.Paused) + `,"moderatorCount":` + quoteJSON(strconv.Itoa(s.ModeratorCount)) + `,"ownerModerator":` + strconv.FormatBool(s.OwnerModerator) + `,"daoModerator":` + strconv.FormatBool(s.DAOModerator) + `,"successorModerator":` + strconv.FormatBool(s.SuccessorModerator) + `,"subjectModerator":` + strconv.FormatBool(s.SubjectModerator) + `}`
}
func feedActionJSON(a FeedAction, s FeedState) string {
	return `{"type":"feed","target":` + quoteJSON(FeedPath) + `,"operation":` + quoteJSON(string(a.Kind())) + `,"recipient":` + quoteJSON(string(a.Recipient())) + `,"subject":` + quoteJSON(string(a.Subject())) + `,"before":` + feedStateJSON(s) + `}`
}
