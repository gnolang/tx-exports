package memba_weighted_host

import "strconv"

func (h *Host) arcadeConfigJSON() string {
	if h.arcadePolicy == nil {
		return ""
	}
	return `,"arcadePolicy":{"target":` + quoteJSON(ArcadePath) + `,"successor":` + quoteJSON(string(h.arcadePolicy.Successor())) + `,"attesterCategory":"critical","unpauseCategory":"financial","emergencyPause":true,"returnStagesOnly":true,"invalidatesOtherProposals":true}`
}
func arcadeStateJSON(s ArcadeState) string {
	return `{"owner":` + quoteJSON(string(s.Owner)) + `,"pendingOwner":` + quoteJSON(string(s.PendingOwner)) + `,"paused":` + strconv.FormatBool(s.Paused) + `,"ownerListed":` + strconv.FormatBool(s.OwnerListed) + `,"daoListed":` + strconv.FormatBool(s.DAOListed) + `,"successorListed":` + strconv.FormatBool(s.SuccessorListed) + `,"subjectListed":` + strconv.FormatBool(s.SubjectListed) + `}`
}
func arcadeActionJSON(a ArcadeAction, s ArcadeState) string {
	return `{"type":"arcade","target":` + quoteJSON(ArcadePath) + `,"operation":` + quoteJSON(string(a.Kind())) + `,"recipient":` + quoteJSON(string(a.Recipient())) + `,"attester":` + quoteJSON(string(a.Attester())) + `,"before":` + arcadeStateJSON(s) + `}`
}
