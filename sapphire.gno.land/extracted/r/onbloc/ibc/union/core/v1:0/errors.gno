package core

import (
	"errors"
	"strings"
)

// ErrSpoofedRealm guards non-crossing (_ int, rlm realm, ...) entrypoints: the
// passed rlm must be the current crossing frame, not a forged or stale token.
const errSpoofedRealm = "rlm does not match the current crossing frame"

// makeError builds a fresh error from one or more message parts joined by ", ".
// Errors are constructed at the call site (never shared package-level values) so
// the resulting object is owned by this (impl) realm rather than the realm that
// declared a shared sentinel. The base message constant comes first and any
// value-carrying detail after, e.g. makeError(core.ErrChannelNotFound, id.String()).
func makeError(msgs ...string) error {
	return errors.New(strings.Join(msgs, ", "))
}
