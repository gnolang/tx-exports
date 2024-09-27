package dao

import (
	"strconv"
	"time"

	"gno.land/p/demo/avl"
	"gno.land/p/demo/json"
)

// PreMarshaler defines an interface to enable JSON pre marshalling support.
type PreMarshaler interface {
	// PreMarshal pre marshals a type into a JSON node.
	PreMarshal() *json.Node
}

// PreMarshalDAO pre-marshalls a DAO and its sub DAOs.
func PreMarshalDAO(key string, dao *DAO) *json.Node {
	node := json.ObjectNode(key, nil)
	node.AppendObject("name", json.StringNode("name", dao.name))
	node.AppendObject("title", json.StringNode("title", dao.title))
	node.AppendObject("manifest", json.StringNode("manifest", dao.manifest))
	node.AppendObject("isSuperCouncil", json.BoolNode("isSuperCouncil", dao.isSuperCouncil))
	node.AppendObject("isLocked", json.BoolNode("isLocked", dao.isLocked))
	node.AppendObject("lockReason", json.StringNode("lockReason", dao.lockReason))
	node.AppendObject("members", preMarshalMembers("members", dao.members))
	node.AppendObject("createdAt", preMarshalTime("createdAt", dao.createdAt))

	if dao.parent != nil {
		node.AppendObject("parentName", json.StringNode("parentName", dao.parent.name))
	} else {
		node.AppendObject("parentName", json.NullNode("parentName"))
	}

	var children []*json.Node
	for _, c := range dao.children {
		children = append(children, PreMarshalDAO("", c))
	}
	node.AppendObject("children", json.ArrayNode("children", children))

	return node
}

// PreMarshalProposal pre-marshalls a proposal.
func PreMarshalProposal(key string, p *Proposal) *json.Node {
	node := json.ObjectNode(key, nil)
	node.AppendObject("id", json.StringNode("id", p.id.String()))
	node.AppendObject("title", json.StringNode("title", p.title))
	node.AppendObject("description", json.StringNode("description", p.description))
	node.AppendObject("proposer", json.StringNode("proposer", p.proposer.String()))
	node.AppendObject("createdAt", preMarshalTime("createdAt", p.createdAt))
	node.AppendObject("votingDeadline", preMarshalTime("votingDeadline", p.votingDeadline))
	node.AppendObject("reviewDeadline", preMarshalTime("reviewDeadline", p.reviewDeadline))
	node.AppendObject("voteChangeDuration", preMarshalDuration("voteChangeDuration", p.voteChangeDuration))
	node.AppendObject("status", json.StringNode("status", strconv.Itoa(int(p.status))))
	node.AppendObject("statusReason", json.StringNode("statusReason", p.statusReason))
	node.AppendObject("strategy", preMarshalStrategy("strategy", p.strategy))
	node.AppendObject("choice", json.StringNode("choice", string(p.choice)))

	var daos []*json.Node
	for _, dao := range p.daos {
		daos = append(daos, json.StringNode("", dao.name))
	}
	node.AppendObject("daos", json.ArrayNode("", daos))

	var records []*json.Node
	for _, r := range p.votingRecords {
		records = append(records, preMarshalVotingRecord(r))
	}
	node.AppendObject("votingRecords", json.ArrayNode("", records))

	return node
}

func preMarshalTime(key string, t time.Time) *json.Node {
	if t.IsZero() {
		return json.NullNode(key)
	}
	return json.StringNode(key, t.Format(time.RFC3339))
}

func preMarshalDuration(key string, d time.Duration) *json.Node {
	return json.StringNode(key, strconv.FormatInt(int64(d), 10))
}

func preMarshalMembers(key string, members []Member) *json.Node {
	if members == nil {
		return json.NullNode(key)
	}

	nodes := make([]*json.Node, len(members))
	for i, m := range members {
		nodes[i] = json.ObjectNode("", nil)
		nodes[i].AppendObject("address", json.StringNode("address", m.Address.String()))

		var roles []*json.Node
		for _, r := range m.Roles {
			roles = append(roles, json.StringNode("", string(r)))
		}
		nodes[i].AppendObject("roles", json.ArrayNode("roles", roles))
	}
	return json.ArrayNode(key, nodes)
}

func preMarshalProposalGroups(key string, tree avl.Tree) *json.Node {
	node := json.ObjectNode(key, nil)
	tree.Iterate("", "", func(k string, value interface{}) bool {
		// Save proposal IDs instead of the pre marshalled proposal which is saved inside "proposals"
		var proposals []*json.Node
		for _, p := range value.([]*Proposal) {
			proposals = append(proposals, json.StringNode("", p.id.String()))
		}

		daoID, _ := ConvertKeyToID(k) // TODO: Error should not happen, handle it anyways
		node.AppendObject(daoID.String(), json.ArrayNode("", proposals))
		return false
	})
	return node
}

func preMarshalStrategy(key string, s ProposalStrategy) *json.Node {
	if m, ok := s.(PreMarshaler); ok {
		return m.PreMarshal()
	}
	return json.NullNode(key)
}

func preMarshalVotingRecord(r *VotingRecord) *json.Node {
	node := json.ObjectNode("", nil)
	node.AppendObject("votes", preMarshalVotes("votes", r.votes))
	node.AppendObject("counter", preMarshalVoteCounter("counter", r.counter))
	return node
}

func preMarshalVotes(key string, votes []Vote) *json.Node {
	nodes := make([]*json.Node, len(votes))
	for i, v := range votes {
		n := json.ObjectNode("", nil)
		n.AppendObject("address", json.StringNode("address", v.Address.String()))
		n.AppendObject("choice", json.StringNode("choice", string(v.Choice)))
		n.AppendObject("reason", json.StringNode("reason", v.Reason))
		n.AppendObject("createdAt", preMarshalTime("createdAt", v.CreatedAt))

		if v.DAO != nil {
			n.AppendObject("daoPath", json.StringNode("daoPath", v.DAO.Path()))
		} else {
			n.AppendObject("daoPath", json.NullNode("daoPath"))
		}

		nodes[i] = n
	}
	return json.ArrayNode(key, nodes)
}

func preMarshalVoteCounter(key string, tree avl.Tree) *json.Node {
	node := json.ObjectNode(key, nil)
	tree.Iterate("", "", func(choice string, value interface{}) bool {
		node.AppendObject(choice, json.NumberNode("", float64(value.(uint))))
		return false
	})
	return node
}
