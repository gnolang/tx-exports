package cometbls

import (
	"errors"
	"strings"
)

// IBC tendermint client sentinel errors
var (
	ErrInvalidChainID                    = errors.New("invalid chain-id")
	ErrInvalidHeight                     = errors.New("invalid height")
	ErrInvalidProof                      = errors.New("invalid proof")
	ErrInvalidConsensus                  = errors.New("invalid consensus state")
	ErrInvalidNextValidatorsHash         = errors.New("invalid next validators hash")
	ErrInvalidTrustingPeriod             = errors.New("invalid trusting period")
	ErrInvalidUnbondingPeriod            = errors.New("invalid unbonding period")
	ErrInvalidHeaderHeight               = errors.New("invalid header height")
	ErrInvalidMisbehaviour               = errors.New("invalid misbehaviour")
	ErrInvalidHeader                     = errors.New("invalid header")
	ErrInvalidMaxClockDrift              = errors.New("invalid max clock drift")
	ErrProcessedTimeNotFound             = errors.New("processed time not found")
	ErrProcessedHeightNotFound           = errors.New("processed height not found")
	ErrDelayPeriodNotPassed              = errors.New("packet-specified delay period has not been reached")
	ErrTrustingPeriodExpired             = errors.New("time since latest trusted state has passed the trusting period")
	ErrUnbondingPeriodExpired            = errors.New("time since latest trusted state has passed the unbonding period")
	ErrInvalidProofSpecs                 = errors.New("invalid proof specs")
	ErrInvalidValidatorSet               = errors.New("invalid validator set")
	ErrInvalidHeaderTimestamp            = errors.New("invalid header timestamp")
	ErrInvalidMisbehaviourHeaderSequence = errors.New("invalid misbehaviour header sequence")
	ErrMathOverflow                      = errors.New("math operation with overflow")
	ErrMisbehaviourNotFound              = errors.New("misbehaviour not found")
	ErrDecodeState                       = errors.New("decode state error")
)

func errorWithDetails(err error, msgs ...string) error {
	if len(msgs) == 0 {
		return err
	}

	return errors.New(err.Error() + ", " + strings.Join(msgs, ", "))
}
