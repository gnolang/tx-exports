package memba_weighted_host

import "strconv"

func (h *Host) channelsConfigJSON() string {
	if h.channelsPolicy==nil { return "" }
	return `,"channelsPolicy":{"target":`+quoteJSON(ChannelsPath)+`,"successor":`+quoteJSON(string(h.channelsPolicy.Successor()))+`,"memberCategory":"critical","unpauseCategory":"financial","emergencyPause":true,"returnStagesOnly":true,"invalidatesOtherProposals":true}`
}
func channelsStateJSON(s ChannelsState) string {
	return `{"owner":`+quoteJSON(string(s.Owner))+`,"pendingOwner":`+quoteJSON(string(s.PendingOwner))+`,"paused":`+strconv.FormatBool(s.Paused)+`,"memberCount":`+quoteJSON(strconv.Itoa(s.MemberCount))+`,"membershipRevision":`+quoteJSON(strconv.FormatUint(s.MembershipRevision,10))+`,"ownerMember":`+strconv.FormatBool(s.OwnerMember)+`,"daoMember":`+strconv.FormatBool(s.DAOMember)+`,"successorMember":`+strconv.FormatBool(s.SuccessorMember)+`,"subjectMember":`+strconv.FormatBool(s.SubjectMember)+`,"ownerRoles":`+quoteJSON(s.OwnerRoles)+`,"daoRoles":`+quoteJSON(s.DAORoles)+`,"successorRoles":`+quoteJSON(s.SuccessorRoles)+`,"subjectRoles":`+quoteJSON(s.SubjectRoles)+`,"channelCount":`+quoteJSON(strconv.Itoa(s.ChannelCount))+`,"channelExists":`+strconv.FormatBool(s.ChannelExists)+`,"channelDescription":`+quoteJSON(s.ChannelDescription)+`,"channelType":`+quoteJSON(s.ChannelType)+`,"channelReadRoles":`+quoteJSON(s.ChannelReadRoles)+`,"channelWriteRoles":`+quoteJSON(s.ChannelWriteRoles)+`}`
}
func channelsActionJSON(a ChannelsAction, s ChannelsState) string {
	return `{"type":"channels","target":`+quoteJSON(ChannelsPath)+`,"operation":`+quoteJSON(string(a.Kind()))+`,"recipient":`+quoteJSON(string(a.Recipient()))+`,"subject":`+quoteJSON(string(a.Subject()))+`,"roles":`+quoteJSON(a.Roles())+`,"name":`+quoteJSON(a.Name())+`,"description":`+quoteJSON(a.Description())+`,"before":`+channelsStateJSON(s)+`}`
}
