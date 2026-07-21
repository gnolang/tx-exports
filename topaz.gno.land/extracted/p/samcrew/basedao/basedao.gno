package basedao

import (
	"chain"
	"chain/runtime"
	"chain/runtime/unsafe"
	"errors"

	"gno.land/p/nt/mux/v0"
	"gno.land/p/samcrew/daocond"
	"gno.land/p/samcrew/daokit"
)

type daoPublic struct {
	impl *DAOPrivate
}

type SetImplemRaw func(newDAO daokit.DAO)

type RenderFn func(path string, dao *DAOPrivate) string

func (d *daoPublic) Extension(path string, rlm realm) daokit.Extension {
	ext, ok := d.impl.Core.Extensions.Get(path)
	if !ok {
		return nil
	}
	// Only private extensions are gated; a public one is readable by anyone and
	// ignores the realm entirely.
	//
	// This used to ask unsafe.CurrentRealm(), which is a stack walk and answers
	// a different question: "is a DAO frame the innermost live one", not "is my
	// caller the DAO". It was wrong in both directions. Too lax, because
	// anything the DAO invoked WITHOUT crossing inherited the DAO's realm —
	// including a proposer-authored ExecuteLambda callback, which could read a
	// private extension. And too strict, because a DAO-realm helper that is not
	// itself a crossing function had no frame of its own for the walk to find.
	//
	// Requiring the DAO's own live realm answers the intended question directly.
	// It also closes the lambda case by construction rather than by check: a
	// callback that receives no realm cannot produce one, and realm values
	// cannot be persisted or forged.
	if ext.Info().Private {
		assertRealmIsOwn(d.impl, rlm)
	}
	return ext
}

// Not gated, deliberately. It exposes ExtensionInfo — paths and versions — and
// not extension values, so it grants no capability; and realm state is
// world-readable over ABCI anyway, so gating it would suggest a confidentiality
// this cannot provide. Getting the VALUE of a private extension goes through
// Extension, which is gated.
func (d *daoPublic) ExtensionsList() daokit.ExtensionsList {
	return d.impl.Core.Extensions.List()
}

func (d *daoPublic) Propose(req daokit.ProposalRequest, rlm realm) uint64 {
	return d.impl.Propose(req, rlm)
}

func (d *daoPublic) Execute(id uint64, rlm realm) {
	d.impl.Execute(id, rlm)
}

func (d *daoPublic) Vote(id uint64, vote daocond.Vote, rlm realm) {
	d.impl.Vote(id, vote, rlm)
}

func (d *daoPublic) Render(path string) string {
	return d.impl.Render(path)
}

// DAO is meant for internal realm usage and should not be exposed.
type DAOPrivate struct {
	Core             *daokit.Core
	Members          *MembersStore
	RenderRouter     *mux.Router
	GetProfileString ProfileStringGetter
	Realm            runtime.Realm
	RenderFn         func(path string, dao *DAOPrivate) string
	CallerID         CallerIDFn

	InitialConfig *Config // mostly there in case we need this data during upgrade
}

// CallerIDFn resolves the identity of the DAO's immediate caller.
//
// It receives the DAO realm's own threaded realm, so the implementation can use
// rlm.Previous(), which is statically scoped to that crossing function.
//
// On every path the entry gate admits, a stack walk would name the same realm:
// the gate has already established that the DAO's own frame is the live one, so
// unsafe.PreviousRealm() and rlm.Previous() agree. The walk goes wrong only in
// the shape the gate now rejects — a caller invoking these methods through the
// DAO handle, with no DAO realm frame on the stack at all, where the walk names
// the signing account instead. Deriving from the threaded realm is preferred
// because it does not depend on the gate having run first.
//
// The realm is deliberately the SECOND parameter: a function whose first
// parameter is a realm is read as crossing, and /p/ packages may not declare
// crossing functions.
type CallerIDFn func(dao *DAOPrivate, rlm realm) string

type Config struct {
	// Basic DAO information
	Name        string
	Description string
	ImageURI    string

	// Storage handler
	Members *MembersStore

	// Feature toggles
	NoDefaultHandlers  bool // Skips registration of default management actions (add/remove members, etc.)
	NoDefaultRendering bool // Skips setup of default web UI rendering routes
	NoCreationEvent    bool // Skips emitting the DAO creation event

	// Governance configuration
	InitialCondition daocond.Condition // Default condition for all built-in actions, defaults to 60% member majority

	// Profile integration (optional)
	SetProfileString ProfileStringSetter // Function to update profile fields (DisplayName, Bio, Avatar)
	GetProfileString ProfileStringGetter // Function to retrieve profile fields for members

	// Advanced customization hooks
	SetImplemFn       SetImplemRaw      // Function called when DAO implementation changes via governance
	MigrationParamsFn MigrationParamsFn // Function providing parameters for DAO upgrades
	// Condition for replacing the DAO's implementation. A passing migration
	// hands proposer-authored code the DAO's live realm and its full private
	// state, so it is a takeover in the general case — it should not be as easy
	// as adding a member.
	//
	// If you leave InitialCondition to its default, this defaults to an 80%
	// member majority — the same dimension, raised.
	//
	// If you SET InitialCondition, this defaults to it unchanged, and you should
	// set this too. A Condition is opaque, so nothing here can strengthen yours:
	// conjoining a members threshold onto role-based governance can demand a
	// majority such a DAO never assembles, and migration is the one rule that
	// cannot be repaired afterwards — changing it requires a migration. Whatever
	// you choose, make it at least as hard as InitialCondition along every
	// dimension; a condition that merely replaces yours can be WEAKER where it
	// matters.
	MigrationCondition daocond.Condition
	RenderFn          RenderFn          // Rendering function for Gnoweb
	CallerID          CallerIDFn        // Resolves the immediate caller from the DAO's threaded realm; defaults to defaultCallerID

	// Internal configuration
	PrivateVarName string // Name of the private DAO variable for member querying extensions
}

