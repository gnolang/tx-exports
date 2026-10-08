// Package policies is the Remix Lab permission block. A Policy maps named
// operations to an eligibility rule evaluated against a membership reader.
//
// Each operation is defined once with a floor: the most permissive rule it
// may ever be set to. Administrative operations get a floor of RuleReviewer
// or RuleOwner, so reconfiguring a policy can never hand admin powers to
// ordinary members or the public.
//
// Operations with an owner floor (typically policy changes and owner
// appointment) can never be disabled: setting them to RuleNobody would lock
// the owners out permanently.
//
// Policy changes affect future operations only. Ballot eligibility follows
// the electorate frozen when the ballot opened, not the current policy.
package policies

import (
	"gno.land/p/g1lnkytfqcjwllws63gvf0mv9yt04aswy4y9amhm/remixlab/core/v1"
	"gno.land/p/nt/avl/v0"
)

// Rule is an eligibility requirement. Rules are ordered from most to least
// permissive.
type Rule int

const (
	RulePublic Rule = iota
	RuleMember
	RuleReviewer
	RuleOwner
	RuleNobody // operation disabled
)

func (r Rule) String() string {
	switch r {
	case RulePublic:
		return "public"
	case RuleMember:
		return "member"
	case RuleReviewer:
		return "reviewer"
	case RuleOwner:
		return "owner"
	case RuleNobody:
		return "nobody"
	}
	return "unknown"
}

// ParseRule converts the canonical rule name to a Rule.
func ParseRule(s string) (Rule, error) {
	for r := RulePublic; r <= RuleNobody; r++ {
		if r.String() == s {
			return r, nil
		}
	}
	return RuleNobody, core.Errorf(core.ErrInvalidInput, "unknown rule")
}

// MaxOperations bounds the number of operations one policy defines.
const MaxOperations = 64

type entry struct {
	rule  Rule
	floor Rule
}

// RuleView is an inert description of one operation's rule.
type RuleView struct {
	Op    string
	Rule  Rule
	Floor Rule
}

// Policy evaluates named operations. Hold it in an unexported host-realm
// variable; its Set method changes authorization.
type Policy struct {
	members core.MembershipReader
	ops     *avl.Tree // op -> *entry
}

// New creates a policy reading roles from members. members may be the
// host's own membership set or an adapter to a reviewed shared realm.
func New(members core.MembershipReader) *Policy {
	if members == nil {
		panic(core.Errorf(core.ErrInvalidInput, "nil membership reader").Error())
	}
	return &Policy{members: members, ops: avl.NewTree()}
}

// Define registers op with an initial rule and a floor. It panics on invalid
// input because host realms call it from init with constant arguments.
func (p *Policy) Define(op string, rule, floor Rule) {
	if err := checkOp(op); err != nil {
		panic(err.Error())
	}
	if !floor.valid() || !rule.valid() {
		panic(core.Errorf(core.ErrInvalidInput, "invalid rule").Error())
	}
	if rule < floor {
		panic(core.Errorf(core.ErrInvalidInput, op+": rule below floor").Error())
	}
	if floor >= RuleOwner && rule == RuleNobody {
		panic(core.Errorf(core.ErrInvalidInput, op+": cannot be disabled").Error())
	}
	if p.ops.Has(op) {
		panic(core.Errorf(core.ErrConflict, op+": already defined").Error())
	}
	if p.ops.Size() >= MaxOperations {
		panic(core.Errorf(core.ErrLimitExceeded, "too many operations").Error())
	}
	p.ops.Set(op, &entry{rule: rule, floor: floor})
}

// Set changes the rule for a defined op. The host must have authorized the
// actor (typically through a "policy.set" operation with an owner floor).
func (p *Policy) Set(op string, rule Rule) error {
	e := p.get(op)
	if e == nil {
		return core.Errorf(core.ErrNotFound, "unknown operation")
	}
	if !rule.valid() {
		return core.Errorf(core.ErrInvalidInput, "invalid rule")
	}
	if rule < e.floor {
		return core.Errorf(core.ErrInvalidInput, op+": rule below floor "+e.floor.String())
	}
	if e.floor >= RuleOwner && rule == RuleNobody {
		return core.Errorf(core.ErrInvalidInput, op+": cannot be disabled")
	}
	e.rule = rule
	return nil
}

// Rule returns the current rule for op.
func (p *Policy) Rule(op string) (Rule, bool) {
	e := p.get(op)
	if e == nil {
		return RuleNobody, false
	}
	return e.rule, true
}

// Authorize implements core.AuthorizationPolicy. Unknown operations are
// denied.
func (p *Policy) Authorize(op string, actor address) error {
	e := p.get(op)
	if e == nil {
		return core.Errorf(core.ErrUnauthorized, "unknown operation "+op)
	}
	if allowed(e.rule, p.members.RoleOf(actor)) {
		return nil
	}
	if e.rule == RuleNobody {
		return core.Errorf(core.ErrUnauthorized, op+" is disabled")
	}
	return core.Errorf(core.ErrUnauthorized, op+" requires "+e.rule.String())
}

// Allowed reports whether actor may perform op, without building an error.
func (p *Policy) Allowed(op string, actor address) bool {
	e := p.get(op)
	return e != nil && allowed(e.rule, p.members.RoleOf(actor))
}

// List returns every operation's rule, ordered by operation name.
func (p *Policy) List() []RuleView {
	var out []RuleView
	p.ops.Iterate("", "", func(k string, v any) bool {
		e := v.(*entry)
		out = append(out, RuleView{Op: k, Rule: e.rule, Floor: e.floor})
		return false
	})
	return out
}

func (p *Policy) get(op string) *entry {
	v := p.ops.Get(op)
	if v == nil {
		return nil
	}
	return v.(*entry)
}

// allowed treats a role outside the defined range as no role, so a faulty
// MembershipReader can never grant more than owner.
func allowed(rule Rule, role core.Role) bool {
	if !role.Valid() {
		return rule == RulePublic
	}
	switch rule {
	case RulePublic:
		return true
	case RuleMember:
		return role.AtLeast(core.RoleMember)
	case RuleReviewer:
		return role.AtLeast(core.RoleReviewer)
	case RuleOwner:
		return role.AtLeast(core.RoleOwner)
	}
	return false
}

func (r Rule) valid() bool { return r >= RulePublic && r <= RuleNobody }

// checkOp accepts lowercase dotted identifiers such as "poll.open": each
// dot- or underscore-separated part starts with a letter and continues with
// letters or digits.
func checkOp(op string) error {
	if len(op) == 0 || len(op) > 48 {
		return core.Errorf(core.ErrInvalidInput, "operation name length")
	}
	partStart := true
	for _, c := range op {
		lower := c >= 'a' && c <= 'z'
		digit := c >= '0' && c <= '9'
		switch {
		case c == '.' || c == '_':
			if partStart {
				return core.Errorf(core.ErrInvalidInput, "invalid operation name")
			}
			partStart = true
		case lower || (digit && !partStart):
			partStart = false
		default:
			return core.Errorf(core.ErrInvalidInput, "invalid operation name")
		}
	}
	if partStart {
		return core.Errorf(core.ErrInvalidInput, "invalid operation name")
	}
	return nil
}
