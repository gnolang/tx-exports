package daokit

// Defines executable operations that proposals can perform.
// Each action has a type and handler functions that implements the actual logic.
//
// Example: Adding a member, transferring funds, or updating configuration.

import (
	"errors"

	"gno.land/p/moul/md"
	"gno.land/p/nt/ufmt/v0"
)

// Interface storing Action's data.
//
// SECURITY: String() is what a member reads before voting, and for an action
// built with NewAction it is the PAYLOAD's own rendering — supplied by whoever
// created the proposal. It is not trustworthy on its own.
//
// Two things keep it honest. Type() must be truthful or the wrong handler is
// looked up and its type assertion fails, so the action's KIND cannot be
// disguised; and the proposal view renders the Resource's registered
// DisplayName, Description and Condition beside it, which come from the DAO's
// own registry keyed by Type(), not from the proposal. A member therefore always
// sees what KIND of action this is from a trusted source.
//
// What String() can still misrepresent is the payload's DETAIL — and only if the
// handler lets a hostile payload through. See NewActionHandler.
type Action interface {
	// Returns human-readable description of the action.
	String() string
	// Returns unique identifier for the action type.
	Type() string
}

// Interface storing executable function that processes Action's data.
type ActionHandler interface {
	// Executes the given action's logic. The rlm realm is threaded so
	// handlers can perform cross-realm calls during execution.
	Execute(action Action, rlm realm)
	// Returns the action type this handler processes.
	Type() string
}

// Generic action implementation that stores a type and a payload.
// Payload contains the data parameters that will be processed by the handler.
// Example: {kind="/p/demo/transfer.Transfer", payload={amount: 1000, recipient: "user123"}}
type genericAction struct {
	kind    string
	payload interface{}
}

// Generic action handler that executes a function with a given payload.
// Example: A transfer handler that processes {amount, recipient} to move funds.
// {kind="transfer", executor=transferFunds}
type genericActionHandler struct {
	kind     string
	executor func(payload interface{}, rlm realm)
}

func NewAction(kind string, payload interface{}) Action {
	return &genericAction{kind: kind, payload: payload}
}

// Returns string representation of the action's payload.
func (g *genericAction) String() string {
	return ufmt.Sprintf("%v", g.payload)
}

// Returns the action's type identifier.
func (g *genericAction) Type() string {
	return g.kind
}

// SECURITY: the executor MUST type-assert the payload to a CONCRETE type, never
// to an interface.
//
// The concrete assertion is what makes the action's own rendering safe to show a
// voter: a hostile proposer can submit any payload, but one of the wrong type is
// rejected before the executor sees it, and one of the right type renders
// through that type's own String(). Assert to an interface instead and any
// conforming type passes — including one whose String() understates what its
// data does, so the proposal reads as something milder than it executes.
//
// Stronger still, and what the destructive built-ins do: make the payload type
// UNEXPORTED and expose only a constructor, so a proposer cannot build one at
// all. basedao's ChangeDAOImplementation and daokit's InstantExecute both do.
//
// Moving rendering onto the handler would remove this footgun rather than
// document it, since the handler is registered by the DAO and the payload is
// not — gnodaokit#13. That changes ActionHandler, so it belongs to a version
// boundary rather than a patch.
func NewActionHandler(kind string, executor func(interface{}, realm)) ActionHandler {
	return &genericActionHandler{kind: kind, executor: executor}
}

// Executes the action by calling the executor function with the payload.
func (g *genericActionHandler) Execute(iaction Action, rlm realm) {
	action, ok := iaction.(*genericAction)
	if !ok {
		panic(errors.New("invalid action type"))
	}
	g.executor(action.payload, rlm)
}

// Returns the action's type identifier.
func (g *genericActionHandler) Type() string {
	return g.kind
}

// Creates a new empty action instance.
func (g *genericActionHandler) Instantiate() Action {
	return &genericAction{
		kind: g.kind,
	}
}

// //////////////////////////////////////////////////////////
// ActionExecuteLambdaKind
//
// Built-in action type for executing lambda functions.
const ActionExecuteLambdaKind = "gno.land/p/samcrew/daokit.ExecuteLambda"

func NewExecuteLambdaHandler() ActionHandler {
	return NewActionHandler(ActionExecuteLambdaKind, func(i interface{}, _ realm) {
		cb, ok := i.(func())
		if !ok {
			panic(errors.New("invalid action type"))
		}
		cb()
	})
}

func NewExecuteLambdaAction(cb func()) Action {
	return NewAction(ActionExecuteLambdaKind, cb)
}

// //////////////////////////////////////////////////////////
// ActionInstantExecuteKind
//
// Built-in action type for instantly executing sub-proposals.
const ActionInstantExecuteKind = "gno.land/p/samcrew/daokit.InstantExecute"

type actionInstantExecute struct {
	dao DAO             // Target DAO to execute on
	req ProposalRequest // Proposal to execute instantly
}

func (a *actionInstantExecute) String() string {
	// XXX: find a way to be explicit about the subdao
	s := ""
	s += md.Paragraph(md.Blockquote(a.req.Action.Type()))
	s += md.Paragraph(a.req.Action.String())
	return s
}

func NewInstantExecuteHandler() ActionHandler {
	return NewActionHandler(ActionInstantExecuteKind, func(i interface{}, rlm realm) {
		action, ok := i.(*actionInstantExecute)
		if !ok {
			panic(errors.New("invalid action type"))
		}
		InstantExecute(action.dao, action.req, rlm)
	})
}

// SAME REALM ONLY, for the reason on InstantExecute: the handler forwards the
// EXECUTING DAO's realm, so dao must be hosted by the same realm. A child DAO in
// another realm is refused — reach it through that realm's crossing function
// instead.
func NewInstantExecuteAction(dao DAO, req ProposalRequest) Action {
	return NewAction(ActionInstantExecuteKind, &actionInstantExecute{dao: dao, req: req})
}
