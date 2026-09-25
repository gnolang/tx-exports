package memba_weighted_host

import "strconv"

func (h *Host) reviewsConfigJSON() string {
	if h.reviewsPolicy == nil {
		return ""
	}
	return `,"reviewsPolicy":{"target":` + quoteJSON(h.reviewsPolicy.Target()) + `,"successor":` + quoteJSON(string(h.reviewsPolicy.Successor())) + `,"moderationCategory":"routine","returnStagesOnly":true,"invalidatesOtherProposals":true}`
}
func reviewsItemJSON(i ReviewsItem) string {
	return `{"id":` + quoteJSON(strconv.FormatUint(i.ID, 10)) + `,"review":` + strconv.FormatBool(i.Review) + `,"parentId":` + quoteJSON(strconv.FormatUint(i.ParentID, 10)) + `,"subject":` + quoteJSON(i.Subject) + `,"author":` + quoteJSON(string(i.Author)) + `,"rating":` + quoteJSON(strconv.Itoa(i.Rating)) + `,"bodyHash":` + quoteJSON(i.BodyHash) + `,"createdAtHeight":` + quoteJSON(strconv.FormatInt(i.CreatedAt, 10)) + `,"editedAtHeight":` + quoteJSON(strconv.FormatInt(i.EditedAt, 10)) + `,"hidden":` + strconv.FormatBool(i.Hidden) + `,"deleted":` + strconv.FormatBool(i.Deleted) + `,"flagged":` + strconv.FormatBool(i.Flagged) + `}`
}
func reviewsStateJSON(s ReviewsState) string {
	return `{"moderator":` + quoteJSON(string(s.Moderator)) + `,"pendingModerator":` + quoteJSON(string(s.PendingModerator)) + `,"item":` + reviewsItemJSON(s.Item) + `}`
}
func reviewsActionJSON(a ReviewsAction, s ReviewsState) string {
	return `{"type":"reviews","target":` + quoteJSON(a.Target()) + `,"operation":` + quoteJSON(string(a.Kind())) + `,"id":` + quoteJSON(strconv.FormatUint(a.ID(), 10)) + `,"recipient":` + quoteJSON(string(a.Recipient())) + `,"before":` + reviewsStateJSON(s) + `}`
}
