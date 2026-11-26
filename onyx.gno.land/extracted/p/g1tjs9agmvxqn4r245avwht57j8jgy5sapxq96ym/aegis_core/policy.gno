// Package aegis_core is the reusable, stateless core of Aegis Pit.
//
// It contains no realm state, so any realm can import it:
//   - Policy / ValidateSpend: hard spending rules for AI agents
//   - CommitHash / VerifyReveal / ResolveDuel: commit-reveal duel engine
//   - TrustRecord / TrustScore: reputation tied to real money at stake
//   - SplitPool: deterministic 95/3/2 pool split
package aegis_core

import (
	"errors"
	"strings"
)

var (
	ErrNoTargets      = errors.New("aegis: policy needs at least one allowed target")
	ErrBadTarget      = errors.New("aegis: invalid target address in policy")
	ErrBadCap         = errors.New("aegis: maxPerTx must be > 0")
	ErrExpired        = errors.New("aegis: policy expired")
	ErrTargetDenied   = errors.New("aegis: target not in allowlist")
	ErrFnDenied       = errors.New("aegis: function not in allowlist")
	ErrOverCap        = errors.New("aegis: amount exceeds per-tx cap")
	ErrNonPositiveAmt = errors.New("aegis: amount must be > 0")
)

// Policy is a spending rulebook signed by a human owner.
// Whatever an AI agent "decides" (or is prompt-injected into deciding),
// a spend only goes through if it satisfies every rule here.
type Policy struct {
	Targets      []address // allowed recipient addresses
	Fns          []string  // allowed function labels ("*" = any)
	MaxPerTx     int64     // ugnot cap per spend
	ExpireHeight int64     // 0 = never expires
}

// NewPolicy builds a Policy from comma-separated lists (friendly for
// `gnokey maketx call` and gnoweb forms).
func NewPolicy(targetsCSV, fnsCSV string, maxPerTx, expireHeight int64) (*Policy, error) {
	if maxPerTx <= 0 {
		return nil, ErrBadCap
	}
	targets := []address{}
	for _, raw := range splitCSV(targetsCSV) {
		a := address(raw)
		if !a.IsValid() {
			return nil, ErrBadTarget
		}
		targets = append(targets, a)
	}
	if len(targets) == 0 {
		return nil, ErrNoTargets
	}
	fns := splitCSV(fnsCSV)
	if len(fns) == 0 {
		fns = []string{"*"}
	}
	return &Policy{Targets: targets, Fns: fns, MaxPerTx: maxPerTx, ExpireHeight: expireHeight}, nil
}

// ValidateSpend returns nil only if the spend respects the policy.
// Callers are expected to panic on error so the whole tx reverts.
func ValidateSpend(p *Policy, target address, fn string, amt int64, height int64) error {
	if amt <= 0 {
		return ErrNonPositiveAmt
	}
	if p.ExpireHeight > 0 && height > p.ExpireHeight {
		return ErrExpired
	}
	if amt > p.MaxPerTx {
		return ErrOverCap
	}
	if !p.AllowsTarget(target) {
		return ErrTargetDenied
	}
	if !p.AllowsFn(fn) {
		return ErrFnDenied
	}
	return nil
}

func (p *Policy) AllowsTarget(target address) bool {
	for _, t := range p.Targets {
		if t == target {
			return true
		}
	}
	return false
}

func (p *Policy) AllowsFn(fn string) bool {
	for _, f := range p.Fns {
		if f == "*" || f == fn {
			return true
		}
	}
	return false
}

func splitCSV(s string) []string {
	out := []string{}
	for _, part := range strings.Split(s, ",") {
		part = strings.TrimSpace(part)
		if part != "" {
			out = append(out, part)
		}
	}
	return out
}
