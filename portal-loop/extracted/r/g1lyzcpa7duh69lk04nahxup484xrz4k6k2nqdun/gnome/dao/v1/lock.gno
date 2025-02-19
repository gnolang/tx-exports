package gnome

import (
	"crypto/sha256"
	"encoding/hex"
	"std"
	"strings"
	"time"

	"gno.land/p/demo/json"

	gnome "gno.land/p/g1lyzcpa7duh69lk04nahxup484xrz4k6k2nqdun/gnome/dao"
)

var (
	// Initial state hash contains the sha256 hash of the initial realm state.
	initialStateHash string

	// Final state hash contains the sha256 hash of the final realm state.
	// This value is initialized right after the realm is locked and can be used to
	// validate the state when migrating to a new realm version.
	finalStateHash string
)

func init() {
	initialStateHash = mustCalculateStateHash()
}

// SubmitDAOLockingProposal submits a new proposal to lock the DAO.
//
// Locking the DAO "freezes the state" by disallowing further modifications.
// State must be locked to migrate the realm to a newer version.
//
// This type of proposal can only be created by the Council or Main DAO members.
// Tally is done by plurality.
// Default voting period is 2 days.
//
// Parameters:
// - proposalTitle: A title for the proposal (required)
// - proposalDescription: A description of the proposal
// - daoPath: Path of the DAO where the proposal should be created (required)
// - reason: Text with the DAO locking reason
//
// The optional `reason` argument can contain HTML.
func SubmitDAOLockingProposal(
	proposalTitle,
	proposalDescription,
	daoPath,
	reason string,
) uint64 {
	assertDAOIsNotLocked()

	caller := std.OriginCaller()
	assertIsCouncilOrMainDAOMember(caller)

	dao := mustGetDAO(daoPath)
	assertIsCouncilOrMainDAO(dao)

	reason = strings.TrimSpace(reason)
	strategy := newLockingStrategy(gnomeDAO, reason, func() (err error) {
		// Advance all proposals before locking the DAO
		advanceProposals()

		// Also update realm state with the final state hash
		finalStateHash, err = calculateStateHash()
		return err
	})

	p, err := gnome.NewProposal(
		genProposalID(),
		strategy,
		caller,
		dao,
		proposalTitle,
		gnome.WithDescription(proposalDescription),
		gnome.WithReviewDeadline(time.Now().Add(reviewDeadline)),
	)
	if err != nil {
		panic(err)
	}

	if err := p.Validate(); err != nil {
		panic(err)
	}

	proposals.Index(p)
	AdvanceProposals()

	return uint64(p.ID())
}

// GetInitialDAOStateHash returns the sha256 hash of the initial realm state.
// The initial state hash is calculated when the realm is initialized.
func GetInitialDAOStateHash() string {
	return initialStateHash
}

// GetFinalDAOStateHash returns the sha256 hash of the final realm state.
// Locking the realm requires a lock DAO proposal to pass.
// The final state hash is calculated when a lock DAO proposal is executed.
func GetFinalDAOStateHash() string {
	if !gnomeDAO.IsLocked() {
		panic("DAO must be locked to get the final state hash")
	}

	return finalStateHash
}

// GetState returns the realm state as JSON.
// State can only be read when the realm is locked.
// It can be used with the final state hash to migrate realms to newer versions.
func GetState() string {
	if !gnomeDAO.IsLocked() {
		panic("DAO must be locked to get the state")
	}

	bz, err := marshalState()
	if err != nil {
		panic(err)
	}
	return string(bz)
}

func marshalState() ([]byte, error) {
	node := json.ObjectNode("", nil)
	node.AppendObject("lastProposalID", json.StringNode("lastProposalID", lastProposalID.String()))
	node.AppendObject("gnomeDAO", gnome.PreMarshalDAO("gnomeDAO", gnomeDAO))

	var items []*json.Node
	proposals.Iterate(func(p *gnome.Proposal) bool {
		items = append(items, gnome.PreMarshalProposal("", p))
		return false
	})
	node.AppendObject("proposals", json.ArrayNode("", items))

	return json.Marshal(node)
}

func calculateStateHash() (string, error) {
	bz, err := marshalState()
	if err != nil {
		return "", err
	}

	hash := sha256.Sum256(bz)
	return hex.EncodeToString(hash[:]), nil
}

func mustCalculateStateHash() string {
	hash, err := calculateStateHash()
	if err != nil {
		panic(err)
	}
	return hash
}

func assertDAOIsNotLocked() {
	if gnomeDAO.IsLocked() {
		panic("DAO is locked")
	}
}

func assertIsCouncilOrMainDAO(dao *gnome.DAO) {
	if !dao.IsSuperCouncil() {
		// Main DAO parent must be the super council
		parentDAO := dao.Parent()
		if !parentDAO.IsSuperCouncil() {
			panic("DAO is not the council or main DAO")
		}
	}
}

func assertIsCouncilOrMainDAOMember(addr std.Address) {
	if !gnomeDAO.HasMember(addr) {
		if mainDAO := gnomeDAO.GetFirstSubDAO(); !mainDAO.HasMember(addr) {
			panic("account is not a council or main DAO member")
		}
	}
}
