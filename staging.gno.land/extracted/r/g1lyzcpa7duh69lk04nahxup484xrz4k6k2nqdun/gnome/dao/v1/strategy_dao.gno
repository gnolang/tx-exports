package gnome

import (
	"errors"
	"strconv"
	"strings"
	"time"

	"gno.land/p/demo/json"

	gnome "gno.land/p/g1lyzcpa7duh69lk04nahxup484xrz4k6k2nqdun/gnome/dao"
)

func newSubDAOCreationStrategy(daos daoIndex, name, title, manifest string, members []gnome.Member) subDAOCreationStrategy {
	if strings.TrimSpace(name) == "" {
		panic("sub DAO name is required")
	}

	if !gnome.IsSlug(name) {
		panic(`invalid sub DAO name, only letters from "a" to "z", numbers, "-" and "_" are allowed`)
	}

	if strings.TrimSpace(title) == "" {
		panic("sub DAO title is required")
	}

	if strings.TrimSpace(manifest) == "" {
		panic("sub DAO manifest is required")
	}

	if len(members) < minMembersCount {
		panic("sub DAOs require at least " + strconv.Itoa(minMembersCount) + " members")
	}

	return subDAOCreationStrategy{
		choices:  []gnome.VoteChoice{gnome.ChoiceYes, gnome.ChoiceNo},
		daos:     daos,
		name:     name,
		title:    title,
		manifest: manifest,
		members:  members,
	}
}

type subDAOCreationStrategy struct {
	choices               []gnome.VoteChoice
	daos                  daoIndex
	name, title, manifest string
	members               []gnome.Member
}

// Name returns the name of the strategy.
func (subDAOCreationStrategy) Name() string {
	return "create-sub-dao"
}

// Quorum returns the minimum required percentage of DAO member votes
// required for a proposal to pass.
func (subDAOCreationStrategy) Quorum() float64 {
	return 1.0
}

// VotingPeriod returns the period that a proposal should allow voting.
func (subDAOCreationStrategy) VotingPeriod() time.Duration {
	return time.Minute * 30
}

// VoteChoices returns the valid voting choices for the strategy.
func (s subDAOCreationStrategy) VoteChoices() []gnome.VoteChoice {
	return s.choices
}

// Tally counts the votes and returns the winner voting choice.
func (subDAOCreationStrategy) Tally(dao *gnome.DAO, r gnome.VotingRecord) gnome.VoteChoice {
	// Strategy need 100% participation to decide on the outcome.
	// Normally quorum should make sure all members voted before
	// tallying but otherwise tally should not return a valid outcome.
	if len(dao.Members()) != r.VoteCount() {
		return gnome.ChoiceNone
	}

	// This type of proposals can pass only when 100% of members vote YES.
	for _, v := range r.Votes() {
		// If there is at least one NO vote then proposal must be rejected
		if v.Choice == gnome.ChoiceNo {
			return gnome.ChoiceNo
		}
	}
	// Proposal should pass when all votes are YES
	return gnome.ChoiceYes
}

// Validate validates if a proposal is valid for the current state.
func (s subDAOCreationStrategy) Validate(p *gnome.Proposal) error {
	dao := p.DAO()
	path := dao.Path()
	if dao.IsLocked() {
		return errors.New("parent DAO '" + path + "' is locked")
	}

	subDAOPath := path + gnome.PathSeparator + s.name
	if s.daos.HasPathKey(subDAOPath) {
		return errors.New("sub DAO path has been taken by another DAO")
	}
	return nil
}

// RenderParams returns a markdown with the rendered strategy parameters.
func (s subDAOCreationStrategy) RenderParams() string {
	var (
		b        strings.Builder
		members  []string
		manifest = gnome.EscapeHTML(s.manifest)
	)

	for _, addr := range s.members {
		members = append(members, addr.String())
	}

	// TODO: Use a custom HTML table and add styling (vertical alignment, padding, ...)
	//       This would allow to remove the markdown "hacks" to improve the output layout
	b.WriteString("|||\n|---|---|\n")
	b.WriteString("| Name: | " + gnome.EscapeHTML(s.name) + " |\n")
	b.WriteString("| Title: | " + gnome.EscapeHTML(s.title) + " |\n")
	b.WriteString("| Members: | </br>" + strings.Join(members, "</br>") + "</br></br> |\n")
	b.WriteString("| Manifest:&nbsp;&nbsp; | " + strings.ReplaceAll(manifest, "\n", "</br>") + " |\n")

	return b.String()
}

