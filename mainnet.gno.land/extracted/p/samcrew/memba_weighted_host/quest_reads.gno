package memba_weighted_host

func (h *Host) questConfigJSON() string {
	if h.questPolicy == nil {
		return ""
	}
	return `,"questPolicy":{"target":` + quoteJSON(QuestPath) + `,"successor":` + quoteJSON(string(h.questPolicy.Successor())) + `,"signerCategory":"critical","returnStagesOnly":true,"invalidatesOtherProposals":true}`
}
func questStateJSON(s QuestState) string {
	return `{"owner":` + quoteJSON(string(s.Owner)) + `,"pendingOwner":` + quoteJSON(string(s.PendingOwner)) + `,"signer":` + quoteJSON(s.Signer) + `}`
}
func questActionJSON(a QuestAction, s QuestState) string {
	return `{"type":"quest","target":` + quoteJSON(QuestPath) + `,"operation":` + quoteJSON(string(a.Kind())) + `,"signer":` + quoteJSON(a.Key()) + `,"recipient":` + quoteJSON(string(a.Recipient())) + `,"before":` + questStateJSON(s) + `}`
}