type ProfileStringSetter func(cur realm, field string, value string) bool
type ProfileStringGetter func(addr address, field string, def string) string

const EventBaseDAOCreated = "BaseDAOCreated"

func New(conf *Config, rlm realm) (daokit.DAO, *DAOPrivate) {
	// XXX: emit events from memberstore

	members := conf.Members
	if members == nil {
		members = NewMembersStore(nil, nil)
	}

	if conf.GetProfileString == nil {
		panic(errors.New("GetProfileString is required"))
	}

	if conf.CallerID == nil {
		conf.CallerID = defaultCallerID
	}

	core := daokit.NewCore()
	dao := &DAOPrivate{
		Core:             core,
		Members:          members,
		GetProfileString: conf.GetProfileString,
		Realm:            unsafe.CurrentRealm(),
		RenderFn:         conf.RenderFn,
		CallerID:         conf.CallerID,
		InitialConfig:    conf,
	}

	pubdao := &daoPublic{impl: dao}

	dao.Core.Extensions.Set(&membersViewExtension{
		getStore:  func() *MembersStore { return dao.Members },
		queryPath: dao.Realm.PkgPath() + "." + conf.PrivateVarName + ".Members",
	})

	dao.initRenderingRouter()

	if !conf.NoDefaultRendering {
		dao.InitDefaultRendering()
	}

	if conf.SetProfileString != nil {
		conf.SetProfileString(cross(rlm), "DisplayName", conf.Name)
		conf.SetProfileString(cross(rlm), "Bio", conf.Description)
		conf.SetProfileString(cross(rlm), "Avatar", conf.ImageURI)
	}

	if !conf.NoDefaultHandlers {
		// Whether the DAO chose its own governance decides how far the migration
		// default may go, below. Captured before the default is filled in.
		governanceIsCallerChosen := conf.InitialCondition != nil
		if conf.InitialCondition == nil {
			conf.InitialCondition = daocond.MembersThreshold(0.6, members.IsMember, members.MembersCount)
		}

		if conf.SetProfileString != nil {
			dao.Core.Resources.Set(&daokit.Resource{
				Handler:     NewEditProfileHandler(conf.SetProfileString, []string{"DisplayName", "Bio", "Avatar"}),
				Condition:   conf.InitialCondition,
				DisplayName: "Edit Profile",
				Description: "This proposal allows you to edit this DAO profile.",
			})
		}

		if conf.SetImplemFn != nil {
			setImplemFn := func(dao daokit.DAO) {
				conf.SetImplemFn(dao)
			}
			setImplemFn(pubdao)

			if conf.MigrationParamsFn == nil {
				conf.MigrationParamsFn = func() []any { return nil }
			}

			// Held locally rather than written back into conf: New must not
			// mutate its caller's Config, and this closure captures THIS DAO's
			// member store — reusing one Config for a second DAO would otherwise
			// give it a migration condition evaluating the first one's members.
			migrationCondition := conf.MigrationCondition
			if migrationCondition == nil {
				if governanceIsCallerChosen {
					// The DAO designed its own governance, and a Condition is
					// opaque, so there is no way to strengthen it from here. A
					// members threshold is not a strengthening: conjoined with
					// role-based governance it can demand a member majority that
					// role-governed DAOs never assemble, and migration is the one
					// rule that cannot be repaired afterwards — changing it needs
					// a migration. Substituting one is worse still: against
					// And(MembersThreshold(0.4), RoleCount(1,"officer")) a ballot
					// that fails an ordinary action passed a bare 0.8 migration,
					// making a takeover CHEAPER than adding a member.
					//
					// So: match the DAO's own bar, and say plainly that a
					// takeover deserves a higher one. Set MigrationCondition.
					migrationCondition = conf.InitialCondition
				} else {
					// Default governance, so a members threshold is the same
					// dimension the DAO is already judged on and raising it is a
					// genuine strengthening: 80% against the default 60%.
					migrationCondition = daocond.MembersThreshold(0.8, members.IsMember, members.MembersCount)
				}
			}

			dao.Core.Resources.Set(&daokit.Resource{
				Handler:     NewChangeDAOImplementationHandler(dao, setImplemFn, conf.MigrationParamsFn),
				Condition:   migrationCondition,
				DisplayName: "Change DAO Implementation",
				Description: "Replaces the DAO implementation. The migration receives the DAO's live realm and private state.",
			})
		}

		defaultResources := []daokit.Resource{
			{
				Handler:     NewAddMemberHandler(dao),
				Condition:   conf.InitialCondition,
				DisplayName: "Add Member",
				Description: "This proposal allows you to add a new member to the DAO.",
			},
			{
				Handler:     NewRemoveMemberHandler(dao),
				Condition:   conf.InitialCondition,
				DisplayName: "Remove Member",
				Description: "This proposal allows you to remove a member from the DAO.",
			},
			{
				Handler:     NewAssignRoleHandler(dao),
				Condition:   conf.InitialCondition,
				DisplayName: "Assign Role",
				Description: "This proposal allows you to assign a role to a member.",
			},
			{
				Handler:     NewUnassignRoleHandler(dao),
				Condition:   conf.InitialCondition,
				DisplayName: "Unassign Role",
				Description: "This proposal allows you to unassign a role from a member.",
			},
		}
		// register management handlers
		for _, resource := range defaultResources {
			dao.Core.Resources.Set(&resource)
		}

	}

	if !conf.NoCreationEvent {
		chain.Emit(EventBaseDAOCreated)
	}

	return pubdao, dao
}