// Execute creates the new sub DAO.
func (s subDAOCreationStrategy) Execute(dao *gnome.DAO) error {
	subDAO, err := gnome.New(s.name, s.title, gnome.WithManifest(s.manifest), gnome.WithMembers(s.members...))
	if err != nil {
		return err
	}

	// Add the new sub DAO to its parent
	dao.AddSubDAO(subDAO)

	// Index the new sub DAO
	s.daos.IndexByPath(subDAO)

	return nil
}

// PreMarshaler defines an interface to enable JSON pre marshalling support.
func (s subDAOCreationStrategy) PreMarshal() *json.Node {
	node := json.ObjectNode("", nil)
	node.AppendObject("name", json.StringNode("name", s.Name()))
	node.AppendObject("daoName", json.StringNode("daoName", s.name))
	node.AppendObject("daoTitle", json.StringNode("daoTitle", s.title))
	node.AppendObject("daoManifest", json.StringNode("daoManifest", s.title))
	node.AppendObject("members", preMarshalMembers("members", s.members))
	return node
}

func newDAOMembersModificationStrategy(newMembers, removeMembers []gnome.Member) daoMembersModificationStrategy {
	if len(newMembers) == 0 && len(removeMembers) == 0 {
		panic("members are required")
	}

	return daoMembersModificationStrategy{
		choices:       []gnome.VoteChoice{gnome.ChoiceYes, gnome.ChoiceNo},
		newMembers:    newMembers,
		removeMembers: removeMembers,
	}
}

type daoMembersModificationStrategy struct {
	choices                   []gnome.VoteChoice
	newMembers, removeMembers []gnome.Member
}

// Name returns the name of the strategy.
func (daoMembersModificationStrategy) Name() string {
	return "modify-dao-members"
}

// Quorum returns the minimum required percentage of DAO member votes
// required for a proposal to pass.
func (daoMembersModificationStrategy) Quorum() float64 {
	return 0.51
}

// VotingPeriod returns the period that a proposal should allow voting.
func (daoMembersModificationStrategy) VotingPeriod() time.Duration {
	return time.Minute * 30
}

// VoteChoices returns the valid voting choices for the strategy.
func (s daoMembersModificationStrategy) VoteChoices() []gnome.VoteChoice {
	return s.choices
}

// Tally counts the votes and returns the winner voting choice.
func (daoMembersModificationStrategy) Tally(_ *gnome.DAO, r gnome.VotingRecord) gnome.VoteChoice {
	// Tally requires at least three votes to be able to tally by 2/3s super majority
	if r.VoteCount() < 3 {
		return gnome.ChoiceNone
	}

	if choice, ok := gnome.SelectChoiceBySuperMajority(r); ok {
		return choice
	}
	return gnome.ChoiceNone
}

// Validate validates if a proposal is valid for the current DAO state.
func (s daoMembersModificationStrategy) Validate(p *gnome.Proposal) error {
	// At least three members are required to enforce 2/3s majority on proposals
	dao := p.DAO()
	memberCount := len(dao.Members()) + len(s.newMembers) - len(s.removeMembers)
	if memberCount < minMembersCount {
		return errors.New("DAO must always have a minimum of " + strconv.Itoa(minMembersCount) + " members")
	}

	// TODO: Should we allow re-adding members to only change assigned roles?
	for _, m := range s.newMembers {
		if dao.HasMember(m.Address) {
			return errors.New("address is already a DAO member: " + m.Address.String())
		}
	}

	for _, m := range s.removeMembers {
		if !dao.HasMember(m.Address) {
			return errors.New("address is not a DAO member: " + m.Address.String())
		}
	}

	return nil
}

// Execute modifies main DAO members.
func (s daoMembersModificationStrategy) Execute(dao *gnome.DAO) error {
	for _, m := range s.newMembers {
		dao.AddMember(m)
	}

	for _, m := range s.removeMembers {
		dao.RemoveMember(m.Address)
	}

	return nil
}

// RenderParams returns a markdown with the rendered strategy parameters.
func (s daoMembersModificationStrategy) RenderParams() string {
	var b strings.Builder

	b.WriteString("|||\n|---|---|\n")

	if len(s.newMembers) > 0 {
		var members []string
		for _, m := range s.newMembers {
			members = append(members, m.String())
		}

		b.WriteString("| New Members: | " + strings.Join(members, "</br>") + "</br></br> |\n")
	}

	if len(s.removeMembers) > 0 {
		var members []string
		for _, m := range s.removeMembers {
			members = append(members, m.String())
		}

		b.WriteString("| Members to Remove: | " + strings.Join(members, "</br>") + " |\n")
	}

	return b.String()
}

