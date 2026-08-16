package memba_dao

// MembaDAO — Community governance realm for the Memba ecosystem.
//
// Uses gnodaokit basedao for full DAO lifecycle:
//   - Role-based membership (admin, dev, ops, member)
//   - Proposal/Vote/Execute governance (66% threshold)
//   - Self-upgradable via ChangeDAOImplementation proposals
//   - Profile integration via r/samcrew/_deps/demo/profile
//
// Security:
//   - NO open AddMember — membership only via DAO proposals (66% vote)
//   - Caller identity via realmid.Previous (default in basedao)
//
// Founding member: samcrew-core-test1 multisig (testnet)
//
// interrealm v2: init takes a realm; basedao.New / localDAO.Execute thread it;
// the v1 crossing wrapper (daokit.NewCrossing / CrossFn / the public DAO var)
// is removed.

import (
	"gno.land/p/samcrew/basedao"
	"gno.land/p/samcrew/daocond"
	"gno.land/p/samcrew/daokit"
	"gno.land/r/demo/profile" // genesis profile (v2); REQUIRED — basedao.New() panics without GetProfileString
)

var (
	localDAO   daokit.DAO          // Local interface for maketx call
	daoPrivate *basedao.DAOPrivate // Full access to internal DAO state
)

// Initializes MembaDAO with roles, founding member, and governance rules.
func init(cur realm) {
	// ── Roles ────────────────────────────────────────────────
	roles := []basedao.RoleInfo{
		{Name: "admin", Description: "DAO administrators with full governance power", Color: "#329175"},
		{Name: "dev", Description: "Core developers building the Memba ecosystem", Color: "#4ecdc4"},
		{Name: "ops", Description: "Operations team managing infrastructure", Color: "#fdcb6e"},
		{Name: "member", Description: "Community members contributing to governance", Color: "#21577A"},
	}

	// ── Founding Member ─────────────────────────────────────
	// samcrew-core-test1 multisig — testnet equivalent of production multisig
	members := []basedao.Member{
		{
			Address: "g1x7k4628w93a7wzdhqc06atzx0v50rnshweuxu0",
			Roles:   []string{"admin", "dev"},
		},
	}

	// ── Governance ───────────────────────────────────────────
	store := basedao.NewMembersStore(roles, members)

	// 66% threshold — strong consensus required for all actions.
	// With 1 member (bootstrap), this effectively means 100% (1/1).
	condition := daocond.MembersThreshold(0.66, store.IsMember, store.MembersCount)

	// ── Initialize DAO ──────────────────────────────────────
	localDAO, daoPrivate = basedao.New(&basedao.Config{
		Name:             "MembaDAO",
		Description:      "Community governance for the Memba ecosystem — multisig wallet & DAO platform on Gno",
		Members:          store,
		InitialCondition: condition,
		GetProfileString: profile.GetStringField,
		SetProfileString: profile.SetStringField,
		PrivateVarName:   "daoPrivate",
		SetImplemFn:      setImplem,
	}, cur)
}

// ── Public API ───────────────────────────────────────────────

// Propose creates a new governance proposal.
// Must be called via MsgRun (gnokey maketx run) for cross-realm support.
func Propose(cur realm, req daokit.ProposalRequest) {
	localDAO.Propose(req, cur)
}

// Vote allows DAO members to cast their vote on a proposal.
func Vote(cur realm, proposalID uint64, vote daocond.Vote) {
	localDAO.Vote(proposalID, vote, cur)
}

// Execute triggers execution of an approved proposal's actions.
func Execute(cur realm, proposalID uint64) {
	localDAO.Execute(proposalID, cur)
}

// Render generates the web UI for gnoweb.
func Render(path string) string {
	return localDAO.Render(path)
}

// ── Internal ─────────────────────────────────────────────────

// setImplem updates the DAO implementation when governance proposals change it.
func setImplem(newLocalDAO daokit.DAO) {
	localDAO = newLocalDAO
}
