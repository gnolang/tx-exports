package gnome

import (
	"std"
	"strconv"
	"time"

	"gno.land/p/demo/avl"
	"gno.land/p/demo/json"
)

type PreMarshaler interface {
	PreMarshal() *json.Node
}

func PreMarshalDAO(dao *DAO) *json.Node {
	return preMarshalDAO("dao", dao)
}

func PreMarshalProposals(p Proposals) *json.Node {
	node := json.ObjectNode("proposals", nil)
	node.AppendObject("lastID", json.StringNode("lastID", p.lastID.String()))
	node.AppendObject("proposals", preMarshalProposals("proposals", p.proposals))
	node.AppendObject("groups", preMarshalProposalGroups("groups", p.groups))
	return node
}

func preMarshalDAO(key string, dao *DAO) *json.Node {
	node := json.ObjectNode(key, nil)
	node.AppendObject("name", json.StringNode("name", dao.name))
	node.AppendObject("title", json.StringNode("title", dao.title))
	node.AppendObject("manifest", json.StringNode("manifest", dao.manifest))
	node.AppendObject("isSuperCouncil", json.BoolNode("isSuperCouncil", dao.isSuperCouncil))
	node.AppendObject("children", preMarshalChildren(dao.children))
	node.AppendObject("members", preMarshalAddresses("members", dao.members))
	node.AppendObject("createdAt", preMarshalTime("createdAt", dao.createdAt))

	if dao.parent != nil {
		node.AppendObject("parentName", json.StringNode("parentName", dao.parent.name))
	} else {
		node.AppendObject("parentName", json.NullNode("parentName"))
	}

	return node
}

func preMarshalChildren(children []*DAO) *json.Node {
	if children == nil {
		return json.NullNode("children")
	}

	nodes := make([]*json.Node, len(children))
	for i, c := range children {
		nodes[i] = preMarshalDAO("", c)
	}
	return json.ArrayNode("children", nodes)
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

func preMarshalAddresses(key string, addresses []std.Address) *json.Node {
	if addresses == nil {
		return json.NullNode(key)
	}

	nodes := make([]*json.Node, len(addresses))
	for i, a := range addresses {
		nodes[i] = json.StringNode("", a.String())
	}
	return json.ArrayNode(key, nodes)
}

func preMarshalProposals(key string, tree avl.Tree) *json.Node {
	node := json.ObjectNode(key, nil)
	tree.Iterate("", "", func(k string, value interface{}) bool {
		proposalID, _ := ConvertKeyToID(k) // TODO: Error should not happen, handle it anyways
		node.AppendObject(proposalID.String(), preMarshalProposal(value.(*Proposal)))
		return false
	})
	return node
}

func preMarshalProposal(p *Proposal) *json.Node {
	node := json.ObjectNode("", nil)
	node.AppendObject("id", json.StringNode("id", p.id.String()))
	node.AppendObject("title", json.StringNode("title", p.title))
	node.AppendObject("description", json.StringNode("description", p.description))
	node.AppendObject("proposer", json.StringNode("proposer", p.proposer.String()))
	node.AppendObject("createdAt", preMarshalTime("createdAt", p.createdAt))
	node.AppendObject("votingDeadline", preMarshalTime("votingDeadline", p.votingDeadline))
	node.AppendObject("reviewDeadline", preMarshalTime("reviewDeadline", p.reviewDeadline))
	node.AppendObject("voteChangeDuration", preMarshalDuration("voteChangeDuration", p.voteChangeDuration))
	node.AppendObject("status", json.StringNode("status", strconv.Itoa(int(p.status))))
	node.AppendObject("strategy", preMarshalStrategy("strategy", p.strategy))
	node.AppendObject("choice", json.StringNode("choice", string(p.choice)))

	if p.dao != nil {
		node.AppendObject("daoName", json.StringNode("daoName", p.dao.name))
	} else {
		node.AppendObject("daoName", json.NullNode("daoName"))
	}

	if p.votingRecord != nil {
		node.AppendObject("votingRecord", preMarshalVotingRecord("votingRecord", p.votingRecord))
	} else {
		node.AppendObject("votingRecord", json.NullNode("votingRecord"))
	}

	return node
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

func preMarshalVotingRecord(key string, r *VotingRecord) *json.Node {
	node := json.ObjectNode(key, nil)
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
			n.AppendObject("daoName", json.StringNode("daoName", v.DAO.name))
		} else {
			n.AppendObject("daoName", json.NullNode("daoName"))
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
