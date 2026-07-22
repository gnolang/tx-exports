package basedao

import (
	"errors"

	"gno.land/p/samcrew/daokit"
)

// Making this action name extra explicit.
const ActionChangeDAOImplementationKind = "gno.land/p/samcrew/basedao.ChangeDAOImplementation"

type MigrateFn = func(prev *DAOPrivate, params []any, rlm realm) daokit.DAO

type MigrationParamsFn = func() []any

type actionChangeDAOImplementation struct {
	label   string
	migrate MigrateFn
}

func (a *actionChangeDAOImplementation) String() string {
	return "WARNING: this replaces the DAO's implementation.\n\n" +
		"The migration function receives the DAO's live realm and full private\n" +
		"state, so approving it grants whoever wrote it the DAO's authority.\n" +
		"Read the code it refers to before voting.\n\n" +
		"Migration: " + a.label
}

func NewChangeDAOImplementationHandler(dao *DAOPrivate, setImplem daokit.SetImplemFn, paramsFn MigrationParamsFn) daokit.ActionHandler {
	if dao == nil || setImplem == nil || paramsFn == nil {
		panic("nil arg")
	}
	return daokit.NewActionHandler(ActionChangeDAOImplementationKind, func(i interface{}, rlm realm) {
		action, ok := i.(*actionChangeDAOImplementation)
		if !ok {
			panic(errors.New("invalid action type"))
		}

		migrated := action.migrate(dao, paramsFn(), rlm)
		setImplem(migrated)
	})
}

// The label is required and appears in the proposal a member votes on.
//
// Without it every migration renders as the same fixed sentence, so a voter sees
// nothing distinguishing a routine upgrade from a takeover. A function value
// cannot be rendered, so the caller has to say what it is — name the version,
// the commit, or the change.
//
// It is NOT a safety control. Whoever writes the migration writes the label, so
// a takeover can ship as "routine security patch". It exists so an honest
// proposal can be told apart from another honest proposal, and so a voter has
// something to check the code against. Read the migration.
func NewChangeDAOImplementationAction(label string, migrate MigrateFn) daokit.Action {
	if label == "" {
		panic("migration label must not be empty")
	}
	if migrate == nil {
		panic("migration function must not be nil")
	}
	return daokit.NewAction(ActionChangeDAOImplementationKind, &actionChangeDAOImplementation{
		label:   label,
		migrate: migrate,
	})
}