// PreMarshaler defines an interface to enable JSON pre marshalling support.
func (s daoMembersModificationStrategy) PreMarshal() *json.Node {
	node := json.ObjectNode("", nil)
	node.AppendObject("name", json.StringNode("name", s.Name()))
	node.AppendObject("newMembers", preMarshalMembers("newMembers", s.newMembers))
	node.AppendObject("removeMembers", preMarshalMembers("removeMembers", s.removeMembers))
	return node
}

func newSubDAODismissalStrategy(dao *gnome.DAO, x proposalIndex) subDAODismissalStrategy {
	if dao == nil {
		panic("DAO is required")
	}

	return subDAODismissalStrategy{
		choices:   []gnome.VoteChoice{gnome.ChoiceYes, gnome.ChoiceNo},
		dao:       dao,
		proposals: x,
	}
}

type subDAODismissalStrategy struct {
	choices   []gnome.VoteChoice
	dao       *gnome.DAO
	proposals proposalIndex
}

// Name returns the name of the strategy.
func (subDAODismissalStrategy) Name() string {
	return "dismiss-sub-dao"
}

// Quorum returns the minimum required percentage of DAO member votes
// required for a proposal to pass.
func (subDAODismissalStrategy) Quorum() float64 {
	return 0.51
}

// VotingPeriod returns the period that a proposal should allow voting.
func (subDAODismissalStrategy) VotingPeriod() time.Duration {
	return time.Minute * 30
}

// VoteChoices returns the valid voting choices for the strategy.
func (s subDAODismissalStrategy) VoteChoices() []gnome.VoteChoice {
	return s.choices
}

// Tally counts the votes and returns the winner voting choice.
func (subDAODismissalStrategy) Tally(_ *gnome.DAO, r gnome.VotingRecord) gnome.VoteChoice {
	if choice, ok := gnome.SelectChoiceByPlurality(r); ok {
		return choice
	}
	return gnome.ChoiceNone
}

// Validate validates if a proposal is valid for the current DAO state.
func (s subDAODismissalStrategy) Validate(p *gnome.Proposal) error {
	parentDAO := s.dao.Parent()
	if parentDAO == nil {
		return errors.New("the DAO to dismiss has no parent DAO")
	}

	parentName := p.DAO().Name()
	if parentDAO.Name() != parentName {
		return errors.New(`the DAO to dismiss must be a first level sub DAO of "` + parentName + `"`)
	}
	return nil
}

// Execute modifies main DAO members.
func (s subDAODismissalStrategy) Execute(*gnome.DAO) error {
	// Get the list of all sub DAOs and the root DAO to dismiss
	daos := append(s.dao.CollectSubDAOs(), s.dao)
	// Proposal dismissal requires a reason
	// TODO: Send proposal to Execute and add dismissal proposal link?
	reason := "Dismissed because of DAO dismissal: " + s.dao.Path()

	for _, dao := range daos {
		// Dismiss all proposals for the current DAO
		for _, p := range s.proposals.GetAllByDAO(dao.Path()) {
			if !p.Status().IsFinal() {
				p.Dismiss(reason)
			}
		}

		// Lock the DAO to dismiss it
		dao.Lock("")
	}
	return nil
}

// RenderParams returns a markdown with the rendered strategy parameters.
func (s subDAODismissalStrategy) RenderParams() string {
	return "DAO: " + s.dao.Path()
}

// PreMarshaler defines an interface to enable JSON pre marshalling support.
func (s subDAODismissalStrategy) PreMarshal() *json.Node {
	node := json.ObjectNode("", nil)
	node.AppendObject("name", json.StringNode("name", s.Name()))
	node.AppendObject("daoPath", json.StringNode("daoPath", s.dao.Path()))
	return node
}

func preMarshalMembers(key string, members []gnome.Member) *json.Node {
	if members == nil {
		return json.NullNode(key)
	}

	nodes := make([]*json.Node, len(members))
	for i, m := range members {
		nodes[i] = json.ObjectNode("", nil)
		nodes[i].AppendObject("address", json.StringNode("address", m.Address.String()))

		if m.Roles == nil {
			nodes[i].AppendObject("members", json.NullNode("members"))
			continue
		}

		roles := make([]*json.Node, len(m.Roles))
		for j, r := range m.Roles {
			roles[j] = json.StringNode("", string(r))
		}
		nodes[i].AppendObject("members", json.ArrayNode("members", roles))
	}
	return json.ArrayNode(key, nodes)
}