func (d *DAOPrivate) Vote(proposalID uint64, vote daocond.Vote, rlm realm) {
	if len(vote) > 16 {
		panic("invalid vote")
	}

	assertRealmIsOwn(d, rlm)
	voterID := d.assertCallerIsMember(d.CallerID(d, rlm))
	d.Core.Vote(voterID, proposalID, vote)
}

func (d *DAOPrivate) Execute(proposalID uint64, rlm realm) {
	assertRealmIsOwn(d, rlm)
	_ = d.assertCallerIsMember(d.CallerID(d, rlm))
	d.Core.Execute(proposalID, rlm)
}

func (d *DAOPrivate) Propose(req daokit.ProposalRequest, rlm realm) uint64 {
	assertRealmIsOwn(d, rlm)
	proposerID := d.assertCallerIsMember(d.CallerID(d, rlm))
	return d.Core.Propose(proposerID, req)
}

// Resolves the DAO's immediate caller from the DAO's own threaded realm.
// rlm.Previous() is statically scoped to the DAO realm's crossing function, so
// unlike a stack walk it cannot be shifted by how deep the call chain is.
//
// At the root of a call chain — a package init, or an entry point an account
// reached directly — the previous realm is the origin realm: the signing
// account, with an empty pkgpath. IsUser() holds there, so this resolves to
// that account's address, which is how an ordinary member is authenticated.
//
// It yields "" only where the machine carries no signing account at all. That
// is not an identity, and assertCallerIsMember refuses it.
func defaultCallerID(dao *DAOPrivate, rlm realm) string {
	p := rlm.Previous()
	if p.IsUser() {
		return p.Address().String()
	}
	return p.PkgPath()
}

// The realm threaded into an entry point must be the DAO realm's own live one.
//
// Execute forwards this realm to the action handlers, which cross out under it,
// so whoever supplies it decides the identity the DAO acts as. Left unchecked, a
// third realm holding the DAO value could pass its own realm and have the DAO
// write to that realm's profile — or, through MigrateFn, reach anywhere the
// caller controls. Realm values are unforgeable and cannot be persisted across
// transactions, so a caller can only ever pass its own; requiring it to equal
// the DAO's own realm therefore closes the donation path outright.
//
// The pkgpath alone is not enough. Every realm the DAO crosses out into during
// an action receives the DAO's own realm value as its cur.Previous(), and can
// hand that value straight back within the same transaction — same pkgpath,
// but belonging to a frame that is no longer executing. IsCurrent() is what
// separates the two: it holds only for the realm minted for the crossing
// function currently on the stack, by frame identity rather than by name. It
// survives the /p/ hop into this package, and it is true during a realm's own
// init, so neither the ordinary path nor construction is affected.
//
// Given both, rlm.Previous() is by construction the DAO's immediate caller.
//
// This takes the DAO as its first parameter rather than being a method on it:
// the VM reads any function whose FIRST parameter is a realm as crossing, and
// /p/ packages may not declare crossing functions. Receivers do not count, so a
// method would hit the same rule.
func assertRealmIsOwn(d *DAOPrivate, rlm realm) {
	if rlm.PkgPath() != d.Realm.PkgPath() || !rlm.IsCurrent() {
		panic("realm mismatch: the DAO may only act as " + d.Realm.PkgPath())
	}
}

func (d *DAOPrivate) assertCallerIsMember(id string) string {
	// An empty id is never a real caller, and the store can hold one: AddMember
	// does not reject it, and Members is an exported avl.Tree that a same-realm
	// write or a MigrateFn can seed directly. Reject it here, where every entry
	// point passes, so one such entry cannot authenticate every unattributable
	// call.
	if id == "" {
		panic(errors.New("caller id is empty"))
	}
	if !d.Members.IsMember(id) {
		panic(errors.New("caller is not a member"))
	}
	return id
}
